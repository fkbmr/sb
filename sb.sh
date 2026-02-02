#!/bin/bash
apt update
curl -sSL https://dot.net/v1/dotnet-install.sh | bash
apt install -y libicu-dev git
echo 'export PATH="$HOME/.dotnet:$PATH"' >> ~/.bashrc
source ~/.bashrc
dotnet --info
git clone https://gh-proxy.org/https://github.com/NirvanaTec/Fantnel.git
git clone https://gh-proxy.org/https://github.com/denetease/OpenSDK.NEL.git
echo "sb"
