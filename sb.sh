#!/usr/bin/env bash

# ============================================================================
# 系统配置脚本：安装 .NET SDK、Git 和中文支持
# 版本: 2.0
# 作者: AI Assistant
# ============================================================================

set -euo pipefail  # 严格的错误处理
IFS=$'\n\t'

# ============================================================================
# 配置常量
# ============================================================================

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="/tmp/${SCRIPT_NAME}.$(date +%Y%m%d_%H%M%S).log"
readonly DOTNET_INSTALL_SCRIPT="https://dot.net/v1/dotnet-install.sh"
readonly REQUIRED_PACKAGES=("libicu-dev" "git" "curl" "wget" "ca-certificates")
readonly CHINESE_PACKAGES=("locales" "fonts-wqy-zenhei" "fcitx" "fcitx-googlepinyin" 
                          "fcitx-module-cloudpinyin" "fcitx-sunpinyin" "im-config")
readonly SUPPORTED_DISTROS=("ubuntu" "debian" "linuxmint")

# ============================================================================
# 颜色和样式定义
# ============================================================================

readonly COLOR_RESET='\033[0m'
readonly COLOR_BOLD='\033[1m'
readonly COLOR_DIM='\033[2m'

# 前景色
readonly COLOR_BLACK='\033[30m'
readonly COLOR_RED='\033[31m'
readonly COLOR_GREEN='\033[32m'
readonly COLOR_YELLOW='\033[33m'
readonly COLOR_BLUE='\033[34m'
readonly COLOR_MAGENTA='\033[35m'
readonly COLOR_CYAN='\033[36m'
readonly COLOR_WHITE='\033[37m'

# 背景色
readonly BG_RED='\033[41m'
readonly BG_GREEN='\033[42m'
readonly BG_YELLOW='\033[43m'
readonly BG_BLUE='\033[44m'

# 图标
readonly ICON_SUCCESS="✓"
readonly ICON_ERROR="✗"
readonly ICON_INFO="ℹ"
readonly ICON_WARN="⚠"
readonly ICON_QUESTION="?"

# ============================================================================
# 实用函数
# ============================================================================

# 日志记录函数
log() {
    local level="$1"
    local message="$2"
    local color=""
    local icon=""
    
    case "$level" in
        "SUCCESS") color="${COLOR_GREEN}"; icon="${ICON_SUCCESS}" ;;
        "ERROR") color="${COLOR_RED}"; icon="${ICON_ERROR}" ;;
        "WARN") color="${COLOR_YELLOW}"; icon="${ICON_WARN}" ;;
        "INFO") color="${COLOR_CYAN}"; icon="${ICON_INFO}" ;;
        "DEBUG") color="${COLOR_DIM}"; icon="•" ;;
        *) color="${COLOR_RESET}"; icon="" ;;
    esac
    
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local log_entry="[$timestamp] [$level] $message"
    
    # 输出到控制台（带颜色）
    if [[ "$level" == "DEBUG" && "${DEBUG:-false}" != "true" ]]; then
        # 仅在调试模式下显示调试信息
        :
    else
        echo -e "${color}${icon} ${message}${COLOR_RESET}"
    fi
    
    # 写入日志文件（无颜色）
    echo "$log_entry" >> "$LOG_FILE"
}

# 带样式的输出函数
print_header() {
    echo -e "\n${COLOR_BOLD}${COLOR_CYAN}╔══════════════════════════════════════════════════════════╗${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_CYAN}║$COLOR_RESET ${COLOR_BOLD}$1${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_CYAN}╚══════════════════════════════════════════════════════════╝${COLOR_RESET}\n"
}

print_step() {
    echo -e "\n${COLOR_BOLD}${COLOR_BLUE}[$(printf "%02d" $1)]${COLOR_RESET} ${COLOR_BOLD}$2${COLOR_RESET}"
    log "INFO" "步骤 $1: $2"
}

print_status() {
    local status="$1"
    local message="$2"
    
    case "$status" in
        "ok") echo -e "  [${COLOR_GREEN} OK ${COLOR_RESET}] $message" ;;
        "fail") echo -e "  [${COLOR_RED}FAIL${COLOR_RESET}] $message" ;;
        "skip") echo -e "  [${COLOR_YELLOW}SKIP${COLOR_RESET}] $message" ;;
    esac
}

