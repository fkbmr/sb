#!/bin/bash
# =========================================================
# Minecraft Mod FULL AUTO PIPELINE
# Build → Obfuscate → Deobf → Decompile
# =========================================================

BASE=~/modpipeline
PROJ=$BASE/projects
REL=$BASE/release
DEOBF=$BASE/deobf
DECOMP=$BASE/decompile
TOOLS=$BASE/tools

mkdir -p $PROJ $REL $DEOBF $DECOMP $TOOLS

RED="\033[1;31m"
GREEN="\033[1;32m"
BLUE="\033[1;34m"
RESET="\033[0m"

info(){ echo -e "${BLUE}[INFO]${RESET} $*"; }
ok(){ echo -e "${GREEN}[OK]${RESET} $*"; }
err(){ echo -e "${RED}[ERR]${RESET} $*"; }

# =========================================================
# 存储挂载
# =========================================================
if command -v termux-setup-storage >/dev/null; then
 [[ ! -d ~/storage/shared ]] && termux-setup-storage
fi

# =========================================================
# 工具安装
# =========================================================
pkg install -y git wget unzip zip openjdk-17 >/dev/null 2>&1

# =========================================================
# 下载工具
# =========================================================

download_tools(){

# ProGuard
mkdir -p $TOOLS/proguard
[[ ! -f $TOOLS/proguard/proguard.jar ]] && \
wget -O pg.zip https://github.com/Guardsquare/proguard/releases/download/v7.4.1/proguard-7.4.1.zip && \
unzip pg.zip -d $TOOLS/proguard && \
mv $TOOLS/proguard/proguard*/lib/proguard.jar $TOOLS/proguard/

# ZelixKiller
mkdir -p $TOOLS/zelixkiller
[[ ! -f $TOOLS/zelixkiller/zkm.jar ]] && \
wget -O $TOOLS/zelixkiller/zkm.jar \
https://raw.githubusercontent.com/fkbmr/sb/main/zkm.jar

# CFR
mkdir -p $TOOLS/cfr
[[ ! -f $TOOLS/cfr/cfr.jar ]] && \
wget -O $TOOLS/cfr/cfr.jar \
https://www.benf.org/other/cfr/cfr-0.152.jar

ok "工具准备完成"
}

# =========================================================
# Loader 识别
# =========================================================
detect_loader(){
if grep -qi fabric build.gradle 2>/dev/null; then
 echo fabric
elif grep -qi forge build.gradle 2>/dev/null; then
 echo forge
else
 echo gradle
fi
}

# =========================================================
# 构建
# =========================================================
build_project(){

wrapper(){
 [[ ! -f gradlew ]] && gradle wrapper && chmod +x gradlew
}

wrapper
TYPE=$(detect_loader)

case $TYPE in
 fabric) CMD="./gradlew build remapJar" ;;
 forge) CMD="./gradlew build reobfJar" ;;
 *) CMD="./gradlew build" ;;
esac

$CMD --stacktrace || { err "构建失败"; return; }

jar=$(find build/libs -name "*.jar" | head -1)
cp "$jar" $REL/
ok "构建完成: $(basename $jar)"
}

# =========================================================
# ProGuard 混淆
# =========================================================
proguard(){
jar=$(find $REL -name "*.jar" | head -1)

cat > rules.pro <<EOF
-injars $jar
-outjars $REL/pg-obf.jar
-dontwarn
-keep public class * { *; }
EOF

java -jar $TOOLS/proguard/proguard.jar @rules.pro
ok "ProGuard完成"
}

# =========================================================
# ZKM 混淆
# =========================================================
zkm(){
jar=$(find $REL -name "*.jar" | head -1)

cat > zkm.txt <<EOF
input=$jar
output=$REL/zkm-obf.jar
EOF

java -jar $TOOLS/zelixkiller/zkm.jar -script zkm.txt
ok "ZKM完成"
}

# =========================================================
# ZelixKiller 反混淆
# =========================================================
deobf(){
jar=$(find $REL -name "*.jar" | head -1)

java -jar $TOOLS/zelixkiller/zkm.jar \
 --input "$jar" \
 --output "$DEOBF/deobf.jar" \
 --transformer "s11,si11,rvm11,cf11" \
 --verbose

ok "反混淆完成"
}

# =========================================================
# CFR 反编译
# =========================================================
decompile(){
jar=$(find $DEOBF -name "*.jar" | head -1)

java -jar $TOOLS/cfr/cfr.jar \
 "$jar" \
 --outputdir "$DECOMP"

ok "反编译完成 → $DECOMP"
}

# =========================================================
# 全自动流水线
# =========================================================
pipeline(){
download_tools
build_project
proguard
zkm
deobf
decompile
ok "全流水线完成"
}

# =========================================================
# 菜单
# =========================================================
while true; do
echo "========= FULL PIPELINE ========="
echo "1️⃣ 下载工具"
echo "2️⃣ 构建项目"
echo "3️⃣ 全自动流水线"
echo "0️⃣ 退出"
read -rp "选择: " c

case $c in
1) download_tools ;;
2) build_project ;;
3) pipeline ;;
0) exit ;;
esac
done
