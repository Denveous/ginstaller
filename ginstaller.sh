#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

if [[ -t 1 ]] && [[ -n "$TERM" ]] && [[ "$TERM" != "dumb" ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly PURPLE='\033[0;35m'
    readonly CYAN='\033[0;36m'
    readonly WHITE='\033[1;37m'
    readonly NC='\033[0m'
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly PURPLE=''
    readonly CYAN=''
    readonly WHITE=''
    readonly NC=''
fi
readonly BASE_INDENT="           "

readonly DEFAULT_COMPILE_DIR="/root/git"
readonly DEFAULT_OUTPUT_DIR_LISTSERVER="/root/Listserver"
readonly DEFAULT_OUTPUT_DIR_GSERVER="/root/GServer"
readonly DEFAULT_OUTPUT_DIR_NEWPROTOCOL="/root/GServerNP"
readonly DEFAULT_OUTPUT_DIR_BETA4="/root/GServerBeta"
readonly DEFAULT_DVER_EXTRA="custom"

COMPILE_DIR="$DEFAULT_COMPILE_DIR"
OUTPUT_DIR_LISTSERVER="$DEFAULT_OUTPUT_DIR_LISTSERVER"
OUTPUT_DIR_GSERVER="$DEFAULT_OUTPUT_DIR_GSERVER"
OUTPUT_DIR_NEWPROTOCOL="$DEFAULT_OUTPUT_DIR_NEWPROTOCOL"
OUTPUT_DIR_BETA4="$DEFAULT_OUTPUT_DIR_BETA4"
DVER_EXTRA="$DEFAULT_DVER_EXTRA"

DEPS_INSTALLED_BASE=false
DEPS_INSTALLED_LISTSERVER=false
DEPS_INSTALLED_GSERVER=false
BUILD_LOG="/tmp/ginstaller_$(date +%Y%m%d_%H%M%S).log"
PARALLEL_JOBS=$(nproc)
CLEAN_INSTALL=false
APPLY_LISTSERVER_PATCH=false

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$BUILD_LOG"
}

error_exit() {
    echo -e "${RED}${BASE_INDENT}❌ ERROR: $1${NC}" >&2
    log "ERROR: $1"
    cleanup_and_exit
}

cleanup_and_exit() {
    echo -e "\n${RED}${BASE_INDENT}🛑${WHITE} Build interrupted. Cleaning up...${NC}"
    jobs -p | xargs -r kill 2>/dev/null || true
    wait 2>/dev/null || true
    echo -e "${CYAN}${BASE_INDENT}📋${WHITE} Build log saved to: $BUILD_LOG${NC}"
    exit 1
}

trap cleanup_and_exit SIGINT SIGTERM ERR

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

show_spinner() {
    local message="$1"
    local pid="$2"
    local spin='⣾⣽⣻⢿⡿⣟⣯⣷'
    local i=0
    tput civis 2>/dev/null || true
    
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i+1) % ${#spin} ))
        echo -ne "\033[2K\r${BASE_INDENT}${message} ${spin:$i:1}"
        sleep 0.1
        
        if read -t 0.01 -n 1 key 2>/dev/null; then
            [[ "$key" =~ ^[qQ]$ ]] && { kill "$pid" 2>/dev/null; cleanup_and_exit; }
        fi
    done
    
    wait "$pid"
    local exit_code=$?
    
    tput cnorm 2>/dev/null || true
    
    if [[ $exit_code -eq 0 ]]; then
        echo -e "\033[2K\r${BASE_INDENT}${message} ✓  ${NC}"
    else
        echo -e "\033[2K\r${BASE_INDENT}${message} ✗  ${NC}"
        error_exit "Process failed with exit code $exit_code. Check $BUILD_LOG for details"
    fi
}

install_base_deps() {
    [[ "$DEPS_INSTALLED_BASE" == true ]] && return
    
    log "Installing base dependencies"
    { apt update && apt install -y build-essential cmake git; } >> "$BUILD_LOG" 2>&1 &
    show_spinner "${PURPLE}📦${WHITE} Installing base dependencies" $!
    DEPS_INSTALLED_BASE=true
}

install_listserver_deps() {
    [[ "$DEPS_INSTALLED_LISTSERVER" == true ]] && return
    
    log "Installing Listserver dependencies"
    apt install -y g++-10 libc6-dev gcc-multilib libc++-dev libstdc++-10-dev cmake git >> "$BUILD_LOG" 2>&1 &
    show_spinner "${PURPLE}📦${WHITE} Installing Listserver dependencies" $!
    DEPS_INSTALLED_LISTSERVER=true
}

install_gserver_deps() {
    [[ "$DEPS_INSTALLED_GSERVER" == true ]] && return
    log "Installing GServer dependencies"
    echo -e "${PURPLE}${BASE_INDENT}📦${WHITE} Installing GServer dependencies...${NC}"
    apt update >> "$BUILD_LOG" 2>&1
    apt install -y docker.io bison flex ninja-build libssl-dev libzstd-dev >> "$BUILD_LOG" 2>&1
    echo -e "${CYAN}${BASE_INDENT}🐳${WHITE} Starting Docker service...${NC}"
    systemctl start docker >> "$BUILD_LOG" 2>&1 || true
    systemctl enable docker >> "$BUILD_LOG" 2>&1 || true
    sleep 2
    if ! systemctl is-active --quiet docker; then
        echo -e "${YELLOW}${BASE_INDENT}⚠️${WHITE}  Docker service failed to start, continuing anyway...${NC}"
        log "Warning: Docker service failed to start"
    fi
    DEPS_INSTALLED_GSERVER=true
}

cleanup_directory() {
    local dir="$1"
    [[ ! -d "$dir" ]] && return
    
    echo -e "${CYAN}${BASE_INDENT}🧹 ${WHITE}Cleaning up existing $dir directory...${NC}"
    log "Cleaning directory: $dir"
    
    if ! rm -rf "$dir" 2>>"$BUILD_LOG"; then
        chmod -R 755 "$dir" 2>/dev/null || true
        rm -rf "$dir" || error_exit "Failed to remove directory: $dir"
    fi
}

validate_directory() {
    local dir="$1"
    local purpose="$2"
    
    if [[ ! -d "$(dirname "$dir")" ]]; then
        error_exit "Parent directory for $purpose does not exist: $(dirname "$dir")"
    fi
    
    if [[ -e "$dir" && ! -d "$dir" ]]; then
        error_exit "$purpose path exists but is not a directory: $dir"
    fi
}

detect_cpu_cores() {
    local cores=$(nproc 2>/dev/null || echo 1)
    local safe_cores=$((cores > 2 ? cores - 1 : cores))
    echo "$safe_cores"
}

show_banner() {
    echo -e "${YELLOW}"
    cat << "EOF"
                            ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⣀⣄⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
                            ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠘⣿⣿⣿⣿⡀⠀⠀⠀⠀⣠⣷⣦⣄⠀⠀⠀⠀⠀⠀⠀
                            ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣿⣿⣿⣿⣿⣶⣤⣤⣶⣿⣿⣿⣿⠏⠀⠀⠀⠀⠀⠀
                            ⠀⠀⠀⣠⣶⣤⣀⣀⣠⣼⣿⠿⠛⠋⠉⠉⠙⠛⠿⣿⣿⣿⡟⠀⠀⠀⠀⠀⠀⠀
                            ⠀⠀⣰⣿⣿⣿⣿⣿⡿⠋⣡⡴⠞⠛⠋⠙⠛⠳⢦⣄⠙⢿⣷⣀⠀⠀⠀⢀⠀⠀
                            ⠀⠀⠈⠙⢿⣿⣿⠟⢠⡾⠁⠀⠀⠀⠀⠀⠀⠀⠀⠈⢷⡄⠻⣿⣿⣿⣿⣿⡆⠀
                            ⠀⠀⠀⠀⠈⣿⡟⠀⣾⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢿⡀⢻⣿⣿⣿⣿⣷⠀
                            ⠀⠀⠀⢀⣼⣿⡇⢸⡇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢸⡇⢸⣿⡿⠋⠀⠀⠀
                            ⠀⢶⣾⣿⣿⣿⣧⠀⣷⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣼⠁⣸⣿⡀⠀⠀⠀⠀
                            ⠀⠸⣿⣿⣿⣿⣿⣆⠘⣧⡀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣼⠃⣰⣿⣿⣷⣄⠀⠀⠀
                            ⠀⠀⠉⠀⠀⠀⠙⢿⣷⣌⠛⠶⣤⣀⣀⣀⣀⣤⡴⠛⣡⣾⣿⣿⣿⣿⣿⡟⠀⠀
                            ⠀⠀⠀⠀⠀⠀⠀⢸⣿⣿⣷⣦⣄⣉⣉⣉⣉⣠⣴⣾⡿⠛⠋⠛⠻⢿⠏⠀⠀⠀
                            ⠀⠀⠀⠀⠀⠀⣠⣿⣿⣿⣿⡿⠿⠿⢿⣿⣿⣿⣿⣿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
                            ⠀⠀⠀⠀⠀⠀⠈⠛⠿⣿⠏⠀⠀⠀⠀⠙⣿⣿⣿⣿⡄⠀⠀⠀⠀⠀⠀⠀⠀⠀
                            ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠙⠛⠋⠉⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
    ██████╗ ██████╗ ███████╗ █████╗  ██████╗  ██████╗ ███╗   ██║ █████╗ ██║   
    ██╔══██╗██╔══██╗██╔════╝██╔══██╗██╔════╝ ██╔═══██╗████╗  ██║██╔══██╗██║  
    ██████╔╝██████╔╝█████╗  ███████║██║  ███╗██║   ██║██╔██╗ ██║███████║██║  
    ██╔═══╝ ██╔══██╗██╔══╝  ██╔══██║██║   ██║██║   ██║██║╚██╗██║██╔══██║██║ 
    ██║     ██║  ██║███████╗██║  ██║╚██████╔╝╚██████╔╝██║ ╚████║██║  ██║███████╗
    ╚═╝     ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═══╝╚═╝  ╚═╝╚══════╝
EOF
    echo -e "${NC}"
    echo -e "${CYAN} ══════════════════════════════════════════════════════════════════════════════════${NC}"
}

show_menu() {
    echo ""
    echo -e "${CYAN}${BASE_INDENT}📋${WHITE} Available Build Options:${NC}"
    echo -e "${GREEN}${BASE_INDENT}  1)${NC} ${YELLOW}⚡${NC} ${WHITE}GServer${NC} ${GREEN}(New Protocol)${NC}  - New protocol implementation"
    echo -e "${GREEN}${BASE_INDENT}  2)${NC} ${BLUE}🔧${NC} ${WHITE}GServer${NC} ${GREEN}(Standard)${NC}      - Stable production version"
    echo -e "${GREEN}${BASE_INDENT}  3)${NC} ${CYAN}🧪${NC} ${WHITE}GServer${NC} ${GREEN}(Beta4)${NC}         - Beta4 branch (Nalin)"
    echo -e "${GREEN}${BASE_INDENT}  4)${NC} ${YELLOW}🔨${NC} ${WHITE}GServer${NC} ${GREEN}(Dev)${NC}           - Development branch"
    echo -e "${GREEN}${BASE_INDENT}  5)${NC} ${PURPLE}📡${NC} ${WHITE}Listserver${NC}              - Server lister"
    echo -e "${GREEN}${BASE_INDENT}  6)${NC} ${RED}🔥${NC} ${WHITE}Build All${NC}               - Complete deployment stack"
    echo -e "${WHITE}${BASE_INDENT}Press 'q' at any time to quit${NC}"
    echo ""
}

get_user_choice() {
    local input
    while true; do
        read -rp "$(echo -e "${CYAN}${BASE_INDENT}🎯${WHITE} Choose your build option${NC} ${YELLOW}[1-6]${NC}: ")" input
        input=$(echo "$input" | tr -d '[:space:]')
        if [[ "$input" == "q" || "$input" == "Q" ]]; then
            echo ""
            echo -e "${RED}${BASE_INDENT}🛑${WHITE} Exiting...${NC}"
            exit 0
        fi
        if [[ "$input" =~ ^[1-6]$ ]]; then
            USER_CHOICE="$input"
            return 0
        fi
        echo -e "${RED}${BASE_INDENT}❌ Invalid choice.${WHITE} Please select 1, 2, 3, 4, 5, or 6.${NC}"
    done
}

ask_clean_install() {
    echo -e "${YELLOW}${BASE_INDENT}🔄${WHITE} Clean Install Option${NC}"
    echo -e "${WHITE}${BASE_INDENT}────────────────────────────${NC}"
    echo -e "${CYAN}${BASE_INDENT}⚠️${WHITE}  Clean install will re-download everything including:${NC}"
    echo -e "${WHITE}${BASE_INDENT}   • V8 dependencies (this takes fucking forever)${NC}"
    echo -e "${WHITE}${BASE_INDENT}   • WolfSSL submodules (also slow as shit)${NC}"
    echo -e "${WHITE}${BASE_INDENT}   • All git repositories${NC}"
    echo ""
    
    local response
    while true; do
        read -rp "$(echo -e "${YELLOW}${BASE_INDENT}❓${WHITE} Do a clean install? (y/N): ${NC}")" response
        [[ "$response" =~ ^[qQ]$ ]] && { echo -e "${RED}${BASE_INDENT}🛑${WHITE} Exiting...${NC}"; exit 0; }
        case "$response" in
            [yY]) CLEAN_INSTALL=true; break ;;
            [nN]|"") CLEAN_INSTALL=false
            APPLY_LISTSERVER_PATCH=false; break ;;
            *) echo -e "${RED}${BASE_INDENT}Invalid response. Use y/n${NC}" ;;
        esac
    done
}

