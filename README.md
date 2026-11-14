# Windows 11 WSL 本地部署WordPess网站

####  1.
```
cd && sudo apt update && sudo apt install git -y 
```

#### 2. Download
```
sudo git clone --depth 1 https://github.com/soroylee/wpsd
```

#### 3. Deploy Environment
```
sudo bash wpsd/install.sh
```

##### 4. Add Sites
```
sudo vhost.sh
```

#### 5. 项目常用指令 (可选)
```
# 进入项目
cd $HOME/wpsd 

# 停止并删除容器 网络 图像和挂载卷
docker compose down

# 创建并且后台运行方式启动所有容器
docker-compose up -d

# 重启服务
docker-compose restart <服务名>             

# 重启
sudo reboot
```

#### 6. WSL 常用指令
```
# 进入指定安装的wsl发型版
wsl -d wpsd

# 终止 所有 WSL 2 虚拟机
wsl --shutdown
```