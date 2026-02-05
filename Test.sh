#!/usr/bin/env bash
# mcdev_final.sh
# Ultimate single-file Minecraft Mod pipeline (Termux-friendly)
# Full integration: JDK (custom + auto download), Gradle wrapper, Gradle ZIP import,
# Maven, Gradle optimization, Git clone with proxy, Fabric/Forge/MCP detection,
# remap/reobf handling, release publishing, ProGuard, advanced obfuscation, ZKM, CFR,
# Fabric/Forge MDK download, batch build, full pipeline.

set -euo pipefail
IFS=$'\n\t'

# -------------------------
# Colors & helpers
# -------------------------
RED="\033[1;31m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; BLUE="\033[1;34m"; CYAN="\033[1;36m"; RESET="\033[0m"
info(){ echo -e "${BLUE}[INFO]${RESET} $*"; }
ok(){ echo -e "${GREEN}[OK]${RESET} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $*"; }
err(){ echo -e "${RED}[ERR]${RESET} $*"; }

# -------------------------
# Paths & globals
# -------------------------
BASE="$HOME/modpipeline"
PROJECTS_LOCAL="$HOME/projects"
PROJECTS_SDCARD="$HOME/storage/shared/Projects"   # Termux shared path
TOOLS_DIR="$BASE/tools"
PROGUARD_DIR="$TOOLS_DIR/proguard"
PROGUARD_JAR="$PROGUARD_DIR/proguard.jar"
ZKM_DIR="$TOOLS_DIR/zelixkiller"
ZKM_JAR="$ZKM_DIR/zkm.jar"
CFR_DIR="$TOOLS_DIR/cfr"
CFR_JAR="$CFR_DIR/cfr.jar"
STRINGER_JAR="$HOME/stringer.jar"   # optional external string obfuscator
CONFIG_FILE="$HOME/.mcdev_env.conf"
GRADLE_USER_HOME="$HOME/.gradle"
SDCARD_DOWNLOAD="/sdcard/Download"
ARCH=$(uname -m)

IS_TERMUX=false
PKG_INSTALL_CMD=""

# Determine environment & package manager
if command -v pkg >/dev/null 2>&1; then
  IS_TERMUX=true
  PKG_INSTALL_CMD="pkg install -y"
elif command -v apt >/dev/null 2>&1; then
  PKG_INSTALL_CMD="sudo apt-get install -y"
elif command -v yum >/dev/null 2>&1; then
  PKG_INSTALL_CMD="sudo yum install -y"
fi

# -------------------------
# Utility
# -------------------------
ensure_dir(){ mkdir -p "$1"; }
run_and_log(){ local log="$1"; shift; "$@" 2>&1 | tee "$log"; return "${PIPESTATUS[0]}"; }

# -------------------------
# Config load/save
# -------------------------
load_config(){
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
  fi
  if [[ -z "${PROJECT_BASE:-}" ]]; then
    if [[ -d "$PROJECTS_SDCARD" ]]; then PROJECT_BASE="$PROJECTS_SDCARD"; else PROJECT_BASE="$PROJECTS_LOCAL"; fi
  fi
}
save_config(){
  ensure_dir "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<EOF
PROJECT_BASE="$PROJECT_BASE"
EOF
  ok "配置保存至 $CONFIG_FILE"
}

# -------------------------
# Storage / Termux helper
# -------------------------
check_storage_and_hint(){
  if [[ "$IS_TERMUX" == "true" ]]; then
    if [[ ! -d "$HOME/storage/shared" && ! -d "/sdcard" ]]; then
      warn "Termux 未挂载共享存储 (~/storage/shared 或 /sdcard)。"
      read -p "现在运行 termux-setup-storage 授权？(y/N): " yn
      if [[ "$yn" =~ ^[Yy]$ ]]; then
        termux-setup-storage
        sleep 2
      else
        warn "将使用本地目录作为 fallback。"
      fi
    fi
  fi
}

# -------------------------
# Ensure basic CLI tools
# -------------------------
ensure_basic_tools(){
  local need=(git wget curl unzip zip tar sed awk javac)
  local miss=()
  for t in "${need[@]}"; do
    if ! command -v "$t" >/dev/null 2>&1; then miss+=("$t"); fi
  done
  if [[ ${#miss[@]} -gt 0 ]]; then
    warn "检测到缺失工具: ${miss[*]}"
    if [[ -n "$PKG_INSTALL_CMD" ]]; then
      info "尝试通过包管理器安装..."
      $PKG_INSTALL_CMD "${miss[@]}" || warn "自动安装失败，请手动安装: ${miss[*]}"
    else
      warn "无法自动安装，请手动安装: ${miss[*]}"
    fi
  fi
}

# -------------------------
# JDK: auto download and custom install
# -------------------------
auto_install_jdk(){
  if command -v java >/dev/null 2>&1; then
    info "检测到 Java: $(java -version 2>&1 | head -n1)"
    read -p "保留现有 Java？(y/N): " keep
    [[ "$keep" =~ ^[Yy]$ ]] && return 0
  fi

  echo "请选择 JDK 版本：1)8  2)17(推荐)  3)21  4) 自定义 URL/本地包  5) 取消"
  read -p "选择 [1-5]: " c
  case "$c" in
    1) ver=8 ;;
    2) ver=17 ;;
    3) ver=21 ;;
    4)
      read -p "输入 JDK 下载 URL 或 本地路径 (tar.gz/zip): " src
      install_custom_jdk "$src"
      return $?
      ;;
    *) warn "取消 JDK 安装"; return 1 ;;
  esac

  case "$ARCH" in
    aarch64|arm64) arch_dl="aarch64" ;;
    x86_64|amd64) arch_dl="x64" ;;
    *) arch_dl="x64" ;;
  esac

  dest="$HOME/jdk-$ver"
  ensure_dir "$dest"
  api_url="https://api.adoptium.net/v3/binary/latest/${ver}/ga/linux/${arch_dl}/jdk/hotspot/normal/eclipse"
  info "将通过 Adoptium API 下载 JDK $ver ..."
  tmp="/tmp/jdk${ver}.tar.gz"
  if wget -O "$tmp" "$api_url"; then
    info "下载完成，正在解压..."
    tar -xzf "$tmp" -C "$dest" --strip-components=1 || { err "解压失败"; return 1; }
    rm -f "$tmp"
    shell_rc="$HOME/.bashrc"; [[ -n "${ZSH_VERSION-}" ]] && shell_rc="$HOME/.zshrc"
    if ! grep -q "mcdev jdk $ver" "$shell_rc" 2>/dev/null; then
      {
        echo ""
        echo "# mcdev jdk $ver"
        echo "export JAVA_HOME=\"$dest\""
        echo 'export PATH=$JAVA_HOME/bin:$PATH'
      } >> "$shell_rc"
      ok "已写入 $shell_rc（重新打开 shell 或 source 生效）"
    fi
    export JAVA_HOME="$dest"; export PATH="$JAVA_HOME/bin:$PATH"
    ok "JDK $ver 安装完成"
    return 0
  else
    err "JDK 下载失败 (URL: $api_url)"
    return 1
  fi
}