configure_build() {
    local choice=$1
    
    echo -e "${CYAN}${BASE_INDENT}⚙️${WHITE}  Configuration Settings${NC}"
    echo -e "${WHITE}${BASE_INDENT}────────────────────────────${NC}"
    
    read -rp "$(echo -e "${YELLOW}${BASE_INDENT}📁${WHITE} Compile directory${NC} ${YELLOW}[$COMPILE_DIR]${NC}: ")" input
    [[ "$input" =~ ^[qQ]$ ]] && { echo -e "${RED}${BASE_INDENT}🛑${WHITE} Exiting...${NC}"; exit 0; }
    COMPILE_DIR=${input:-$COMPILE_DIR}
    validate_directory "$COMPILE_DIR" "Compile"
    
    case $choice in
        1) configure_new_protocol ;;
        2) configure_gserver ;;
        3) configure_gserver_beta4 ;;
        4) configure_gserver ;;
        5) configure_listserver ;;
        6) configure_all ;;
    esac
}

configure_new_protocol() {
    read -rp "$(echo -e "${YELLOW}${BASE_INDENT}📤${WHITE} Output directory for GServer (New Protocol)${NC} ${YELLOW}[$OUTPUT_DIR_NEWPROTOCOL]${NC}: ")" input
    [[ "$input" =~ ^[qQ]$ ]] && { echo -e "${RED}${BASE_INDENT}🛑${WHITE} Exiting...${NC}"; exit 0; }
    OUTPUT_DIR_NEWPROTOCOL=${input:-$OUTPUT_DIR_NEWPROTOCOL}
    validate_directory "$OUTPUT_DIR_NEWPROTOCOL" "New Protocol Output"
    
    read -rp "$(echo -e "${YELLOW}${BASE_INDENT}🏷️${WHITE}  Version tag (DVER_EXTRA)${NC} ${YELLOW}[$DVER_EXTRA]${NC}: ")" input
    [[ "$input" =~ ^[qQ]$ ]] && { echo -e "${RED}${BASE_INDENT}🛑${WHITE} Exiting...${NC}"; exit 0; }
    DVER_EXTRA=${input:-$DVER_EXTRA}
}

