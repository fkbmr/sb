#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# -------------------------
# Basic helpers / cleanup
# -------------------------
trap 'rc=$?; [[ -n "${_TMPDIR:-}" ]] && rm -rf "${_TMPDIR}" 2>/dev/null || true; exit $rc' EXIT

_TMPDIR=$(mktemp -d -t mcdev.XXXXXX)
export TMPDIR="${TMPDIR:-$_TMPDIR}"

# Colors
RED="\033[1;31m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; BLUE="\033[1;34m"; CYAN="\033[1;36m"; RESET="\033[0m"
info(){ local IFS=' '; echo -e "${BLUE}[INFO]${RESET} $*"; }
ok()  { local IFS=' '; echo -e "${GREEN}[OK]${RESET} $*"; }
warn(){ local IFS=' '; echo -e "${YELLOW}[WARN]${RESET} $*" >&2; }
err() { local IFS=' '; echo -e "${RED}[ERR]${RESET} $*" >&2; }

# -------------------------
# Paths & globals
# -------------------------
BASE="${BASE:-$HOME/modpipeline}"
PROJECTS_LOCAL="${PROJECTS_LOCAL:-$HOME/projects}"
PROJECTS_SDCARD="${PROJECTS_SDCARD:-/sdcard/Projects}"
TOOLS_DIR="${TOOLS_DIR:-$BASE/tools}"
GRADLE_USER_HOME="${GRADLE_USER_HOME:-$HOME/.gradle}"
SDCARD_DOWNLOAD="${SDCARD_DOWNLOAD:-/sdcard/Download}"
ARCH="$(uname -m)"
IS_TERMUX="false"
IS_ANDROID="false"

# -------------------------
# Environment detection
# -------------------------
detect_termux() {
  if [[ -n "${TERMUX_VERSION-}" || "${PREFIX-}" == /data/data/com.termux* || -d "/data/data/com.termux" ]]; then
    IS_TERMUX="true"
    ok "Termux 环境检测通过"
  else
    IS_TERMUX="false"
  fi
}

detect_android() {
  if [[ -d /sdcard || -d /storage/emulated/0 || -d /data/data/com.termux ]]; then
    IS_ANDROID="true"
    ok "Android 环境检测通过"
  else
    IS_ANDROID="false"
  fi
}

detect_termux
detect_android

if [[ "$IS_ANDROID" == "true" ]]; then
    [[ ! -d /sdcard && -d /storage/emulated/0 ]] && PROJECTS_SDCARD="/storage/emulated/0/Projects"
fi

# -------------------------
# Package installer helper
# -------------------------
ensure_pkg_cmd() {
  if [[ "$IS_TERMUX" == "true" ]]; then
    echo "apt update && apt install -y"
    return 0
  fi
  if command -v apt >/dev/null 2>&1; then
    echo "apt update && apt install -y"   # proot debian 通常无需 sudo
    return 0
  fi
  if command -v dnf >/dev/null 2>&1; then
    echo "sudo dnf install -y"
    return 0
  elif command -v yum >/dev/null 2>&1; then
    echo "sudo yum install -y"
    return 0
  fi
  return 1
}
PKG_INSTALL_CMD="$(ensure_pkg_cmd || true)"

# -------------------------
# Utility
# -------------------------
ensure_dir(){ mkdir -p "$1"; }
run_and_log(){ local log="$1"; shift; set +e; "$@" 2>&1 | tee "$log"; rc=${PIPESTATUS[0]}; set -e; return $rc; }

# -------------------------
# Config load/save
# -------------------------
load_config(){
  if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
  fi
  if [[ -z "${PROJECT_BASE:-}" ]]; then
    if [[ "$IS_ANDROID" == "true" && -d "$PROJECTS_SDCARD" ]]; then
      PROJECT_BASE="$PROJECTS_SDCARD"
    else
      PROJECT_BASE="$PROJECTS_LOCAL"
    fi
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
# Storage hint (Termux only)
# -------------------------
check_storage_and_hint(){
  if [[ "$IS_TERMUX" == "true" ]]; then
    if [[ ! -d "$HOME/storage/shared" && ! -d /sdcard ]]; then
      warn "Termux 未挂载共享存储。"
      read -r -p "现在运行 termux-setup-storage 授权？(y/N): " yn
      [[ "$yn" =~ ^[Yy]$ ]] && command -v termux-setup-storage >/dev/null && termux-setup-storage || warn "跳过"
    fi
  fi
}

# -------------------------
# Basic tools
# -------------------------
ensure_basic_tools() {
    if [[ -z "$PKG_INSTALL_CMD" ]]; then
        warn "未检测到包管理命令，请手动安装：git wget curl unzip zip tar sed awk"
        return 1
    fi
    echo -e "\n开始检查基础工具..."
    local need=()
    for t in git wget curl unzip zip tar sed awk grep; do
      if ! command -v "$t" &>/dev/null; then need+=("$t"); fi
    done
    if [[ ${#need[@]} -eq 0 ]]; then
      ok "基础工具已齐全"
      return 0
    fi
    echo "将尝试安装: ${need[*]}"
    ( IFS=' '; bash -c "$PKG_INSTALL_CMD ${need[*]}" ) || warn "自动安装部分工具失败，请手动安装"
    ok "安装尝试完成"
}

# -------------------------
# JDK (unchanged)
# -------------------------
auto_install_jdk(){
  if command -v java >/dev/null 2>&1; then
    info "检测到 Java: $(java -version 2>&1 | head -n1)"
    read -r -p "保留现有 Java？(y/N): " keep
    [[ "$keep" =~ ^[Yy]$ ]] && return 0
  fi
  echo "请选择 JDK 版本：1)8  2)17(推荐)  3)21  4) 自定义  5) 取消"
  read -r -p "选择 [1-5]: " c
  case "$c" in
    1) ver=8 ;;
    2) ver=17 ;;
    3) ver=21 ;;
    4) read -r -p "URL 或本地路径: " src; install_custom_jdk "$src"; return ;;
    *) warn "取消"; return 1 ;;
  esac
  case "$ARCH" in
    aarch64|arm64) arch_dl="aarch64" ;;
    x86_64|amd64) arch_dl="x64" ;;
    *) arch_dl="x64" ;;
  esac
  dest="$HOME/jdk-$ver"
  ensure_dir "$dest"
  api_url="https://api.adoptium.net/v3/binary/latest/${ver}/ga/linux/${arch_dl}/jdk/hotspot/normal/eclipse"
  tmp="$TMPDIR/jdk${ver}.tar.gz"
  if ! wget -q --timeout=30 --tries=3 -O "$tmp" "$api_url" 2>/dev/null; then
    warn "官方 API 失败，尝试清华镜像..."
    mirror_url="https://mirrors.tuna.tsinghua.edu.cn/Adoptium/latest/jdk-${ver}u?os=linux&arch=${arch_dl}&type=jdk"
    if ! wget -q --timeout=30 --tries=3 -O "$tmp" "$mirror_url" 2>/dev/null; then
      warn "镜像失败，请使用自定义"
      read -r -p "URL/路径: " src
      [[ -z "$src" ]] && { warn "取消"; return 1; }
      install_custom_jdk "$src"
      return
    fi
  fi
  info "解压中..."
  local tmp_extract="$TMPDIR/jdk_extract"
  mkdir -p "$tmp_extract"
  tar -xzf "$tmp" -C "$tmp_extract" || { err "解压失败"; return 1; }
  local inner=$(ls -1 "$tmp_extract" | head -n1)
  if [[ -d "$tmp_extract/$inner" ]]; then
    mv "$tmp_extract/$inner"/* "$dest"/
  else
    mv "$tmp_extract"/* "$dest"/
  fi
  rm -rf "$tmp_extract" "$tmp"
  [[ ! -x "$dest/bin/java" ]] && { err "未找到 bin/java"; return 1; }
  local rcfile="$HOME/.bashrc"
  local marker="# mcdev jdk $ver"
  if ! grep -qF "$marker" "$rcfile" 2>/dev/null; then
    {
      echo ""
      echo "$marker"
      echo "export JAVA_HOME=\"$dest\""
      echo 'export PATH=$JAVA_HOME/bin:$PATH'
    } >> "$rcfile"
    ok "写入 $rcfile"
  fi
  export JAVA_HOME="$dest"; export PATH="$JAVA_HOME/bin:$PATH"
  ok "JDK $ver 安装完成"
}

install_custom_jdk(){
  local src="$1"
  [[ -z "$src" ]] && { err "未提供路径"; return 1; }
  if [[ "$src" =~ ^https?:// ]]; then
    tmp="$TMPDIR/custom_jdk_$(date +%s).tar.gz"
    wget -q --timeout=30 --tries=3 -O "$tmp" "$src" || { err "下载失败"; return 1; }
    src="$tmp"
  fi
  [[ ! -f "$src" ]] && { err "文件不存在: $src"; return 1; }
  dest="$HOME/jdk-custom-$(date +%s)"
  ensure_dir "$dest"
  case "$src" in
    *.tar.gz|*.tgz)
      local tmp_extract="$TMPDIR/jdk_extract_custom"
      mkdir -p "$tmp_extract"
      tar -xzf "$src" -C "$tmp_extract" || { err "解压失败"; return 1; }
      local inner=$(ls -1 "$tmp_extract" | head -n1)
      if [[ -d "$tmp_extract/$inner" ]]; then
        mv "$tmp_extract/$inner"/* "$dest"/
      else
        mv "$tmp_extract"/* "$dest"/
      fi
      rm -rf "$tmp_extract"
      ;;
    *.zip)
      unzip -q "$src" -d "$dest" || { err "解压失败"; return 1; }
      local inner=$(ls -1 "$dest" | head -n1)
      if [[ -d "$dest/$inner" ]]; then
        mv "$dest/$inner"/* "$dest"/
        rmdir "$dest/$inner"
      fi
      ;;
    *) err "不支持的格式"; return 1 ;;
  esac
  [[ ! -x "$dest/bin/java" ]] && { err "未找到 bin/java"; return 1; }
  local rcfile="$HOME/.bashrc"
  local marker="# mcdev custom jdk $dest"
  if ! grep -qF "$marker" "$rcfile" 2>/dev/null; then
    {
      echo ""
      echo "$marker"
      echo "export JAVA_HOME=\"$dest\""
      echo 'export PATH=$JAVA_HOME/bin:$PATH'
    } >> "$rcfile"
  fi
  export JAVA_HOME="$dest"; export PATH="$JAVA_HOME/bin:$PATH"
  ok "自定义 JDK 已安装"
}

# -------------------------
# Gradle helpers (fixes permission issue)
# -------------------------

# 智能执行 gradlew：自动检测是否需要通过 bash 调用
run_gradlew() {
  if [[ -f "./gradlew" ]]; then
    if [[ -x "./gradlew" ]]; then
      ./gradlew "$@"
    else
      # 无法直接执行时（如 /sdcard）使用 bash 解释执行
      bash ./gradlew "$@"
    fi
  else
    err "gradlew 不存在，请先生成"
    return 1
  fi
}

ensure_gradle_wrapper() {
  if [[ -f "./gradlew" ]]; then
    chmod +x ./gradlew 2>/dev/null || true
    ok "gradlew 已存在"
    return 0
  fi
  warn "gradlew 不存在，尝试生成 wrapper..."
  if ! command -v gradle >/dev/null 2>&1; then
    if [[ -n "$PKG_INSTALL_CMD" ]]; then
      bash -c "$PKG_INSTALL_CMD gradle" || warn "自动安装 gradle 失败"
    fi
  fi
  if command -v gradle >/dev/null 2>&1; then
    gradle wrapper || { err "生成失败"; return 1; }
    chmod +x ./gradlew 2>/dev/null || true
    ok "Gradle wrapper 生成完成"
    return 0
  fi
  warn "无法生成 gradle wrapper"
  return 1
}

install_gradle_from_zip(){
  read -r -p "Gradle ZIP 路径或 URL: " zippath
  [[ -z "$zippath" ]] && return 1
  zippath="${zippath/#\~/$HOME}"
  if [[ "$zippath" =~ ^https?:// ]]; then
    tmp="$TMPDIR/gradle_$(date +%s).zip"
    wget -q --timeout=60 --tries=3 -O "$tmp" "$zippath" || { err "下载失败"; return 1; }
    zippath="$tmp"
  fi
  [[ ! -f "$zippath" ]] && { err "文件不存在"; return 1; }
  dest="$HOME/.local/gradle"
  ensure_dir "$dest"
  unzip -q -o "$zippath" -d "$dest"
  local folder=$(ls -1 "$dest" | head -n1)
  if [[ -x "$dest/$folder/bin/gradle" ]]; then
    ensure_dir "$HOME/.local/bin"
    ln -sf "$dest/$folder/bin/gradle" "$HOME/.local/bin/gradle"
    if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
      export PATH="$HOME/.local/bin:$PATH"
      if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.bashrc"; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
      fi
      ok "已添加 PATH"
    fi
    ok "Gradle 已安装"
    return 0
  fi
  err "未找到 bin/gradle"
  return 1
}

# -------------------------
# Maven
# -------------------------
ensure_maven(){
  if command -v mvn >/dev/null 2>&1; then ok "Maven 已安装"; return 0; fi
  if [[ -n "$PKG_INSTALL_CMD" ]]; then
    bash -c "$PKG_INSTALL_CMD maven" || warn "安装失败"
  fi
}

# -------------------------
# Gradle optimization
# -------------------------
configure_gradle_optimization(){
  ensure_dir "$GRADLE_USER_HOME"
  local props="$GRADLE_USER_HOME/gradle.properties"
  if [[ -f /proc/meminfo ]]; then
    local mem_mb=$(($(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024))
  else mem_mb=2048; fi
  local xmx=$((mem_mb*70/100))
  (( xmx > 4096 )) && xmx=4096
  sed -i '/org.gradle.jvmargs/d' "$props" 2>/dev/null || true
  echo "org.gradle.jvmargs=-Xmx${xmx}m -Dfile.encoding=UTF-8" >> "$props"
  ok "Gradle 内存优化: ${xmx}m"
  cat > "$GRADLE_USER_HOME/init.gradle" <<'EOF'
allprojects {
  repositories {
    maven { url 'https://maven.aliyun.com/repository/public/' }
    mavenLocal()
    mavenCentral()
    google()
  }
}
EOF
  ok "Gradle 国内镜像已配置"
}

# -------------------------
# Git clone
# -------------------------
clone_repo(){
  read -p "仓库 (user/repo 或完整 URL): " repo_input
  [[ -z "$repo_input" ]] && return 1
  if [[ "$repo_input" =~ github\.com ]]; then
    repo_input="${repo_input%.git}"
    repo_input=$(echo "$repo_input" | sed -E 's|https?://(www\.)?github\.com/||')
  fi
  if [[ ! "$repo_input" =~ ^https?:// ]] && [[ ! "$repo_input" =~ ^[^/]+/[^/]+$ ]]; then
    err "格式错误"
    return 1
  fi
  if [[ "$repo_input" =~ ^https?:// ]]; then
    repo_url="$repo_input"
  else
    echo "选择镜像加速: 1) gh-proxy.org 2) ghproxy.com 3) hub.fastgit.xyz 4) 自定义 5) 官方源"
    read -p "选择 [1-5]: " proxy
    case $proxy in
      1) base="https://gh-proxy.org/https://github.com/" ;;
      2) base="https://ghproxy.com/https://github.com/" ;;
      3) base="https://hub.fastgit.xyz/" ;;
      4) read -p "输入前缀: " custom; [[ "$custom" != */ ]] && custom="${custom}/"; base="${custom}https://github.com/" ;;
      *) base="https://github.com/" ;;
    esac
    repo_url="${base}${repo_input}.git"
  fi
  load_config
  local default_target="${PROJECT_BASE:-$PROJECTS_LOCAL}"
  echo "存放位置 (默认: $default_target): 1) 本地 2) 共享 3) 自定义"
  read -p "选择 [Enter=默认]: " choice
  case $choice in
    2) target="${PROJECTS_SDCARD:-$default_target}" ;;
    3) read -p "输入路径: " customp; target="${customp:-$default_target}" ;;
    *) target="${PROJECTS_LOCAL:-$default_target}" ;;
  esac
  ensure_dir "$target"
  PROJECT_BASE="$target"
  save_config
  local repo_name=$(basename "$repo_input" .git)
  local target_path="$target/$repo_name"
  info "克隆到 $target_path"
  if [[ -d "$target_path" ]]; then
    read -p "已存在，删除并重新克隆？(y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] && rm -rf "$target_path" || { info "跳过克隆"; return 0; }
  fi
  git clone "$repo_url" "$target_path" || { err "克隆失败"; return 1; }
  ok "克隆完成"
  if cd "$target_path"; then
    build_menu "$PWD"
  fi
}

