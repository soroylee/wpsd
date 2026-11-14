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

#### 5. 常用指令
```
# 进入指定安装的wsl发型版
wsl -d wpsd

# 重启
sudo reboot

# 终止 所有 WSL 2 虚拟机
wsl --shutdown

```