configure_gserver() {
    read -rp "$(echo -e "${YELLOW}${BASE_INDENT}📤${WHITE} Output directory for GServer${NC} ${YELLOW}[$OUTPUT_DIR_GSERVER]${NC}: ")" input
    [[ "$input" =~ ^[qQ]$ ]] && { echo -e "${RED}${BASE_INDENT}🛑${WHITE} Exiting...${NC}"; exit 0; }
    OUTPUT_DIR_GSERVER=${input:-$OUTPUT_DIR_GSERVER}
    validate_directory "$OUTPUT_DIR_GSERVER" "GServer Output"

    read -rp "$(echo -e "${YELLOW}${BASE_INDENT}🏷️${WHITE}  Version tag (DVER_EXTRA)${NC} ${YELLOW}[$DVER_EXTRA]${NC}: ")" input
    [[ "$input" =~ ^[qQ]$ ]] && { echo -e "${RED}${BASE_INDENT}🛑${WHITE} Exiting...${NC}"; exit 0; }
    DVER_EXTRA=${input:-$DVER_EXTRA}
}

configure_gserver_beta4() {
    read -rp "$(echo -e "${YELLOW}${BASE_INDENT}📤${WHITE} Output directory for GServer (Beta4)${NC} ${YELLOW}[$OUTPUT_DIR_BETA4]${NC}: ")" input
    [[ "$input" =~ ^[qQ]$ ]] && { echo -e "${RED}${BASE_INDENT}🛑${WHITE} Exiting...${NC}"; exit 0; }
    OUTPUT_DIR_BETA4=${input:-$OUTPUT_DIR_BETA4}
    validate_directory "$OUTPUT_DIR_BETA4" "GServer Beta4 Output"

    read -rp "$(echo -e "${YELLOW}${BASE_INDENT}🏷️${WHITE}  Version tag (DVER_EXTRA)${NC} ${YELLOW}[$DVER_EXTRA]${NC}: ")" input
    [[ "$input" =~ ^[qQ]$ ]] && { echo -e "${RED}${BASE_INDENT}🛑${WHITE} Exiting...${NC}"; exit 0; }
    DVER_EXTRA=${input:-$DVER_EXTRA}
}