install_custom_jdk(){
  local src="$1"
  if [[ -z "$src" ]]; then err "未提供 URL/路径"; return 1; fi
  if [[ "$src" =~ ^https?:// ]]; then
    tmp="/tmp/custom_jdk_$(date +%s).tar.gz"
    info "下载自定义 JDK..."
    if ! wget -O "$tmp" "$src"; then err "下载失败"; return 1; fi
    src="$tmp"
  fi
  if [[ ! -f "$src" ]]; then err "文件不存在: $src"; return 1; fi
  dest="$HOME/jdk-custom-$(date +%s)"
  ensure_dir "$dest"
  info "解压到 $dest ..."
  case "$src" in
    *.tar.gz|*.tgz) tar -xzf "$src" -C "$dest" --strip-components=1 ;;
    *.zip) unzip -q "$src" -d "$dest" ;;
    *) err "不支持的压缩格式"; return 1 ;;
  esac
  shell_rc="$HOME/.bashrc"; [[ -n "${ZSH_VERSION-}" ]] && shell_rc="$HOME/.zshrc"
  {
    echo ""
    echo "# mcdev custom jdk"
    echo "export JAVA_HOME=\"$dest\""
    echo 'export PATH=$JAVA_HOME/bin:$PATH'
  } >> "$shell_rc"
  export JAVA_HOME="$dest"; export PATH="$JAVA_HOME/bin:$PATH"
  ok "自定义 JDK 已安装并写入 $shell_rc"
  return 0
}

