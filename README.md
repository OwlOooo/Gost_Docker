# Gost_Docker

```bash
#!/bin/bash

# 下载脚本到 /usr/local/bin/
wget -O /usr/local/bin/gost https://raw.githubusercontent.com/OwlOooo/Gost_Docker/main/gost.sh

# 给脚本添加执行权限
chmod +x /usr/local/bin/gost

# 创建软链接（可选，如果 /usr/local/bin 已在 PATH 中则不需要）
ln -sf /usr/local/bin/gost /usr/bin/gost

# 提示安装完成
echo "Gost 脚本已安装成功！输入 'gost' 即可启动脚本。"