configure_listserver() {
    read -rp "$(echo -e "${YELLOW}${BASE_INDENT}📤${WHITE} Output directory for Listserver${NC} ${YELLOW}[$OUTPUT_DIR_LISTSERVER]${NC}: ")" input
    [[ "$input" =~ ^[qQ]$ ]] && { echo -e "${RED}${BASE_INDENT}🛑${WHITE} Exiting...${NC}"; exit 0; }
    OUTPUT_DIR_LISTSERVER=${input:-$OUTPUT_DIR_LISTSERVER}
    validate_directory "$OUTPUT_DIR_LISTSERVER" "Listserver Output"
    
    echo -e "${CYAN}${BASE_INDENT}🔧${WHITE} Apply stdin infinite loop patch? (fixes service mode)${NC}"
    local response
    while true; do
        read -rp "$(echo -e "${YELLOW}${BASE_INDENT}❓${WHITE} Apply patch? (Y/n): ${NC}")" response
        [[ "$response" =~ ^[qQ]$ ]] && { echo -e "${RED}${BASE_INDENT}🛑${WHITE} Exiting...${NC}"; exit 0; }
        case "$response" in
            [yY]|"") APPLY_LISTSERVER_PATCH=true; break ;;
            [nN]) APPLY_LISTSERVER_PATCH=false; break ;;
            *) echo -e "${RED}${BASE_INDENT}Invalid response. Use y/n${NC}" ;;
        esac
    done
}

configure_all() {
    APPLY_LISTSERVER_PATCH=false  # Reset for build all
    configure_listserver
    configure_gserver
    configure_new_protocol
    configure_gserver_beta4
}

show_configuration_summary() {
    local choice=$1
    
    echo ""
    echo -e "${GREEN}${BASE_INDENT}✅${WHITE} Configuration Summary:${NC}"
    echo -e "${GREEN}${BASE_INDENT}   📁${WHITE} Compile Directory: ${WHITE}$COMPILE_DIR${NC}"
    echo -e "${GREEN}${BASE_INDENT}   🖥️${WHITE}  CPU Cores: ${WHITE}$PARALLEL_JOBS${NC}"
    echo -e "${GREEN}${BASE_INDENT}   🔄${WHITE} Clean Install: ${WHITE}$([ "$CLEAN_INSTALL" = true ] && echo "Yes" || echo "No")${NC}"
    
    case $choice in
        1) echo -e "${GREEN}${BASE_INDENT}   📤${WHITE} GServer (New Protocol) Output: $OUTPUT_DIR_NEWPROTOCOL${NC}" ;;
    esac
    case $choice in
        2|4) echo -e "${GREEN}${BASE_INDENT}   📤${WHITE} GServer Output: $OUTPUT_DIR_GSERVER${NC}" ;;
    esac
    case $choice in
        3) echo -e "${GREEN}${BASE_INDENT}   📤${WHITE} GServer (Beta4) Output: $OUTPUT_DIR_BETA4${NC}" ;;
    esac
    case $choice in
        5|6) 
            echo -e "${GREEN}${BASE_INDENT}   📤${WHITE} Listserver Output: $OUTPUT_DIR_LISTSERVER${NC}"
            echo -e "${GREEN}${BASE_INDENT}   🔧${WHITE} Apply stdin patch: ${WHITE}$([ "$APPLY_LISTSERVER_PATCH" = true ] && echo "Yes" || echo "No")${NC}"
            ;;
    esac
    case $choice in
        1|2|3|4) echo -e "${GREEN}${BASE_INDENT}   🏷️${WHITE}  Version Tag: ${WHITE}$DVER_EXTRA${NC}" ;;
    esac
    case $choice in
        6)
            echo -e "${GREEN}${BASE_INDENT}   📤${WHITE} GServer (New Protocol) Output: $OUTPUT_DIR_NEWPROTOCOL${NC}"
            echo -e "${GREEN}${BASE_INDENT}   📤${WHITE} GServer Output: $OUTPUT_DIR_GSERVER${NC}"
            echo -e "${GREEN}${BASE_INDENT}   📤${WHITE} GServer (Beta4) Output: $OUTPUT_DIR_BETA4${NC}"
            echo -e "${GREEN}${BASE_INDENT}   🏷️${WHITE}  Version Tag: ${WHITE}$DVER_EXTRA${NC}"
            ;;
    esac
    
    echo -e "${GREEN}${BASE_INDENT}   📋${WHITE} Build Log: ${WHITE}$BUILD_LOG${NC}"
    echo ""
}

git_clone_with_retry() {
    local repo=$1
    local dest=$2
    local branch=${3:-}
    local max_retries=3
    local retry=0
    
    while [[ $retry -lt $max_retries ]]; do
        if [[ -n "$branch" ]]; then
            git clone -b "$branch" "$repo" "$dest" >> "$BUILD_LOG" 2>&1 && return 0
        else
            git clone "$repo" "$dest" >> "$BUILD_LOG" 2>&1 && return 0
        fi
        
        retry=$((retry + 1))
        log "Git clone failed, retry $retry/$max_retries"
        sleep 2
    done
    
    return 1
}

docker_pull_with_retry() {
    local image=$1
    local max_retries=3
    local retry=0
    
    while [[ $retry -lt $max_retries ]]; do
        docker pull "$image" >> "$BUILD_LOG" 2>&1 && return 0
        retry=$((retry + 1))
        log "Docker pull failed, retry $retry/$max_retries"
        sleep 5
    done
    
    return 1
}

handle_existing_repo() {
    local repo_path=$1
    local repo_url=$2
    local branch=${3:-}
    
    if [[ -d "$repo_path" && "$CLEAN_INSTALL" = false ]]; then
        echo -e "${CYAN}${BASE_INDENT}🔄${WHITE} Using existing repository, updating...${NC}"
        cd "$repo_path" || error_exit "Failed to enter $repo_path"
        
        git fetch --all >> "$BUILD_LOG" 2>&1 || error_exit "Git fetch failed"
        
        if [[ -n "$branch" ]]; then
            git checkout "$branch" >> "$BUILD_LOG" 2>&1 || error_exit "Git checkout failed"
        fi
        
        git pull >> "$BUILD_LOG" 2>&1 || error_exit "Git pull failed"
        return 0
    else
        cleanup_directory "$repo_path"
        return 1
    fi
}

