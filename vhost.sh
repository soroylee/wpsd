#!/bin/bash
set -o pipefail
# 用户
NGINX_USER=www-data
# 组
NGINX_GROUP=www-data
# 获取当前脚本的软链接路径
SYMLINK_PATH=$(readlink -f "$0")
# DNMP目录
DNMP_DIR=$(dirname "$SYMLINK_PATH")
# 路径转换
DNMP_DIR=$(realpath "$DNMP_DIR")
# 加载公共变量
source "$DNMP_DIR/common.sh"
if [ ! -f "$DNMP_DIR/wordpress.zip" ]; then
    echoRC "未找到 wordpress.zip, 请放到 $DNMP_DIR 后再执行."
    exit 1
fi
# 加载.env
source "$DNMP_DIR/.env"
# 虚拟主机配置文件
VHOST_CONF_FILE=$DNMP_DIR/nginx/vhost.conf
# 输入的域名
INPUT_DOMAIN_NAME=""
# 需要操作的站点虚拟主机名
SITE_HOSTNAME=""
# 验证域名
function input_domain {
    while true; do
        echo -ne "$SB请输入域名(eg:demo.com):$ED "
        read -r INPUT_DOMAIN_NAME
        INPUT_DOMAIN_NAME=$(printf '%s' "$INPUT_DOMAIN_NAME" | tr 'A-Z' 'a-z')
        INPUT_DOMAIN_NAME=$(printf '%s' "$INPUT_DOMAIN_NAME" | awk '/^[a-z0-9][-a-z0-9]{0,62}(\.[a-z0-9][-a-z0-9]{0,62})+$/{print $0}')
        if [ -z "$INPUT_DOMAIN_NAME" ]; then
            echoRC "域名有误,请重新输入!!!"
            continue
        fi
        if ! ls "$VHOSTS_CONF_DIR"/*.conf >/dev/null 2>&1; then
            break
        fi
        if grep -r -q -i "server_name.*[ ;]$INPUT_DOMAIN_NAME[ ;]" "$VHOSTS_CONF_DIR"/*.conf; then
            echoCC "域名已存在."
            continue
        fi
        break
    done
}
# 0 存在  1 不存在  2 名为空  3 查询失败
function check_db_exists {
    if [ -z "$1" ]; then
        return 2
    fi
    local result
    if ! result=$(docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql mysql -uroot -N -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$1';"); then
        echoRC "数据库查询失败."
        return 3
    fi
    [ "$result" = "$1" ]
}
# MySQL 用户名最长 32 个字符
function site_database_name {
    local name="sql_$(printf '%s' "$1" | tr '.' '_' | tr '-' '_')"
    printf '%s' "${name:0:32}"
}
function random_str {
    local length=10
    if [ -n "$1" ]; then
        length=$1
    fi
    head -c "$length" /dev/urandom | base64 | tr -d '/+='
}
function reload_nginx {
    if ! docker exec nginx nginx -t >/dev/null 2>&1; then
        docker exec nginx nginx -t
        echoRC "Nginx 配置检测失败."
        return 1
    fi
    if ! docker exec nginx nginx -s reload; then
        echoRC "Nginx 重载失败."
        return 1
    fi
}
# Install WordPress
function install_wp {
    local wp_user wp_pass wp_mail db_prefix database_password site_doc_root
    local extract_dir src unzip_status
    echo -ne "$BC请输入站点管理员账号(默认:admin):$ED "
    read -r wp_user
    [ -z "$wp_user" ] && wp_user=admin
    echo -ne "$BC请输入站点管理员密码(默认:admin):$ED "
    read -r wp_pass
    [ -z "$wp_pass" ] && wp_pass=admin
    echo -ne "$BC请输入站点管理员邮箱(默认:admin@$INPUT_DOMAIN_NAME):$ED "
    read -r wp_mail
    [ -z "$wp_mail" ] && wp_mail="admin@$INPUT_DOMAIN_NAME"
    db_prefix="$(random_str 3 | tr 'A-Z' 'a-z')_"
    database_password=$(random_str 12)
    site_doc_root="/wwwroot/$INPUT_DOMAIN_NAME"
    if [ ! -f "$DNMP_DIR/wordpress.zip" ]; then
        echoRC "未找到 wordpress.zip."
        return 1
    fi
    if ! docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql mysql -uroot -e "CREATE DATABASE \`$DATABASE_NAME\`;"; then
        echoRC "数据库创建失败."
        return 1
    fi
    if ! docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql mysql -uroot -e "CREATE USER \`$DATABASE_NAME\`@'%' IDENTIFIED BY '$database_password';"; then
        echoRC "数据库用户创建失败."
        return 1
    fi
    if ! docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql mysql -uroot -e "GRANT ALL PRIVILEGES ON \`$DATABASE_NAME\`.* TO \`$DATABASE_NAME\`@'%';"; then
        echoRC "数据库授权失败."
        return 1
    fi
    echoCC "使用本地 wordpress.zip"
    extract_dir="$SITE_DOC_ROOT/.wp-extract"
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    unzip -q "$DNMP_DIR/wordpress.zip" -d "$extract_dir"
    unzip_status=$?
    if [ "$unzip_status" -gt 1 ]; then
        rm -rf "$extract_dir"
        echoRC "wordpress.zip 解压失败."
        return 1
    fi
    if [ -f "$extract_dir/wordpress/wp-load.php" ]; then
        src="$extract_dir/wordpress"
    elif [ -f "$extract_dir/wp-load.php" ]; then
        src="$extract_dir"
    else
        rm -rf "$extract_dir"
        echoRC "wordpress.zip 不是 WordPress 程序包."
        return 1
    fi
    if ! (
        shopt -s dotglob
        mv "$src"/* "$SITE_DOC_ROOT"/
    ); then
        rm -rf "$extract_dir"
        echoRC "WordPress 文件就位失败."
        return 1
    fi
    rm -rf "$extract_dir"
    if [ ! -f "$SITE_DOC_ROOT/wp-load.php" ]; then
        echoRC "WordPress 文件就位失败."
        return 1
    fi
    if ! docker exec nginx wp config create --dbname="$DATABASE_NAME" --dbuser="$DATABASE_NAME" --dbpass="$database_password" --dbprefix="$db_prefix" --dbhost=mysql:3306 --path="$site_doc_root" --allow-root --quiet; then
        echoRC "WordPress 配置创建失败."
        return 1
    fi
    if ! docker exec nginx wp core install --url="https://$INPUT_DOMAIN_NAME" --title="My Blog" --admin_user="$wp_user" --admin_password="$wp_pass" --admin_email="$wp_mail" --skip-email --path="$site_doc_root" --allow-root --quiet; then
        echoRC "WordPress 安装失败."
        return 1
    fi
}
# 创建站点
function create_site {
    local db_status wp_ok=0 iswp
    input_domain
    SITE_DOC_ROOT=$VHOSTS_ROOT/$INPUT_DOMAIN_NAME
    DATABASE_NAME=$(site_database_name "$INPUT_DOMAIN_NAME")
    if [ -d "$SITE_DOC_ROOT" ]; then
        echoRC "站点目录已存在."
        return 1
    fi
    check_db_exists "$DATABASE_NAME"
    db_status=$?
    if [ "$db_status" -eq 0 ]; then
        echoRC "数据库已存在."
        return 1
    elif [ "$db_status" -eq 2 ]; then
        echoRC "数据库名不能为空."
        return 1
    elif [ "$db_status" -ne 1 ]; then
        return 1
    fi
    mkdir -p "$SITE_DOC_ROOT"
    cp -f "$VHOST_CONF_FILE" "$VHOSTS_CONF_DIR/$INPUT_DOMAIN_NAME.conf"
    sed -i "s/default_replace_8888/$INPUT_DOMAIN_NAME/" "$VHOSTS_CONF_DIR/$INPUT_DOMAIN_NAME.conf"
    echo -ne "$BC是否安装WordPress(y/N):$ED "
    read -r iswp
    if [ -z "$iswp" ]; then
        iswp=n
    fi
    if [ "$iswp" = "y" ] || [ "$iswp" = "Y" ]; then
        install_wp || wp_ok=1
    else
        echo 'This a Temp Site.' > "$SITE_DOC_ROOT/index.php"
    fi
    if ! chmod -R 777 "$SITE_DOC_ROOT"; then
        echoRC "站点目录权限设置失败."
        return 1
    fi
    if ! reload_nginx; then
        return 1
    fi
    if [ "$wp_ok" -ne 0 ]; then
        return 1
    fi
    iswp=$(printf '%s' "$iswp" | tr 'a-z' 'A-Z')
    echo -e "${CC}站点创建成功${ED}: ${SB}WordPress [${iswp}]${ED}"
    echoGC "站点链接: https://$INPUT_DOMAIN_NAME"
    echoGC "站点目录: $SITE_DOC_ROOT"
}
# 获取站点虚拟主机名
function site_hostname_get {
    local -a sites
    local site_name site_index i
    sites=("$VHOSTS_CONF_DIR"/*.conf)
    if [ ${#sites[@]} -eq 0 ] || [ ! -f "${sites[0]}" ]; then
        echoCC "没有找到任何站点"
        return 1
    fi
    i=1
    for site in "${sites[@]}"; do
        site_name=$(basename "${site%.conf}")
        echo -e "${CC}${i}${ED}.${LG}${site_name}${ED}"
        i=$((i + 1))
    done
    while true; do
        echo -ne "${SB}请输入站点序号(${ED}1-${#sites[@]}${SB}): ${ED}"
        read -r site_index
        if ! [[ "$site_index" =~ ^[0-9]+$ ]]; then
            echoRC "请输入有效的数字"
            continue
        fi
        if [ "$site_index" -lt 1 ] || [ "$site_index" -gt ${#sites[@]} ]; then
            echoRC "请输入 1-${#sites[@]} 之间的数字"
            continue
        fi
        break
    done
    site_name=$(basename "${sites[$((site_index - 1))]}")
    SITE_HOSTNAME="${site_name%.conf}"
    echo -e "${PC}SITE:${ED} ${SITE_HOSTNAME}"
    return 0
}
# 查询是否存在站点
function site_exists {
    local conf_count
    conf_count=$(find "$VHOSTS_CONF_DIR" -type f -name "*.conf" | wc -l)
    if [ "$conf_count" -eq 0 ]; then
        echoCC "没有找到任何站点"
        return 1
    fi
    return 0
}
# 追加域名
function site_append_domain {
    local site_conf_file domain_list
    if ! site_exists; then
        return 1
    fi
    site_hostname_get || return 1
    input_domain
    site_conf_file=$VHOSTS_CONF_DIR/$SITE_HOSTNAME.conf
    sed -i "/server_name/ s/;/ $INPUT_DOMAIN_NAME;/" "$site_conf_file"
    domain_list=$(sed -n '0,/server_name/{s/.*server_name[[:space:]]\+\(.*\);/\1/p}' "$site_conf_file")
    if ! reload_nginx; then
        return 1
    fi
    echo -e "${GC}域名追加成功:${ED} ${CC}$domain_list${ED}"
}
# 删除站点
function site_delete {
    local confirm database_name site_dir db_status
    if ! site_exists; then
        return 1
    fi
    site_hostname_get || return 1
    echo -ne "${SB}完全删除站点(包含备份)?[${ED}y/n${SB}]:${ED} "
    read -r confirm
    case $confirm in
        y) ;;
        n) return ;;
        *) echoRC "输入有误." && return ;;
    esac
    database_name=$(site_database_name "$SITE_HOSTNAME")
    check_db_exists "$database_name"
    db_status=$?
    if [ "$db_status" -eq 3 ]; then
        return 1
    fi
    site_dir="$VHOSTS_ROOT/$SITE_HOSTNAME"
    if [ -n "$SITE_HOSTNAME" ] && [ "${site_dir%/}" != "${VHOSTS_ROOT%/}" ]; then
        rm -rf "$site_dir"
    fi
    if [ "$db_status" -eq 0 ]; then
        docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql mysql -uroot -e "DROP DATABASE \`$database_name\`;"
        docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql mysql -uroot -e "DROP USER \`$database_name\`@'%';"
    elif [ "$db_status" -eq 2 ]; then
        echoRC "数据库名为空."
    else
        echoYC "数据库不存在. 跳过删除."
    fi
    rm -f "$VHOSTS_CONF_DIR/$SITE_HOSTNAME.conf"
    rm -f "$BACKUP_STORAGE_DIR/$SITE_HOSTNAME."*
    rm -f "$LOGS_ROOT/nginx/$SITE_HOSTNAME."*
    if ! reload_nginx; then
        echoRC "站点文件已删除, 但 Nginx 重载失败."
        return 1
    fi
    echoCC "站点删除成功"
}
# 备份站点
function site_backup {
    local site_root_path save_backup_file save_database_file database_name db_status
    if ! site_exists; then
        return 1
    fi
    mkdir -p "$BACKUP_STORAGE_DIR"
    site_hostname_get || return 1
    site_root_path=$VHOSTS_ROOT/$SITE_HOSTNAME
    save_backup_file="$BACKUP_STORAGE_DIR/${SITE_HOSTNAME}.$(date +"%Y%m%d_%H%M%S").tar.zst"
    save_database_file="$site_root_path/db.sql"
    database_name=$(site_database_name "$SITE_HOSTNAME")
    check_db_exists "$database_name"
    db_status=$?
    if [ "$db_status" -eq 3 ]; then
        return 1
    elif [ "$db_status" -eq 1 ]; then
        echoCC "数据库不存在."
        return 1
    elif [ "$db_status" -eq 2 ]; then
        echoCC "数据库名不能为空."
        return 1
    fi
    if ! docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql mysqldump -uroot "$database_name" > "$save_database_file"; then
        rm -f "$save_database_file"
        echoRC "数据库导出失败"
        return 1
    fi
    echoCC "数据库导出成功"
    if ! tar -I zstd -cf "$save_backup_file" -C "$site_root_path" .; then
        rm -f "$save_database_file"
        echoRC "备份失败."
        return 1
    fi
    rm -f "$save_database_file"
    echoSB "备份文件列表, 总容量: $(du -sh "$BACKUP_STORAGE_DIR")"
    ls -ghGA "$BACKUP_STORAGE_DIR" | awk 'BEGIN{OFS="\t"} NR > 1 {print $3, $7}'
}
# 恢复站点
function site_restore {
    local site_root_path temp_dir database_name site_backup_file site_backup_file_path database_backup_file
    if ! site_exists; then
        return 1
    fi
    site_hostname_get || return 1
    site_root_path="$VHOSTS_ROOT/$SITE_HOSTNAME"
    temp_dir=$BACKUP_STORAGE_DIR/temp
    database_name=$(site_database_name "$SITE_HOSTNAME")
    echoSB "备份文件列表, 总容量: $(du -sh "$BACKUP_STORAGE_DIR")"
    ls -ghGA "$BACKUP_STORAGE_DIR" | awk 'BEGIN{OFS="\t"} NR > 1 {print $3, $7}'
    echo -ne "$BC请输入要还原的文件名: $ED"
    read -r site_backup_file
    if [ -z "$site_backup_file" ]; then
        echoCC "输入不能为空"
        return 1
    fi
    if [[ ! $site_backup_file =~ \.tar\.zst$ ]]; then
        echoCC "[$site_backup_file]非指定的压缩格式."
        return 1
    fi
    site_backup_file_path=$BACKUP_STORAGE_DIR/$site_backup_file
    if [ ! -f "$site_backup_file_path" ]; then
        echoCC "[$site_backup_file_path] 指定文件不存在."
        return 1
    fi
    rm -rf "$temp_dir"
    mkdir -p "$temp_dir"
    if ! tar -I zstd -xf "$site_backup_file_path" -C "$temp_dir"; then
        rm -rf "$temp_dir"
        echoRC "站点恢复失败"
        return 1
    fi
    database_backup_file="$temp_dir/db.sql"
    if [ ! -f "$database_backup_file" ]; then
        rm -rf "$temp_dir"
        echoRC "备份中没有数据库文件."
        return 1
    fi
    echo -e "${SB}恢复数据库${ED}"
    docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql mysql -uroot -e "DROP DATABASE IF EXISTS \`$database_name\`;"
    if ! docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql mysql -uroot -e "CREATE DATABASE \`$database_name\`;"; then
        rm -rf "$temp_dir"
        echoRC "数据库恢复失败"
        return 1
    fi
    if ! pv "$database_backup_file" | docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql mysql -uroot "$database_name"; then
        rm -rf "$temp_dir"
        echoRC "数据库恢复失败"
        return 1
    fi
    rm -f "$database_backup_file"
    rm -rf "$site_root_path"
    if ! mv "$temp_dir" "$site_root_path"; then
        echoRC "站点文件恢复失败, 文件仍在 $temp_dir"
        return 1
    fi
    docker exec nginx chown -R "$NGINX_USER:$NGINX_GROUP" "/wwwroot/$SITE_HOSTNAME"
    echoCC "站点恢复成功"
}
# 安装phpMyAdmin
function install_phpmyadmin {
    local phpmyadmin_dir secret_key
    phpmyadmin_dir=$VHOSTS_ROOT/phpMyAdmin
    if [ -d "$phpmyadmin_dir" ]; then
        echoCC "phpMyAdmin已安装."
        echoGC "phpMyAdmin链接: https://localhost:8081"
        return 0
    fi
    secret_key=$(head -c 48 /dev/urandom | base64 | tr -d '/+=' | cut -c1-32)
    if ! wget -O "$VHOSTS_ROOT/phpmyadmin.zip" https://files.phpmyadmin.net/phpMyAdmin/5.2.1/phpMyAdmin-5.2.1-english.zip; then
        rm -f "$VHOSTS_ROOT/phpmyadmin.zip"
        echoRC "phpMyAdmin 下载失败."
        return 1
    fi
    if ! unzip -o "$VHOSTS_ROOT/phpmyadmin.zip" -d "$VHOSTS_ROOT" > /dev/null 2>&1; then
        rm -f "$VHOSTS_ROOT/phpmyadmin.zip"
        echoRC "phpMyAdmin 解压失败."
        return 1
    fi
    rm -f "$VHOSTS_ROOT/phpmyadmin.zip"
    mv "$VHOSTS_ROOT/phpMyAdmin-5.2.1-english" "$phpmyadmin_dir"
    mv "$phpmyadmin_dir/config.sample.inc.php" "$phpmyadmin_dir/config.inc.php"
    sed -i "s/localhost/mysql/g" "$phpmyadmin_dir/config.inc.php"
    sed -i "s/\(\$cfg\['blowfish_secret'\] = \)'';/\1'$secret_key';/" "$phpmyadmin_dir/config.inc.php"
    sed -i "s/\(\$cfg\['blowfish_secret'\] = \)'';/\1'$secret_key';/" "$phpmyadmin_dir/libraries/config.default.php"
    docker exec nginx chown -R "$NGINX_USER:$NGINX_GROUP" /wwwroot/phpMyAdmin
    pv "$phpmyadmin_dir/sql/create_tables.sql" | docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql mysql -uroot
    echoCC "phpMyAdmin安装成功."
    echoGC "phpMyAdmin链接: https://localhost:8081"
}
# 站点命令
function site_cmd {
    local choice
    while true; do
        echo -e "${SB}1${ED}.${LG}创建站点${ED}"
        echo -e "${SB}2${ED}.${LG}追加域名${ED}"
        echo -e "${SB}3${ED}.${LG}删除站点${ED}"
        echo -e "${SB}4${ED}.${LG}备份站点${ED}"
        echo -e "${SB}5${ED}.${LG}恢复站点${ED}"
        echo -e "${SB}6${ED}.${LG}安装phpMyAdmin${ED}"
        echo -e "${SB}e${ED}.${LG}退出${ED}"
        echo -ne "${BC}请选择: ${ED}"
        read -r choice
        case $choice in
            1) create_site ;;
            2) site_append_domain ;;
            3) site_delete ;;
            4) site_backup ;;
            5) site_restore ;;
            6) install_phpmyadmin ;;
            e) break ;;
            *) echoCC "输入有误."
        esac
    done
}
echoCC "本脚本仅供本机开发使用, 不要在生产环境使用."
site_cmd