# 进度条函数
show_progress() {
    local duration="$1"
    local message="$2"
    local width=50
    local increment=$((100 / width))
    
    echo -ne "${message} ["
    for ((i=0; i<width; i++)); do
        echo -ne " "
    done
    echo -ne "] 0%\r"
    
    for ((i=0; i<width; i++)); do
        sleep "$(echo "$duration / $width" | bc -l)"
        echo -ne "${COLOR_GREEN}█${COLOR_RESET}"
        printf " %3d%%\r" $(( (i+1) * increment ))
    done
    echo -ne "\n"
}

# ============================================================================
# 检查函数
# ============================================================================

check_distribution() {
    log "INFO" "检查系统发行版..."
    
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        local distro="${ID:-unknown}"
        local version="${VERSION_ID:-unknown}"
        
        log "INFO" "检测到系统: $NAME $VERSION (ID: $distro, 版本: $version)"
        
        # 检查是否支持此发行版
        local supported=false
        for supported_distro in "${SUPPORTED_DISTROS[@]}"; do
            if [[ "$distro" == "$supported_distro" ]]; then
                supported=true
                break
            fi
        done
        
        if [[ "$supported" == false ]]; then
            log "WARN" "此脚本主要针对 Ubuntu/Debian 系统测试"
            if ! ask_confirm "继续安装？"; then
                exit 1
            fi
        fi
        
        return 0
    else
        log "ERROR" "无法检测系统发行版"
        return 1
    fi
}

check_root() {
    log "INFO" "检查用户权限..."
    
    if [[ $EUID -eq 0 ]]; then
        log "SUCCESS" "当前用户: root"
        return 0
    else
        log "WARN" "当前用户不是 root"
        
        if [[ "$1" == "--require" ]]; then
            log "ERROR" "此操作需要 root 权限"
            echo -e "${COLOR_YELLOW}请使用以下命令重新运行：${COLOR_RESET}"
            echo -e "  sudo $0 $*"
            exit 1
        fi
        
        if ask_confirm "部分操作需要 root 权限。继续？"; then
            return 0
        else
            exit 1
        fi
    fi
}

check_network() {
    log "INFO" "检查网络连接..."
    
    if ping -c 1 -W 2 8.8.8.8 > /dev/null 2>&1; then
        log "SUCCESS" "网络连接正常"
        return 0
    else
        log "ERROR" "网络连接失败"
        return 1
    fi
}

check_existing_dotnet() {
    log "INFO" "检查已安装的 .NET..."
    
    if command -v dotnet > /dev/null 2>&1; then
        local existing_version
        existing_version=$(dotnet --version 2>/dev/null || echo "未知")
        log "INFO" "已安装 .NET 版本: $existing_version"
        
        if ask_confirm "已安装 .NET $existing_version。是否继续安装？"; then
            return 0
        else
            return 1
        fi
    fi
    
    return 0
}

# ============================================================================
# 交互函数
# ============================================================================

ask_confirm() {
    local question="$1"
    local default="${2:-n}"
    
    while true; do
        if [[ "$default" == "y" ]]; then
            echo -ne "${COLOR_BOLD}$question${COLOR_RESET} [${COLOR_GREEN}Y${COLOR_RESET}/n] "
            read -r -p "" response
            case "${response:-y}" in
                [Yy]* ) return 0 ;;
                [Nn]* ) return 1 ;;
                * ) echo "请输入 y 或 n" ;;
            esac
        else
            echo -ne "${COLOR_BOLD}$question${COLOR_RESET} [y/${COLOR_RED}N${COLOR_RESET}] "
            read -r -p "" response
            case "${response:-n}" in
                [Yy]* ) return 0 ;;
                [Nn]* ) return 1 ;;
                * ) echo "请输入 y 或 n" ;;
            esac
        fi
    done
}