handle_v8_deps() {
    local target_path=$1
    local project_name=$2
    
    if [[ -d "$target_path/dependencies/v8" && "$CLEAN_INSTALL" = false ]]; then
        echo -e "${GREEN}${BASE_INDENT}✓${WHITE} V8 dependencies already exist, skipping download${NC}"
        return 0
    fi
    
    log "Getting V8 dependencies"
    {
        docker_pull_with_retry "xtjoeytx/v8:9.1.269.9-gnu" && \
        docker run --rm -v /root:/root -w "$PWD" xtjoeytx/v8:9.1.269.9-gnu \
            cp -fvr /tmp/v8 "$target_path/dependencies/v8"
    } >> "$BUILD_LOG" 2>&1 &
    show_spinner "${PURPLE}🔧${WHITE} Getting V8 dependencies (grab a coffee, this shit takes ages)" $!
}

apply_listserver_patch() {
    echo -e "${CYAN}${BASE_INDENT}🔧${WHITE} Applying stdin infinite loop patch...${NC}"
    log "Applying Listserver patch"
    
    local main_cpp_path=""
    if [[ -f "server/src/main.cpp" ]]; then
        main_cpp_path="server/src/main.cpp"
    elif [[ -f "src/main.cpp" ]]; then
        main_cpp_path="src/main.cpp"
    else
        echo -e "${RED}${BASE_INDENT}❌ main.cpp not found in expected locations${NC}"
        return 1
    fi
    
    # Check if already patched
    if grep -q "std::numeric_limits<std::streamsize>::max()" "$main_cpp_path"; then
        echo -e "${GREEN}${BASE_INDENT}✅${WHITE} Already patched, skipping${NC}"
        return 0
    fi
    
    # Backup original file
    cp "$main_cpp_path" "$main_cpp_path.backup" || error_exit "Failed to backup main.cpp"
    log "Created backup: $main_cpp_path.backup"
    
    # Add #include <limits> after other includes
    if ! grep -q "#include <limits>" "$main_cpp_path"; then
        sed -i '/^#include <thread>/a #include <limits>' "$main_cpp_path" || error_exit "Failed to add limits include"
        log "Added #include <limits>"
    fi
    
    # Replace the main loop with patched version
    cat > /tmp/listserver_patch.txt << 'EOF'
    while (listServer)
    {
        std::string command;

        if (!daemonMode) {
            std::cout << "Input Command: ";
            if (!(std::cin >> command)) {
                if (std::cin.bad() || std::cin.eof()) {
                    daemonMode = true;
                    std::cout << "stdin unavailable, switching to daemon mode\\n";
                    continue;
                }
                std::cin.clear();
                std::cin.ignore(std::numeric_limits<std::streamsize>::max(), '\\n');
                continue;
            }
        } else {
            if (listThread.joinable())
                listThread.join();
            break;
        }

        if (command == "quit") {
            listServer->setRunning(false);
            break;
        }
    }
EOF
    
    # Simple approach - just replace the cin line and add daemon mode logic
    if grep -q "std::cin >> command" "$main_cpp_path"; then
        # Replace the simple cin line with our error handling
        sed -i '/std::cin >> command/c\
            if (!(std::cin >> command)) {\
                if (std::cin.bad() || std::cin.eof()) {\
                    daemonMode = true;\
                    std::cout << "stdin unavailable, switching to daemon mode\\n";\
                    continue;\
                }\
                std::cin.clear();\
                std::cin.ignore(std::numeric_limits<std::streamsize>::max(), '\''\\n'\'');\
                continue;\
            }' "$main_cpp_path" || error_exit "Failed to patch cin line"
        
        log "Patched cin line with error handling"
    else
        error_exit "Could not find std::cin >> command line to patch"
    fi
    
    rm -f /tmp/listserver_patch.txt
    
    echo -e "${GREEN}${BASE_INDENT}✅${WHITE} Patch applied successfully!${NC}"
    log "Listserver patch applied successfully"
}

build_listserver() {
    echo -e "${PURPLE}${BASE_INDENT}🔨${WHITE} Building Listserver...${NC}"
    log "Starting Listserver build"
    
    install_base_deps
    install_listserver_deps
    
    echo -e "${YELLOW}${BASE_INDENT}📂${WHITE} Setting up directories...${NC}"
    mkdir -p "$COMPILE_DIR" && cd "$COMPILE_DIR" || error_exit "Failed to create/enter compile directory"
    
    if ! handle_existing_repo "graal-serverlist" "https://github.com/xtjoeytx/graal-serverlist.git" "feature/revamp"; then
        git_clone_with_retry "https://github.com/xtjoeytx/graal-serverlist.git" "graal-serverlist" "feature/revamp" &
        show_spinner "${BLUE}🌐${WHITE} Cloning Listserver repository" $!
        cd graal-serverlist/ || error_exit "Failed to enter graal-serverlist directory"
    fi
    
    if [[ "$CLEAN_INSTALL" = true ]] || [[ ! -d ".git/modules" ]]; then
        git submodule update --init --recursive >> "$BUILD_LOG" 2>&1 &
        show_spinner "${BLUE}🔄${WHITE} Updating submodules" $!
    else
        echo -e "${GREEN}${BASE_INDENT}✓${WHITE} Submodules already initialized${NC}"
    fi
    
    # Apply patch if requested
    if [[ "$APPLY_LISTSERVER_PATCH" = true ]]; then
        apply_listserver_patch
    fi
    
    mkdir -p build && cd build || error_exit "Failed to create/enter build directory"
    
    log "Running cmake for Listserver"
    cmake .. \
        -DCMAKE_CXX_STANDARD=11 \
        -DCMAKE_INSTALL_PREFIX="$OUTPUT_DIR_LISTSERVER" \
        -DCMAKE_CXX_FLAGS="-include cstdint" \
        -Wno-dev >> "$BUILD_LOG" 2>&1 || error_exit "CMake configuration failed"
    
    { make -j"$PARALLEL_JOBS" && make install; } >> "$BUILD_LOG" 2>&1 &
    show_spinner "${YELLOW}⚙️${WHITE}  Compiling and installing" $!
    
    echo -e "${GREEN}${BASE_INDENT}✅${WHITE} Listserver build complete!${NC} ${WHITE}Installed to $OUTPUT_DIR_LISTSERVER${NC}"
    log "Listserver build completed successfully"
}