# -------------------------
# Select existing project
# -------------------------
choose_existing_project(){
  load_config
  local search_dirs=("$PROJECT_BASE")
  [[ -d "$PROJECTS_LOCAL" ]] && search_dirs+=("$PROJECTS_LOCAL")
  if [[ "$IS_ANDROID" == "true" ]]; then
    [[ -d "$PROJECTS_SDCARD" ]] && search_dirs+=("$PROJECTS_SDCARD")
    [[ -d "/sdcard/Projects" ]] && search_dirs+=("/sdcard/Projects")
  fi
  local dirs=()
  for base in "${search_dirs[@]}"; do
    for d in "$base"/*; do
      [[ -d "$d" ]] && dirs+=("$d")
    done
  done
  local unique_dirs=()
  for d in "${dirs[@]}"; do
    [[ ! " ${unique_dirs[*]} " =~ " ${d} " ]] && unique_dirs+=("$d")
  done
  dirs=("${unique_dirs[@]}")
  if [[ ${#dirs[@]} -eq 0 ]]; then
    warn "未找到项目"; return 1
  fi
  echo "请选择项目："
  select p in "${dirs[@]}" "取消"; do
    if [[ "$p" == "取消" || -z "$p" ]]; then
      return 1
    else
      build_menu "$p"
      break
    fi
  done
}

choose_existing_project_and_return_dir(){
  load_config
  local search_dirs=("$PROJECT_BASE")
  [[ -d "$PROJECTS_LOCAL" ]] && search_dirs+=("$PROJECTS_LOCAL")
  if [[ "$IS_ANDROID" == "true" ]]; then
    [[ -d "$PROJECTS_SDCARD" ]] && search_dirs+=("$PROJECTS_SDCARD")
    [[ -d "/sdcard/Projects" ]] && search_dirs+=("/sdcard/Projects")
  fi
  local dirs=()
  for base in "${search_dirs[@]}"; do
    for d in "$base"/*; do
      [[ -d "$d" ]] && dirs+=("$d")
    done
  done
  local unique_dirs=()
  for d in "${dirs[@]}"; do
    [[ ! " ${unique_dirs[*]} " =~ " ${d} " ]] && unique_dirs+=("$d")
  done
  dirs=("${unique_dirs[@]}")
  if [[ ${#dirs[@]} -eq 0 ]]; then
    warn "未找到项目"; return 1
  fi
  echo "请选择项目："
  select p in "${dirs[@]}" "取消"; do
    if [[ "$p" == "取消" || -z "$p" ]]; then
      return 1
    else
      echo "$p"
      return 0
    fi
  done
}

# -------------------------
# mod detection
# -------------------------
detect_mod_type(){
  local dir="$1"
  if [[ -f "$dir/fabric.mod.json" ]] || grep -qi "fabric-loom" "$dir"/build.gradle* 2>/dev/null; then echo "fabric"
  elif grep -qi "minecraftforge" "$dir"/build.gradle* 2>/dev/null || [[ -f "$dir/src/main/resources/META-INF/mods.toml" ]]; then echo "forge"
  elif [[ -d "$dir/mcp" || -f "$dir/conf/joined.srg" || -f "$dir/setup.sh" ]]; then echo "mcp"
  elif [[ -f "$dir/pom.xml" ]]; then echo "maven"
  elif [[ -f "$dir/build.gradle" || -f "$dir/gradlew" ]]; then echo "gradle"
  else echo "unknown"; fi
}

detect_mc_version(){
  local dir="$1"
  local ver=$(grep -E "minecraft_version|mc_version" "$dir/gradle.properties" 2>/dev/null | head -n1 | cut -d= -f2)
  [[ -z "$ver" && -f "$dir/fabric.mod.json" ]] && ver=$(grep -o '"minecraft": *"[^"]*"' "$dir/fabric.mod.json" | head -n1 | cut -d\" -f4)
  echo "${ver:-unknown}"
}

has_gradle_task(){
  (cd "$1" && run_gradlew tasks --all 2>/dev/null | grep -q "$2")
}

# -------------------------
# find & publish jar
# -------------------------
find_final_jar(){
  local dir="$1" type="$2"
  if [[ "$type" == "fabric" || "$type" == "quilt" ]]; then
    find "$dir/build" -type f \( -iname "*remapped*.jar" -o -iname "*mapped*.jar" \) 2>/dev/null | head -n1 || \
    find "$dir/build" -type f -iname "*.jar" ! -iname "*dev*" ! -iname "*sources*" 2>/dev/null | head -n1
  elif [[ "$type" == "forge" ]]; then
    find "$dir/build" -type f -iname "*reobf*.jar" 2>/dev/null | head -n1 || \
    find "$dir/build" -type f -iname "*.jar" ! -iname "*sources*" 2>/dev/null | head -n1
  else
    find "$dir/build" -type f -iname "*.jar" ! -iname "*sources*" ! -iname "*dev*" 2>/dev/null | head -n1
  fi
}

publish_release(){
  local dir="$1" jar="$2"
  ensure_dir "$dir/release"
  cp -f "$jar" "$dir/release/"
  ok "已发布到 $dir/release/$(basename "$jar")"
  if [[ "$IS_ANDROID" == "true" ]]; then
    mkdir -p "$SDCARD_DOWNLOAD" 2>/dev/null || true
    cp -f "$jar" "$SDCARD_DOWNLOAD/" 2>/dev/null || true
    ok "已复制到 Download 目录"
  fi
}

# -------------------------
# build diagnostics
# -------------------------
diagnose_build_failure(){
  local log="$1"
  warn "构建诊断："
  grep -qi "OutOfMemoryError" "$log" 2>/dev/null && echo "- 内存不足，请增加 Gradle 堆内存或清理缓存"
  grep -qi "Could not resolve" "$log" 2>/dev/null && echo "- 依赖下载失败，检查网络或更换镜像"
  grep -qi "Unsupported major.minor version" "$log" 2>/dev/null && echo "- Java 版本不匹配"
  echo "- 可尝试 ./gradlew clean && ./gradlew build --stacktrace"
}

# -------------------------
# Build (non-interactive)
# -------------------------
auto_build(){
  local dir="$1"
  cd "$dir" || return 1
  local modtype=$(detect_mod_type "$dir")
  local mcver=$(detect_mc_version "$dir")
  info "自动构建: $(basename "$dir") ($modtype, MC $mcver)"
  ensure_gradle_wrapper || true
  local build_log="$TMPDIR/build_$(date +%s).log"
  case "$modtype" in
    fabric|quilt)
      if has_gradle_task "$dir" "remapJar"; then
        run_and_log "$build_log" run_gradlew remapJar --no-daemon --stacktrace
      else
        run_and_log "$build_log" run_gradlew build --no-daemon --stacktrace
      fi ;;
    forge)
      run_and_log "$build_log" run_gradlew build --no-daemon --stacktrace
      has_gradle_task "$dir" "reobfJar" && run_and_log "$build_log" run_gradlew reobfJar --no-daemon --stacktrace ;;
    maven)
      run_and_log "$build_log" mvn package ;;
    *)
      run_and_log "$build_log" run_gradlew build --no-daemon --stacktrace ;;
  esac
  if [[ $? -ne 0 ]]; then
    err "构建失败，查看 $build_log"
    diagnose_build_failure "$build_log"
    return 1
  fi
  local jar=$(find_final_jar "$dir" "$modtype")
  if [[ -n "$jar" ]]; then
    publish_release "$dir" "$jar"
    echo "$jar"
    return 0
  else
    warn "未找到输出 jar"
    return 1
  fi
}

# -------------------------
# Interactive build menu
# -------------------------
build_menu(){
  local dir="$1"
  cd "$dir" || return 1
  info "项目: $dir"
  local modtype=$(detect_mod_type "$dir")
  local mcver=$(detect_mc_version "$dir")
  echo "类型: $modtype   MC: $mcver"
  ensure_gradle_wrapper || true

  echo ""
  echo "1) 智能构建"
  echo "2) Clean"
  echo "3) 下载依赖"
  echo "4) 生成 Gradle Wrapper"
  echo "5) 构建并发布 (自动复制到 release)"
  echo "6) 返回"
  read -r -p "选择: " opt
  local build_log="$TMPDIR/build_$(date +%s).log"
  case "$opt" in
    1)
      if [[ "$modtype" == "fabric" || "$modtype" == "quilt" ]]; then
        if has_gradle_task "$dir" "remapJar"; then
          run_and_log "$build_log" run_gradlew remapJar --no-daemon --stacktrace
        else
          run_and_log "$build_log" run_gradlew build --no-daemon --stacktrace
        fi
      elif [[ "$modtype" == "forge" ]]; then
        run_and_log "$build_log" run_gradlew build --no-daemon --stacktrace
        has_gradle_task "$dir" "reobfJar" && run_and_log "$build_log" run_gradlew reobfJar --no-daemon --stacktrace
      else
        run_and_log "$build_log" run_gradlew build --no-daemon --stacktrace
      fi
      if [[ $? -ne 0 ]]; then
        err "构建失败"; diagnose_build_failure "$build_log"; return 1
      fi
      local finaljar=$(find_final_jar "$dir" "$modtype")
      [[ -n "$finaljar" ]] && publish_release "$dir" "$finaljar" || warn "未找到 jar"
      ;;
    2) run_and_log "$build_log" run_gradlew clean; ok "Clean 完成" ;;
    3) run_and_log "$build_log" run_gradlew dependencies --no-daemon; ok "依赖下载完成" ;;
    4) ensure_gradle_wrapper ;;
    5) run_and_log "$build_log" run_gradlew build --no-daemon --stacktrace
       if [[ $? -ne 0 ]]; then err "构建失败"; diagnose_build_failure "$build_log"; return 1; fi
       local jar=$(find_final_jar "$dir" "$modtype")
       [[ -n "$jar" ]] && publish_release "$dir" "$jar" || err "未找到 jar" ;;
    *) ;;
  esac
}

# -------------------------
# Batch build
# -------------------------
batch_build_all(){
  load_config
  ensure_dir "$PROJECT_BASE"
  ok "批量构建 $PROJECT_BASE ..."
  local success=() fail=()
  for d in "$PROJECT_BASE"/*; do
    [[ -d "$d" ]] || continue
    if auto_build "$d" &>/dev/null; then
      success+=("$(basename "$d")")
    else
      fail+=("$(basename "$d")")
    fi
  done
  ok "完成：成功 ${success[*]}   失败 ${fail[*]}"
}

# -------------------------
# Main menu
# -------------------------
main_menu(){
  load_config
  check_storage_and_hint
  ensure_basic_tools || warn "基础工具安装失败，继续运行"
  configure_gradle_optimization
  ensure_dir "$TOOLS_DIR" "$BASE/release"

  if [[ ! -d "$PROJECT_BASE" && "$IS_ANDROID" == "true" && -d "$PROJECTS_SDCARD" ]]; then
    warn "PROJECT_BASE 不存在，是否使用 Android 共享目录？"
    read -p "使用 $PROJECTS_SDCARD？(Y/n): " ans
    if [[ ! "$ans" =~ ^[Nn] ]]; then
      PROJECT_BASE="$PROJECTS_SDCARD"
      save_config
    fi
  fi

  while true; do
    echo ""
    echo -e "${CYAN}=== MCDev Pipeline (Android/Debian) ===${RESET}"
    echo "Project base: $PROJECT_BASE"
    echo "1) 克隆 GitHub 项目"
    echo "2) 选择已有项目构建"
    echo "3) JDK 安装 / 导入"
    echo "4) 安装 Gradle (ZIP)"
    echo "5) 安装 Maven"
    echo "6) 下载 Fabric MDK"
    echo "7) 下载 Forge MDK"
    echo "8) 生成 Gradle Wrapper"
    echo "9) 批量构建所有项目"
    echo "10) 清理 Gradle 缓存"
    echo "11) 设置 PROJECT_BASE"
    echo "0) 退出"
    read -r -p "选择: " opt
    case "$opt" in
      1) clone_repo ;;
      2) choose_existing_project ;;
      3) auto_install_jdk ;;
      4) install_gradle_from_zip ;;
      5) ensure_maven ;;
      6) download_fabric_mdk ;;
      7) download_forge_mdk ;;
      8) read -p "项目路径 (空=当前目录): " p; cd "${p:-.}"; ensure_gradle_wrapper ;;
      9) batch_build_all ;;
      10) clear_gradle_cache ;;
      11) echo "当前: $PROJECT_BASE"; read -p "新路径: " newp; [[ -n "$newp" ]] && { PROJECT_BASE="$newp"; save_config; } ;;
      0) info "退出"; exit 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

ensure_dir "$BASE" "$TOOLS_DIR" "$PROJECTS_LOCAL"
load_config
main_menu