ask_input() {
    local prompt="$1"
    local default="${2:-}"
    local response=""
    
    if [[ -n "$default" ]]; then
        echo -ne "${COLOR_BOLD}$prompt${COLOR_RESET} [默认: $default] "
        read -r response
        echo "${response:-$default}"
    else
        echo -ne "${COLOR_BOLD}$prompt${COLOR_RESET} "
        read -r response
        echo "$response"
    fi
}

# ============================================================================
# 安装函数
# ============================================================================

update_system() {
    print_step 1 "更新系统包列表"
    
    if ! apt-get update >> "$LOG_FILE" 2>&1; then
        log "ERROR" "更新包列表失败"
        return 1
    fi
    
    log "SUCCESS" "系统包列表更新完成"
    return 0
}

install_required_packages() {
    print_step 2 "安装必要依赖包"
    
    local packages_to_install=()
    
    for package in "${REQUIRED_PACKAGES[@]}"; do
        if dpkg -l "$package" > /dev/null 2>&1; then
            log "INFO" "已安装: $package"
        else
            packages_to_install+=("$package")
        fi
    done
    
    if [[ ${#packages_to_install[@]} -eq 0 ]]; then
        log "INFO" "所有必要依赖包已安装"
        return 0
    fi
    
    log "INFO" "将安装以下包: ${packages_to_install[*]}"
    
    if ! apt-get install -y "${packages_to_install[@]}" >> "$LOG_FILE" 2>&1; then
        log "ERROR" "安装依赖包失败"
        return 1
    fi
    
    log "SUCCESS" "必要依赖包安装完成"
    return 0
}

install_dotnet_sdk() {
    print_step 3 "安装 .NET SDK"
    
    # 检查是否已安装
    check_existing_dotnet || return 0
    
    # 询问安装版本
    local version=""
    echo -e "${COLOR_CYAN}可用的 .NET 版本：${COLOR_RESET}"
    echo "1) 最新 LTS 版本 (推荐)"
    echo "2) 最新稳定版"
    echo "3) 指定版本"
    echo "4) 跳过 .NET 安装"
    
    local choice
    choice=$(ask_input "请选择 [1-4]" "1")
    
    case "$choice" in
        1)
            version="LTS"
            log "INFO" "选择安装最新 LTS 版本"
            ;;
        2)
            version=""
            log "INFO" "选择安装最新稳定版"
            ;;
        3)
            version=$(ask_input "请输入版本号 (例如: 8.0.100)")
            if [[ -z "$version" ]]; then
                log "ERROR" "未指定版本号"
                return 1
            fi
            log "INFO" "选择安装指定版本: $version"
            ;;
        4)
            log "INFO" "跳过 .NET 安装"
            return 0
            ;;
        *)
            log "ERROR" "无效选择"
            return 1
            ;;
    esac
    
    # 下载安装脚本
    log "INFO" "下载 .NET 安装脚本..."
    local install_args=()
    
    if [[ "$version" == "LTS" ]]; then
        install_args=("--channel" "LTS")
    elif [[ -n "$version" && "$version" != "LTS" ]]; then
        install_args=("--version" "$version")
    fi
    
    # 执行安装
    log "INFO" "正在安装 .NET SDK..."
    show_progress 2 "安装 .NET SDK"
    
    if curl -sSL "$DOTNET_INSTALL_SCRIPT" | bash -s -- "${install_args[@]}" >> "$LOG_FILE" 2>&1; then
        log "SUCCESS" ".NET SDK 安装成功"
    else
        log "ERROR" ".NET SDK 安装失败"
        return 1
    fi
    
    return 0
}

configure_environment() {
    print_step 4 "配置环境变量"
    
    local bashrc_file="$HOME/.bashrc"
    local export_line='export PATH="$HOME/.dotnet:$PATH"'
    
    # 检查是否已配置
    if grep -q "export PATH.*\.dotnet" "$bashrc_file" 2>/dev/null; then
        log "INFO" "环境变量已配置"
        return 0
    fi
    
    # 添加到 .bashrc
    echo "" >> "$bashrc_file"
    echo "# .NET SDK" >> "$bashrc_file"
    echo "$export_line" >> "$bashrc_file"
    
    # 添加到当前会话
    export PATH="$HOME/.dotnet:$PATH"
    
    log "SUCCESS" "环境变量配置完成"
    
    # 检查其他shell配置文件
    for shell_file in "$HOME/.zshrc" "$HOME/.profile"; do
        if [[ -f "$shell_file" && ! -L "$shell_file" ]]; then
            if ! grep -q "export PATH.*\.dotnet" "$shell_file"; then
                if ask_confirm "是否也添加到 $shell_file？"; then
                    echo "" >> "$shell_file"
                    echo "# .NET SDK" >> "$shell_file"
                    echo "$export_line" >> "$shell_file"
                    log "INFO" "已添加到 $shell_file"
                fi
            fi
        fi
    done
    
    return 0
}