build_new_protocol() {
    echo -e "${YELLOW}${BASE_INDENT}⚡${WHITE} Building New Protocol GServer...${NC}"
    log "Starting New Protocol GServer build"
    
    install_base_deps
    install_gserver_deps
    
    echo -e "${WHITE}${BASE_INDENT}📂${WHITE} Setting up directories...${NC}"
    mkdir -p "$COMPILE_DIR" && cd "$COMPILE_DIR" || error_exit "Failed to create/enter compile directory"
    
    if ! handle_existing_repo "GServer-newprotocol" "https://github.com/xtjoeytx/GServer-v2.git" "feature/newprotocol"; then
        git_clone_with_retry "https://github.com/xtjoeytx/GServer-v2.git" "GServer-newprotocol" "feature/newprotocol" &
        show_spinner "${BLUE}🌐${WHITE} Cloning repository" $!
        cd GServer-newprotocol || error_exit "Failed to enter GServer-newprotocol directory"
    fi
    
    if [[ "$CLEAN_INSTALL" = true ]] || [[ ! -d ".git/modules" ]]; then
        git submodule update --init --recursive >> "$BUILD_LOG" 2>&1 &
        show_spinner "${BLUE}🔄${WHITE} Updating submodules (wolfssl takes forever, sorry)" $!
    else
        echo -e "${GREEN}${BASE_INDENT}✓${WHITE} Submodules already initialized${NC}"
    fi
    
    handle_v8_deps "$COMPILE_DIR/GServer-newprotocol" "GServer-newprotocol"
    
    mkdir -p build || error_exit "Failed to create build directory"
    
    log "Running cmake for New Protocol GServer"
    cmake -GNinja -S./ -B./build \
        -DCMAKE_BUILD_TYPE=Release \
        -DSTATIC=ON \
        -DCMAKE_INSTALL_PREFIX="$OUTPUT_DIR_NEWPROTOCOL" \
        -DV8NPCSERVER=ON \
        -DVER_EXTRA="-$DVER_EXTRA" \
        -DWOLFSSL=ON \
        -DUPNP=OFF \
        -DCMAKE_EXE_LINKER_FLAGS="-Wl,--allow-multiple-definition" >> "$BUILD_LOG" 2>&1 || error_exit "CMake configuration failed"
    
    {
        cmake --build ./build --target clean && \
        cmake --build ./build --target all --parallel "$PARALLEL_JOBS" && \
        cd build && ninja install
    } >> "$BUILD_LOG" 2>&1 &
    show_spinner "${YELLOW}⚙️${WHITE}  Compiling and installing" $!
    
    echo -e "${GREEN}${BASE_INDENT}✅${WHITE} New Protocol GServer build complete!${NC} ${WHITE}Installed to $OUTPUT_DIR_NEWPROTOCOL${NC}"
    log "New Protocol GServer build completed successfully"
}

build_gserver() {
    echo -e "${GREEN}${BASE_INDENT}🔧${WHITE} Building Standard GServer...${NC}"
    log "Starting Standard GServer build"
    
    install_base_deps
    install_gserver_deps
    
    echo -e "${YELLOW}${BASE_INDENT}📂${WHITE} Setting up directories...${NC}"
    mkdir -p "$COMPILE_DIR" && cd "$COMPILE_DIR" || error_exit "Failed to create/enter compile directory"
    
    if ! handle_existing_repo "GServer-v2" "https://github.com/xtjoeytx/GServer-v2.git"; then
        git_clone_with_retry "https://github.com/xtjoeytx/GServer-v2.git" "GServer-v2" &
        show_spinner "${BLUE}🌐${WHITE} Cloning repository" $!
        cd GServer-v2 || error_exit "Failed to enter GServer-v2 directory"
    fi
    
    if [[ "$CLEAN_INSTALL" = true ]] || [[ ! -d ".git/modules" ]]; then
        git submodule update --init --recursive >> "$BUILD_LOG" 2>&1 &
        show_spinner "${BLUE}🔄${WHITE} Updating submodules" $!
    else
        echo -e "${GREEN}${BASE_INDENT}✓${WHITE} Submodules already initialized${NC}"
    fi
    
    # Apply patch if requested
    if [[ "$APPLY_LISTSERVER_PATCH" = true ]]; then
        apply_listserver_patch
    fi
    
    handle_v8_deps "$COMPILE_DIR/GServer-v2" "GServer-v2"
    
    mkdir -p build && cd build || error_exit "Failed to create/enter build directory"
    
    log "Running cmake for Standard GServer"
    cmake .. \
        -DV8NPCSERVER=TRUE \
        -DCMAKE_INSTALL_PREFIX="$OUTPUT_DIR_GSERVER" \
        -DCMAKE_CXX_STANDARD=23 \
        -DCMAKE_CXX_STANDARD_REQUIRED=ON \
        -DCMAKE_BUILD_TYPE=Release >> "$BUILD_LOG" 2>&1 || error_exit "CMake configuration failed"
   
   { make -j"$PARALLEL_JOBS" && make install; } >> "$BUILD_LOG" 2>&1 &
   show_spinner "${YELLOW}⚙️${WHITE}  Compiling and installing" $!
   
   echo -e "${GREEN}${BASE_INDENT}✅${WHITE} Standard GServer build complete!${NC} ${WHITE}Installed to $OUTPUT_DIR_GSERVER${NC}"
   log "Standard GServer build completed successfully"
}