# -------------------------
# ProGuard auto-download
# -------------------------
ensure_proguard(){
  if [[ -f "$PROGUARD_JAR" ]]; then ok "ProGuard 就绪"; return 0; fi
  info "正在下载 ProGuard..."
  ensure_dir "$PROGUARD_DIR"
  PG_VER="7.4.1"
  PG_TGZ="proguard-${PG_VER}.tar.gz"
  PG_URL="https://github.com/Guardsquare/proguard/releases/download/v${PG_VER}/${PG_TGZ}"
  tmp="$PROGUARD_DIR/$PG_TGZ"
  if wget -O "$tmp" "$PG_URL"; then
    tar -xzf "$tmp" -C "$PROGUARD_DIR" --strip-components=1
    if [[ -f "$PROGUARD_DIR/lib/proguard.jar" ]]; then
      mv "$PROGUARD_DIR/lib/proguard.jar" "$PROGUARD_JAR"
      rm -rf "$PROGUARD_DIR/lib" "$PROGUARD_DIR/bin" "$PROGUARD_DIR/docs"
      rm -f "$tmp"
      ok "ProGuard 已下载: $PROGUARD_JAR"
      return 0
    fi
  fi
  err "ProGuard 下载或解压失败"
  return 1
}

# -------------------------
# ZKM (ZelixKiller) auto-download (user-provided URL default)
# -------------------------
ensure_zkm(){
  if [[ -f "$ZKM_JAR" ]]; then ok "ZKM 就绪"; return 0; fi
  ensure_dir "$ZKM_DIR"
  ZKM_URL_DEFAULT="https://raw.githubusercontent.com/fkbmr/sb/main/zkm.jar"
  read -p "请输入 ZKM 下载 URL (回车使用默认): " zurl
  zurl=${zurl:-$ZKM_URL_DEFAULT}
  info "下载 ZKM..."
  if wget -O "$ZKM_JAR" "$zurl"; then ok "ZKM 已下载: $ZKM_JAR"; return 0; else err "ZKM 下载失败"; return 1; fi
}

# -------------------------
# CFR ensure (decompiler)
# -------------------------
ensure_cfr(){
  if [[ -f "$CFR_JAR" ]]; then ok "CFR 就绪"; return 0; fi
  ensure_dir "$CFR_DIR"
  CFR_URL="https://www.benf.org/other/cfr/cfr-0.152.jar"
  info "下载 CFR..."
  if wget -O "$CFR_JAR" "$CFR_URL"; then ok "CFR 已下载"; return 0; else err "CFR 下载失败"; return 1; fi
}

# -------------------------
# Gradle wrapper / install
# -------------------------
ensure_gradle_wrapper(){
  if [[ -f "./gradlew" ]]; then chmod +x ./gradlew 2>/dev/null || true; ok "gradlew 已存在"; return 0; fi
  warn "gradlew 不存在，尝试生成 wrapper..."
  if ! command -v gradle >/dev/null 2>&1; then
    warn "系统未安装 Gradle"
    if [[ -n "$PKG_INSTALL_CMD" ]]; then
      $PKG_INSTALL_CMD gradle || warn "自动安装 gradle 失败"
    fi
  fi
  if command -v gradle >/dev/null 2>&1; then
    gradle wrapper || { err "gradle wrapper 生成失败"; return 1; }
    chmod +x ./gradlew
    ok "Gradle wrapper 生成完成"
    return 0
  fi
  return 1
}