install_chinese_support() {
    print_step 5 "安装中文支持"
    
    if ! ask_confirm "是否安装中文支持（输入法、字体等）？"; then
        log "INFO" "跳过中文支持安装"
        return 0
    fi
    
    log "INFO" "安装中文支持包..."
    
    # 安装包
    if ! apt-get install -y "${CHINESE_PACKAGES[@]}" >> "$LOG_FILE" 2>&1; then
        log "ERROR" "安装中文支持包失败"
        return 1
    fi
    
    # 配置区域设置
    log "INFO" "配置区域设置..."
    
    # 自动配置常用区域
    local locales_to_enable=("en_US.UTF-8 UTF-8" "zh_CN.UTF-8 UTF-8" "zh_CN.GBK GBK")
    
    for locale in "${locales_to_enable[@]}"; do
        if ! grep -q "^$locale" /etc/locale.gen 2>/dev/null; then
            echo "$locale" >> /etc/locale.gen
        fi
    done
    
    # 生成区域设置
    locale-gen >> "$LOG_FILE" 2>&1
    
    # 设置默认区域
    update-locale LANG=en_US.UTF-8 >> "$LOG_FILE" 2>&1
    
    log "SUCCESS" "中文支持安装完成"
    
    # 显示说明
    echo -e "\n${COLOR_YELLOW}中文支持说明：${COLOR_RESET}"
    echo "1. 字体已安装：文泉驿正黑"
    echo "2. 输入法已安装：fcitx (含谷歌拼音、太阳拼音)"
    echo "3. 重新登录后，可在系统设置中配置输入法"
    
    return 0
}

verify_installation() {
    print_step 6 "验证安装结果"
    
    echo -e "\n${COLOR_CYAN}验证安装结果：${COLOR_RESET}"
    
    # 验证 .NET
    if command -v dotnet > /dev/null 2>&1; then
        local dotnet_version
        dotnet_version=$(dotnet --version 2>/dev/null || echo "未知")
        print_status "ok" ".NET SDK: $dotnet_version"
    else
        print_status "fail" ".NET SDK: 未找到"
    fi
    
    # 验证 Git
    if command -v git > /dev/null 2>&1; then
        local git_version
        git_version=$(git --version 2>/dev/null | head -n1)
        print_status "ok" "Git: $git_version"
    else
        print_status "fail" "Git: 未找到"
    fi
    
    # 验证必要依赖
    for package in "${REQUIRED_PACKAGES[@]}"; do
        if dpkg -l "$package" > /dev/null 2>&1; then
            print_status "ok" "$package: 已安装"
        else
            print_status "fail" "$package: 未安装"
        fi
    done
    
    echo -e "\n${COLOR_GREEN}安装日志：${COLOR_RESET} $LOG_FILE"
}

# ============================================================================
# 清理函数
# ============================================================================

cleanup() {
    print_step 7 "清理临时文件"
    
    # 清理 apt 缓存
    if [[ "${CLEANUP:-true}" == "true" ]]; then
        log "INFO" "清理 apt 缓存..."
        apt-get clean >> "$LOG_FILE" 2>&1
        apt-get autoclean >> "$LOG_FILE" 2>&1
        
        log "SUCCESS" "清理完成"
    else
        log "INFO" "跳过清理步骤"
    fi
}

# ============================================================================
# 显示帮助
# ============================================================================

