#!/bin/bash
apt update
curl -sSL https://dot.net/v1/dotnet-install.sh | bash
apt install -y libicu-dev git
echo 'export PATH="$HOME/.dotnet:$PATH"' >> ~/.bashrc
source ~/.bashrc
dotnet --info
echo "安装完成！"
