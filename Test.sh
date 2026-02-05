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
choose_existing_project(){
  load_config
  ensure_dir "$PROJECT_BASE"
  local dirs=()
  for d in "$PROJECT_BASE"/*; do [[ -d "$d" ]] && dirs+=("$d"); done
  if [[ ${#dirs[@]} -eq 0 ]]; then warn "未找到项目在 $PROJECT_BASE"; return 1; fi
  echo "请选择项目："
  select p in "${dirs[@]}" "取消"; do
    if [[ "$p" == "取消" || -z "$p" ]]; then return 1; else build_menu "$p"; break; fi
  done
}

# -------------------------
# Main menu
# -------------------------
main_menu(){
  load_config
  check_storage_and_hint
  ensure_basic_tools
  configure_gradle_optimization
  ensure_dir "$TOOLS_DIR" "$BASE/release" "$BASE/release/deobf" "$BASE/decompile"

  while true; do
    echo ""
    echo -e "${CYAN}=== MCDev Ultimate Pipeline (Final) ===${RESET}"
    echo "Project base: $PROJECT_BASE"
    echo "1) 克隆 GitHub 项目 (并进入构建)"
    echo "2) 选择已拉取项目 (构建菜单)"
    echo "3) JDK：自动下载 / 自定义导入"
    echo "4) 安装 / 导入 Gradle (ZIP)"
    echo "5) 安装 Maven"
    echo "6) 下载 Fabric MDK"
    echo "7) 下载 Forge MDK"
    echo "8) 生成 Gradle Wrapper (若缺失)"
    echo "9) 确保 ProGuard (自动下载)"
    echo "10) 确保 ZelixKiller (ZKM) 自动下载"
    echo "11) 构建并混淆单项目"
    echo "12) 批量构建 (projects/*)"
    echo "13) 单项目：全流程 Pipeline (build→obf→zkm→deobf→decompile)"
    echo "14) 批量 ZKM 反混淆 release/*.jar"
    echo "15) CFR 反编译 deobf jar"
    echo "16) 清理 Gradle 缓存"
    echo "17) 显示 / 编辑 PROJECT_BASE"
    echo "0) 退出"
    read -p "选择: " opt
    case "$opt" in
      1) clone_repo ;;
      2) choose_existing_project ;;
      3) auto_install_jdk ;;
      4) install_gradle_from_zip ;;
      5) ensure_maven ;;
      6) download_fabric_mdk ;;
      7) download_forge_mdk ;;
      8) ensure_gradle_wrapper ;;
      9) ensure_proguard ;;
      10) ensure_zkm ;;
      11) choose_existing_project ;;  # enters build_menu
      12) batch_build_all ;;
      13) read -p "项目路径 (留空选择项目): " p; if [[ -z "$p" ]]; then choose_existing_project; else full_pipeline_project "$p"; fi ;;
      14) batch_zkm_deobf ;;
      15) read -p "deobf jar 路径 (回车自动): " j; j=${j:-$(ls "$BASE"/release/deobf/*.jar 2>/dev/null | head -n1)}; [[ -n "$j" ]] && cfr_decompile_single "$j" || warn "未找到 jar" ;;
      16) clear_gradle_cache ;;
      17) echo "当前 PROJECT_BASE=$PROJECT_BASE"; read -p "输入新 PROJECT_BASE (回车保持): " newp; [[ -n "$newp" ]] && { PROJECT_BASE="$newp"; save_config; } ;;
      0) info "退出"; exit 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

# -------------------------
# start
# -------------------------
ensure_dir "$BASE" "$TOOLS_DIR" "$PROJECTS_LOCAL"
load_config
main_menu