install_gradle_from_zip(){
  read -p "请输入 Gradle ZIP 本地路径或下载 URL: " zippath
  [[ -z "$zippath" ]] && { warn "取消"; return 1; }
  zippath="${zippath/#\~/$HOME}"
  if [[ "$zippath" =~ ^https?:// ]]; then
    tmp="/tmp/gradle_$(date +%s).zip"
    info "下载 Gradle ZIP..."
    wget -O "$tmp" "$zippath" || { err "下载失败"; return 1; }
    zippath="$tmp"
  fi
  if [[ ! -f "$zippath" ]]; then err "文件不存在: $zippath"; return 1; fi
  if [[ -w /opt ]]; then dest="/opt/gradle"; else dest="$HOME/.local/gradle"; fi
  ensure_dir "$dest"
  unzip -q -o "$zippath" -d "$dest"
  folder=$(ls "$dest" | head -n1)
  if [[ -x "$dest/$folder/bin/gradle" ]]; then
    ln -sf "$dest/$folder/bin/gradle" /usr/local/bin/gradle 2>/dev/null || ln -sf "$dest/$folder/bin/gradle" "$HOME/.local/bin/gradle"
    ok "Gradle 已安装到 $dest/$folder"
    return 0
  fi
  err "Gradle 安装后未找到 bin/gradle"
  return 1
}

# -------------------------
# Maven ensure
# -------------------------
ensure_maven(){
  if command -v mvn >/dev/null 2>&1; then ok "Maven 已安装"; return 0; fi
  if [[ -n "$PKG_INSTALL_CMD" ]]; then
    info "尝试安装 Maven..."
    $PKG_INSTALL_CMD maven || { warn "自动安装 Maven 失败，请手动安装"; return 1; }
    ok "Maven 安装完成"; return 0
  fi
  warn "无法自动安装 Maven，请手动安装"
  return 1
}

# -------------------------
# Gradle optimization & init (mirrors)
# -------------------------
configure_gradle_optimization(){
  ensure_dir "$GRADLE_USER_HOME"
  PROPS="$GRADLE_USER_HOME/gradle.properties"
  if [[ -f /proc/meminfo ]]; then
    mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    mem_mb=$((mem_kb/1024))
  else mem_mb=2048; fi
  xmx=$((mem_mb*70/100))
  (( xmx > 4096 )) && xmx=4096
  sed -i '/org.gradle.jvmargs/d' "$PROPS" 2>/dev/null || true
  echo "org.gradle.jvmargs=-Xmx${xmx}m -Dfile.encoding=UTF-8" >> "$PROPS"
  ok "写入 $PROPS (-Xmx ${xmx}m)"
  INIT="$GRADLE_USER_HOME/init.gradle"
  cat > "$INIT" <<'EOF'
allprojects {
  repositories {
    maven { url 'https://maven.aliyun.com/repository/public/' }
    mavenLocal()
    mavenCentral()
    google()
  }
}
EOF
  ok "写入 Gradle init (镜像)"
}

# -------------------------
# Git clone (proxy options) and place selection
# -------------------------
clone_repo(){
  read -p "仓库 (user/repo 或 完整 URL): " repo_input
  [[ -z "$repo_input" ]] && { warn "取消"; return 1; }
  if [[ "$repo_input" =~ ^https?:// ]]; then repo_url="$repo_input"; else
    echo "是否使用镜像加速?"
    echo "1) gh-proxy.org   2) ghproxy.com   3) hub.fastgit.xyz   4) 自定义   5) 不使用"
    read -p "选择 [1-5]: " proxy
    case "$proxy" in
      1) base="https://gh-proxy.org/https://github.com/" ;;
      2) base="https://ghproxy.com/https://github.com/" ;;
      3) base="https://hub.fastgit.xyz/https://github.com/" ;;
      4) read -p "输入镜像前缀 (例如 https://myproxy/https://github.com/): " custom; base="$custom" ;;
      *) base="https://github.com/" ;;
    esac
    repo_url="${base}${repo_input}.git"
  fi

  load_config
  echo "选择存放位置 (默认: $PROJECT_BASE):"
  echo "1) 本地: $PROJECTS_LOCAL"
  if [[ "$IS_TERMUX" == "true" ]]; then echo "2) 共享: $PROJECTS_SDCARD"; fi
  echo "3) 自定义路径"
  read -p "选择 [Enter=默认]: " choice
  case "$choice" in
    2) target="$PROJECTS_SDCARD" ;;
    3) read -p "输入目标路径: " customp; target="$customp" ;;
    *) target="$PROJECTS_LOCAL" ;;
  esac
  ensure_dir "$target"
  save_config
  info "克隆到: $target"
  git clone "$repo_url" "$target/$(basename "$repo_input" .git)" || { err "git clone 失败"; return 1; }
  ok "克隆完成"
  cd "$target/$(basename "$repo_input" .git)" || return 0
  ok "已进入 $(pwd)"
  ensure_gradle_wrapper || true
  build_menu "$PWD"
}

# -------------------------
# Choose existing project
# -------------------------
choose_existing_project