show_help() {
    cat << EOF
${COLOR_BOLD}系统配置脚本 v${SCRIPT_VERSION}${COLOR_RESET}

用法: $0 [选项]

选项:
  -h, --help          显示此帮助信息
  -v, --version       显示版本信息
  -d, --debug         启用调试模式
  --no-cleanup        安装后不清理临时文件
  --skip-dotnet       跳过 .NET 安装
  --skip-chinese      跳过中文支持安装
  --minimal           最小化安装（仅 .NET 和 Git）
  
示例:
  $0                    # 交互式安装所有组件
  $0 --minimal         # 仅安装 .NET 和 Git
  sudo $0              # 以 root 权限运行
  
支持的发行版:
  ${SUPPORTED_DISTROS[*]}
EOF
}

show_version() {
    echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"
}

# ============================================================================
# 主函数
# ============================================================================

main() {
    # 解析命令行参数
    local skip_dotnet=false
    local skip_chinese=false
    local minimal_install=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                show_version
                exit 0
                ;;
            -d|--debug)
                DEBUG=true
                set -x
                shift
                ;;
            --no-cleanup)
                CLEANUP=false
                shift
                ;;
            --skip-dotnet)
                skip_dotnet=true
                shift
                ;;
            --skip-chinese)
                skip_chinese=true
                shift
                ;;
            --minimal)
                minimal_install=true
                skip_chinese=true
                shift
                ;;
            *)
                log "ERROR" "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # 显示欢迎信息
    print_header "系统配置脚本 v${SCRIPT_VERSION}"
    
    # 记录开始时间
    local start_time
    start_time=$(date +%s)
    
    # 执行检查
    check_distribution || exit 1
    check_root || exit 1
    check_network || exit 1
    
    # 执行安装步骤
    update_system || exit 1
    install_required_packages || exit 1
    
    if [[ "$skip_dotnet" == false ]]; then
        install_dotnet_sdk || exit 1
        configure_environment || exit 1
    fi
    
    if [[ "$minimal_install" == false && "$skip_chinese" == false ]]; then
        install_chinese_support || exit 1
    fi
    
    # 验证安装
    verify_installation
    
    # 清理
    cleanup
    
    # 计算运行时间
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    # 显示完成信息
    echo -e "\n${COLOR_BOLD}${COLOR_GREEN}══════════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_GREEN}  安装完成！用时 ${duration} 秒${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_GREEN}══════════════════════════════════════════════════════════${COLOR_RESET}"
    
    echo -e "\n${COLOR_BOLD}下一步：${COLOR_RESET}"
    echo "1. 重新打开终端或运行: ${COLOR_CYAN}source ~/.bashrc${COLOR_RESET}"
    echo "2. 验证 .NET: ${COLOR_CYAN}dotnet --info${COLOR_RESET}"
    echo "3. 查看日志: ${COLOR_CYAN}cat $LOG_FILE${COLOR_RESET}"
    
    if [[ "$skip_chinese" == false ]]; then
        echo -e "\n${COLOR_YELLOW}注意：${COLOR_RESET}中文输入法需要重新登录才能生效"
    fi
    
    echo -e "\n${COLOR_DIM}问题反馈请查看日志文件: $LOG_FILE${COLOR_RESET}"
}

# ============================================================================
# 异常处理
# ============================================================================

handle_error() {
    local exit_code="$?"
    local line_number="$1"
    local command="$2"
    
    log "ERROR" "脚本在第 ${line_number} 行执行失败: ${command}"
    log "ERROR" "退出代码: ${exit_code}"
    
    echo -e "\n${COLOR_RED}══════════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_RED}  安装失败！请检查日志文件：${COLOR_RESET}"
    echo -e "${COLOR_RED}  $LOG_FILE${COLOR_RESET}"
    echo -e "${COLOR_RED}══════════════════════════════════════════════════════════${COLOR_RESET}"
    
    exit "$exit_code"
}

# 设置错误处理
trap 'handle_error ${LINENO} "$BASH_COMMAND"' ERR

# ============================================================================
# 脚本入口
# ============================================================================

# 确保脚本不在管道中运行
if [[ -t 0 ]]; then
    main "$@"
else
    log "ERROR" "此脚本需要交互式终端"
    exit 1
fi