build_gserver_dev() {
    echo -e "${GREEN}${BASE_INDENT}🔧${WHITE} Building GServer (Dev Branch)...${NC}"
    log "Starting GServer Dev build"
    
    install_base_deps
    install_gserver_deps
    
    echo -e "${YELLOW}${BASE_INDENT}📂${WHITE} Setting up directories...${NC}"
    mkdir -p "$COMPILE_DIR" && cd "$COMPILE_DIR" || error_exit "Failed to create/enter compile directory"
    
    if ! handle_existing_repo "GServer-v2" "https://github.com/xtjoeytx/GServer-v2.git" "dev"; then
        git_clone_with_retry "https://github.com/xtjoeytx/GServer-v2.git" "GServer-v2" "dev" &
        show_spinner "${BLUE}🌐${WHITE} Cloning repository" $!
        cd GServer-v2 || error_exit "Failed to enter GServer-v2 directory"
    fi
    
    if [[ "$CLEAN_INSTALL" = true ]] || [[ ! -d ".git/modules" ]]; then
        git submodule update --init --recursive >> "$BUILD_LOG" 2>&1 &
        show_spinner "${BLUE}🔄${WHITE} Updating submodules" $!
    else
        echo -e "${GREEN}${BASE_INDENT}✓${WHITE} Submodules already initialized${NC}"
    fi
    
    # Apply patch if requested
    if [[ "$APPLY_LISTSERVER_PATCH" = true ]]; then
        apply_listserver_patch
    fi
    
    handle_v8_deps "$COMPILE_DIR/GServer-v2" "GServer-v2"
    
    mkdir -p build && cd build || error_exit "Failed to create/enter build directory"
    
    log "Running cmake for GServer Dev"
    cmake .. \
        -DV8NPCSERVER=TRUE \
        -DCMAKE_INSTALL_PREFIX="$OUTPUT_DIR_GSERVER" \
        -DCMAKE_CXX_STANDARD=23 \
        -DCMAKE_CXX_STANDARD_REQUIRED=ON \
        -DCMAKE_BUILD_TYPE=Release \
        -DVER_EXTRA="-$DVER_EXTRA" >> "$BUILD_LOG" 2>&1 || error_exit "CMake configuration failed"
   
   { make -j"$PARALLEL_JOBS" && make install; } >> "$BUILD_LOG" 2>&1 &
   show_spinner "${YELLOW}⚙️${WHITE}  Compiling and installing" $!
   
   echo -e "${GREEN}${BASE_INDENT}✅${WHITE} GServer Dev build complete!${NC} ${WHITE}Installed to $OUTPUT_DIR_GSERVER${NC}"
   log "GServer Dev build completed successfully"
}

build_gserver_beta4() {
    echo -e "${CYAN}${BASE_INDENT}🧪${WHITE} Building GServer Beta4...${NC}"
    log "Starting GServer Beta4 build"

    install_base_deps
    install_gserver_deps

    echo -e "${YELLOW}${BASE_INDENT}📂${WHITE} Setting up directories...${NC}"
    mkdir -p "$COMPILE_DIR" && cd "$COMPILE_DIR" || error_exit "Failed to create/enter compile directory"

    if ! handle_existing_repo "beta4" "https://github.com/xtjoeytx/GServer-v2.git" "beta4"; then
        git_clone_with_retry "https://github.com/xtjoeytx/GServer-v2.git" "beta4" "beta4" &
        show_spinner "${BLUE}🌐${WHITE} Cloning beta4 repository" $!
        cd beta4 || error_exit "Failed to enter beta4 directory"
    fi

    if [[ "$CLEAN_INSTALL" = true ]] || [[ ! -d ".git/modules" ]]; then
        git submodule update --init --recursive >> "$BUILD_LOG" 2>&1 &
        show_spinner "${BLUE}🔄${WHITE} Updating submodules" $!
    else
        echo -e "${GREEN}${BASE_INDENT}✓${WHITE} Submodules already initialized${NC}"
    fi

    mkdir -p build && cd build || error_exit "Failed to create/enter build directory"

    log "Running cmake for GServer Beta4"
    export VCPKG_ROOT=/usr/local/vcpkg
    cmake .. \
        -DCMAKE_INSTALL_PREFIX="$OUTPUT_DIR_BETA4" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_STANDARD=23 \
        -DCMAKE_CXX_STANDARD_REQUIRED=ON \
        -DVER_EXTRA="-$DVER_EXTRA" >> "$BUILD_LOG" 2>&1 || error_exit "CMake configuration failed"

    { make -j"$PARALLEL_JOBS" && make install; } >> "$BUILD_LOG" 2>&1 &
    show_spinner "${YELLOW}⚙️${WHITE}  Compiling and installing" $!

    echo -e "${GREEN}${BASE_INDENT}✅${WHITE} GServer Beta4 build complete!${NC} ${WHITE}Installed to $OUTPUT_DIR_BETA4${NC}"
    log "GServer Beta4 build completed successfully"
}

post_install_verification() {
    local install_dir=$1
    local binary_name=$2
    
    if [[ -f "$install_dir/$binary_name" ]]; then
        echo -e "${GREEN}${BASE_INDENT}✓${WHITE} Binary verified: $install_dir/$binary_name${NC}"
        local size=$(du -h "$install_dir/$binary_name" | cut -f1)
        echo -e "${GREEN}${BASE_INDENT}  Size: $size${NC}"
    else
        echo -e "${YELLOW}${BASE_INDENT}⚠️${WHITE}  Warning: Expected binary not found at $install_dir/$binary_name${NC}"
    fi
}

patch_listserver() {
    echo -e "${CYAN}${BASE_INDENT}🔧${WHITE} Patching Listserver stdin infinite loop...${NC}"
    log "Starting Listserver patch"
    
    echo -e "${YELLOW}${BASE_INDENT}📂${WHITE} Looking for Listserver source...${NC}"
    mkdir -p "$COMPILE_DIR" && cd "$COMPILE_DIR" || error_exit "Failed to create/enter compile directory"
    
    local main_cpp_path=""
    if [[ -f "graal-serverlist/server/src/main.cpp" ]]; then
        main_cpp_path="graal-serverlist/server/src/main.cpp"
    elif [[ -f "graal-serverlist/src/main.cpp" ]]; then
        main_cpp_path="graal-serverlist/src/main.cpp"
    else
        echo -e "${RED}${BASE_INDENT}❌ Listserver source not found. Run build option 5 first.${NC}"
        return 1
    fi
    
    echo -e "${CYAN}${BASE_INDENT}📝${WHITE} Found main.cpp at: $main_cpp_path${NC}"
    
    # Check if already patched
    if grep -q "std::numeric_limits<std::streamsize>::max()" "$main_cpp_path"; then
        echo -e "${GREEN}${BASE_INDENT}✅${WHITE} Listserver already patched!${NC}"
        return 0
    fi
    
    # Backup original file
    cp "$main_cpp_path" "$main_cpp_path.backup" || error_exit "Failed to backup main.cpp"
    echo -e "${CYAN}${BASE_INDENT}💾${WHITE} Created backup: $main_cpp_path.backup${NC}"
    
    # Add #include <limits> after other includes
    if ! grep -q "#include <limits>" "$main_cpp_path"; then
        sed -i '/^#include <thread>/a #include <limits>' "$main_cpp_path" || error_exit "Failed to add limits include"
        log "Added #include <limits>"
    fi
    
    # Replace the main loop with patched version
    cat > /tmp/listserver_patch.txt << 'EOF'
    while (listServer)
    {
        std::string command;

        if (!daemonMode) {
            std::cout << "Input Command: ";
            if (!(std::cin >> command)) {
                if (std::cin.bad() || std::cin.eof()) {
                    daemonMode = true;
                    std::cout << "stdin unavailable, switching to daemon mode\\n";
                    continue;
                }
                std::cin.clear();
                std::cin.ignore(std::numeric_limits<std::streamsize>::max(), '\\n');
                continue;
            }
        } else {
            if (listThread.joinable())
                listThread.join();
            break;
        }

        if (command == "quit") {
            listServer->setRunning(false);
            break;
        }
    }
EOF
    
    # Simple approach - just replace the cin line and add daemon mode logic
    if grep -q "std::cin >> command" "$main_cpp_path"; then
        # Replace the simple cin line with our error handling
        sed -i '/std::cin >> command/c\
            if (!(std::cin >> command)) {\
                if (std::cin.bad() || std::cin.eof()) {\
                    daemonMode = true;\
                    std::cout << "stdin unavailable, switching to daemon mode\\n";\
                    continue;\
                }\
                std::cin.clear();\
                std::cin.ignore(std::numeric_limits<std::streamsize>::max(), '\''\\n'\'');\
                continue;\
            }' "$main_cpp_path" || error_exit "Failed to patch cin line"
        
        log "Patched cin line with error handling"
    else
        error_exit "Could not find std::cin >> command line to patch"
    fi
    
    rm -f /tmp/listserver_patch.txt
    
    echo -e "${GREEN}${BASE_INDENT}✅${WHITE} Listserver patched successfully!${NC}"
    echo -e "${CYAN}${BASE_INDENT}📝${WHITE} Changes made:${NC}"
    echo -e "${GREEN}${BASE_INDENT}   • Added #include <limits>${NC}"
    echo -e "${GREEN}${BASE_INDENT}   • Fixed stdin infinite loop in main()${NC}"
    echo -e "${GREEN}${BASE_INDENT}   • Auto-switches to daemon mode when stdin unavailable${NC}"
    echo -e "${YELLOW}${BASE_INDENT}💡${WHITE} Rebuild listserver (option 5) to apply changes${NC}"
    
    log "Listserver patch completed successfully"
}

main() {
   show_banner
   
   PARALLEL_JOBS=$(detect_cpu_cores)
   log "Script started with $PARALLEL_JOBS parallel jobs"
   
   if [[ $EUID -ne 0 ]]; then
       error_exit "This script must be run as root"
   fi
   
   show_menu
   get_user_choice
   local choice="$USER_CHOICE"
   ask_clean_install
   
   configure_build "$choice"
   show_configuration_summary "$choice"
   
   echo -e "${CYAN}${BASE_INDENT}🚀${WHITE} Starting build process...${NC}"
   
    case $choice in
        1) 
            build_new_protocol
            post_install_verification "$OUTPUT_DIR_NEWPROTOCOL" "gs2emu"
            ;;
        2) 
            build_gserver
            post_install_verification "$OUTPUT_DIR_GSERVER" "gs2emu"
            ;;
        3)
            build_gserver_beta4
            post_install_verification "$OUTPUT_DIR_BETA4" "gs2emu"
            ;;
        4) 
            build_gserver_dev
            post_install_verification "$OUTPUT_DIR_GSERVER" "gs2emu"
            ;;
        5)
            build_listserver
            post_install_verification "$OUTPUT_DIR_LISTSERVER" "listserver"
            ;;
        6)
            echo -e "${RED}${BASE_INDENT}🔥${WHITE} Building complete deployment stack...${NC}"
            build_listserver
            post_install_verification "$OUTPUT_DIR_LISTSERVER" "listserver"
            
            build_new_protocol
            post_install_verification "$OUTPUT_DIR_NEWPROTOCOL" "gs2emu"

            build_gserver
            post_install_verification "$OUTPUT_DIR_GSERVER" "gs2emu"

            build_gserver_beta4
            post_install_verification "$OUTPUT_DIR_BETA4" "gs2emu"

            echo -e "${GREEN}${BASE_INDENT}🎉${WHITE} All components built successfully!${NC}"
            ;;

    esac
   
   echo -e "${WHITE}${BASE_INDENT}🎉 Build process completed successfully!${NC}"
   echo -e "${CYAN}${BASE_INDENT}📋${WHITE} Build log: $BUILD_LOG${NC}"
   echo -e "${CYAN} ══════════════════════════════════════════════════════════════════════════════════${NC}"
}

main "$@"   