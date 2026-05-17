#(!/usr/bin/env bash
set -euo pipefail

SELF_REPO_BASE="https://raw.githubusercontent.com/Star123451/LuaToolsLinux/main"
LUATOOLS_MILLENNIUM_URL="$SELF_REPO_BASE/update.sh"
LUATOOLS_LEGACY_URL="$SELF_REPO_BASE/update_legacy.sh"
ENTERTHEWIRED_REPO="https://github.com/ciscosweater/enter-the-wired.git"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

DEBUG=false
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok() { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
debug() { $DEBUG && echo -e "${CYAN}[DEBUG]${NC} $*"; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }
run_remote_script() {
    local url="$1"
    info "Running: $url"
    curl -fsSL "$url" | bash
}

# ---------- Pre-flight checks ----------
check_internet() {
    info "Checking internet connectivity..."
    if ! curl -fsS --head "https://github.com" >/dev/null 2>&1; then
        fail "No internet connection. Please check your network."
    fi
    ok "Internet is reachable."
}

check_architecture() {
    if [[ "$(uname -m)" != "x86_64" ]]; then
        fail "Unsupported architecture: $(uname -m). Millennium only works on x86_64."
    fi
    ok "Architecture x86_64 OK."
}

force_close_steam() {
    if pgrep -x "steam" >/dev/null; then
        warn "Steam is currently running. Closing it now..."
        pkill -x steam || true
        sleep 3
        if pgrep -x "steam" >/dev/null; then
            warn "Steam still running. Please close it manually."
        else
            ok "Steam closed."
        fi
    fi
}

start_steam() {
    info "Starting Steam..."
    nohup steam >/dev/null 2>&1 &
    ok "Steam launched."
}

# ---------- Steam compatibility checks ----------
detect_steam_type() {
    if flatpak list | grep -q "com.valvesoftware.Steam" 2>/dev/null; then
        echo "flatpak"
    elif snap list 2>/dev/null | grep -q "^steam "; then
        echo "snap"
    elif command -v steam >/dev/null && [[ -f /usr/bin/steam ]]; then
        echo "native"
    else
        echo "unknown"
    fi
}

get_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "$ID"
    else
        echo "unknown"
    fi
}

get_distro_family() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "$ID" == "ubuntu" || "$ID" == "debian" || "$ID_LIKE" =~ (debian|ubuntu) ]]; then
            echo "debian"
        elif [[ "$ID" == "fedora" || "$ID" == "rhel" || "$ID" == "centos" || "$ID_LIKE" =~ (fedora|rhel) ]]; then
            echo "fedora"
        elif [[ "$ID" == "arch" || "$ID_LIKE" =~ arch ]]; then
            echo "arch"
        else
            echo "unknown"
        fi
    else
        echo "unknown"
    fi
}

suggest_native_steam_install() {
    local distro=$(get_distro)
    case "$distro" in
        ubuntu|debian)      echo "sudo snap remove steam && sudo apt update && sudo apt install steam" ;;
        fedora)             echo "sudo snap remove steam && sudo dnf install steam" ;;
        arch|manjaro)       echo "sudo snap remove steam && sudo pacman -S steam" ;;
        opensuse*)          echo "sudo snap remove steam && sudo zypper install steam" ;;
        *)                  echo "See your distro docs to install native Steam." ;;
    esac
}

check_steam_compatibility() {
    local steam_type=$(detect_steam_type)
    case "$steam_type" in
        flatpak)
            warn "Steam Flatpak detected. Millennium does NOT work with Flatpak."
            local cmd=$(suggest_native_steam_install)
            echo -e "${YELLOW}To fix, remove Flatpak:${NC}"
            echo "  flatpak uninstall com.valvesoftware.Steam"
            echo -e "${YELLOW}Then install native Steam:${NC}"
            echo "  $cmd"
            fail "Aborted. Use native Steam."
            ;;
        snap)
            warn "Steam Snap detected. Millennium does NOT work with Snap."
            local cmd=$(suggest_native_steam_install)
            echo -e "${YELLOW}Remove Snap and install native:${NC}"
            echo "  $cmd"
            fail "Aborted. Use native Steam."
            ;;
        native)
            ok "Native Steam detected. OK."
            ;;
        *)
            warn "Could not determine Steam type. Assuming native, but be careful."
            ;;
    esac
}

check_decky_loader() {
    if [[ -d "$HOME/.local/share/decky" ]] || [[ -f "$HOME/.steam/steam/plugins/decky-loader" ]] || systemctl --user list-units 2>/dev/null | grep -q decky; then
        warn "Decky Loader detected! It may conflict with Millennium."
        echo -e "${YELLOW}Options:${NC}"
        echo "  1) Uninstall Decky Loader (recommended)"
        echo "  2) Continue anyway (risky)"
        local response=""
        printf "Choose [1/2]: " > /dev/tty
        read -r response < /dev/tty
        case "$response" in
            1)
                info "Uninstalling Decky Loader..."
                curl -fsSL https://github.com/SteamDeckHomebrew/decky-loader/raw/main/uninstall.sh | bash || warn "Uninstall failed."
                ok "Decky Loader removed."
                ;;
            *)
                warn "Continuing with Decky Loader present. Expect issues."
                ;;
        esac
    fi
}

# ---------- Millennium detection (hybrid command + version extraction) ----------
is_millennium_installed() {
    local result
    result=$(sh -c 'pacman -Qs millennium 2>/dev/null || dpkg -l | grep millennium 2>/dev/null || rpm -qa | grep millennium 2>/dev/null || flatpak list | grep -i millennium 2>/dev/null || grep -i "version" ~/.local/share/millennium/bootstrap.log 2>/dev/null')
    [[ -n "$result" ]] && return 0
    [[ -f "/usr/lib/millennium/libmillennium.so" ]] || [[ -f "/usr/bin/steam.millennium.bak" ]]
}

get_millennium_version() {
    local result
    result=$(sh -c 'pacman -Qs millennium 2>/dev/null || dpkg -l | grep millennium 2>/dev/null || rpm -qa | grep millennium 2>/dev/null || flatpak list | grep -i millennium 2>/dev/null || grep -i "version" ~/.local/share/millennium/bootstrap.log 2>/dev/null')
    if [[ -n "$result" ]]; then
        local ver=""
        if [[ "$result" =~ [v]?([0-9]+\.[0-9]+\.[0-9]+) ]]; then
            ver="${BASH_REMATCH[1]}"
        elif [[ "$result" =~ version[\"[:space:]]*:[\"[:space:]]*([0-9]+\.[0-9]+\.[0-9]+) ]]; then
            ver="${BASH_REMATCH[1]}"
        else
            ver="unknown"
        fi
        echo "$ver"
    else
        if [[ -f "/usr/lib/millennium/version.txt" ]]; then
            cat "/usr/lib/millennium/version.txt" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
        elif [[ -f "/usr/lib/millennium/libmillennium.so" ]]; then
            strings "/usr/lib/millennium/libmillennium.so" 2>/dev/null | grep -oE 'Millennium v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed 's/.*v//'
        else
            echo ""
        fi
    fi
}

# ---------- Accela detection (improved for ACCELA.AppImage) ----------
is_accela_installed() {
    local accela_dir="$HOME/.local/share/ACCELA"
    if [[ ! -d "$accela_dir" ]]; then
        return 1
    fi
    if [[ -f "$accela_dir/run.sh" && -x "$accela_dir/run.sh" ]]; then
        return 0
    fi
    while IFS= read -r file; do
        if [[ -f "$file" && -x "$file" ]]; then
            if [[ "$(basename "$file")" == "ACCELA.AppImage" ]]; then
                return 0
            fi
            if file "$file" 2>/dev/null | grep -q "ELF.*executable"; then
                return 0
            fi
        fi
    done < <(find "$accela_dir" -maxdepth 1 -type f -executable 2>/dev/null)
    return 1
}

detect_accela_type() {
    local accela_dir="$HOME/.local/share/ACCELA"
    if [[ ! -d "$accela_dir" ]]; then
        echo "none"
        return
    fi
    if [[ -f "$accela_dir/run.sh" && -x "$accela_dir/run.sh" ]]; then
        echo "run.sh"
        return
    fi
    if [[ -f "$accela_dir/ACCELA.AppImage" && -x "$accela_dir/ACCELA.AppImage" ]]; then
        echo "appimage"
        return
    fi
    while IFS= read -r file; do
        if [[ -f "$file" && -x "$file" ]]; then
            if file "$file" 2>/dev/null | grep -q "ELF.*executable"; then
                echo "appimage"
                return
            fi
        fi
    done < <(find "$accela_dir" -maxdepth 1 -type f -executable 2>/dev/null)
    echo "unknown"
}

get_accela_filename() {
    local accela_dir="$HOME/.local/share/ACCELA"
    if [[ ! -d "$accela_dir" ]]; then
        echo ""
        return
    fi
    if [[ -f "$accela_dir/run.sh" && -x "$accela_dir/run.sh" ]]; then
        echo "run.sh"
        return
    fi
    if [[ -f "$accela_dir/ACCELA.AppImage" && -x "$accela_dir/ACCELA.AppImage" ]]; then
        echo "ACCELA.AppImage"
        return
    fi
    while IFS= read -r file; do
        if [[ -f "$file" && -x "$file" ]]; then
            basename "$file"
            return
        fi
    done < <(find "$accela_dir" -maxdepth 1 -type f -executable 2>/dev/null)
    echo ""
}

# ---------- Plugin directory cleanup ----------
clean_plugin_dir() {
    local plugin_paths=(
        "$HOME/.local/share/millennium/plugins/LuaToolsLinux"
        "$HOME/.steam/steam/millennium/plugins/LuaToolsLinux"
        "$HOME/.steam/steam/steamui/millennium/plugins/LuaToolsLinux"
    )
    for path in "${plugin_paths[@]}"; do
        if [[ -d "$path" ]]; then
            info "Removing old plugin directory: $path"
            rm -rf "$path"
        fi
    done
}

# ---------- Dependency fix ----------
run_fix_deps() {
    info "Running dependency fix script (fix-deps)..."
    curl -fsSL https://raw.githubusercontent.com/ciscosweater/enter-the-wired/main/fix-deps | bash || warn "fix-deps failed, but continuing..."
}

# ---------- Install Python requirements for LuaTools ----------
install_python_requirements() {
    info "Installing Python requirements (httpx, beautifulsoup4, ruamel.yaml)..."

    local venv_paths=(
        "$HOME/.local/share/millennium/plugins/LuaToolsLinux/.venv"
        "$HOME/.steam/steam/millennium/plugins/LuaToolsLinux/.venv"
        "$HOME/.steam/steam/steamui/millennium/plugins/LuaToolsLinux/.venv"
    )
    local pip_cmd=""
    for vp in "${venv_paths[@]}"; do
        if [[ -f "$vp/bin/pip" ]]; then
            pip_cmd="$vp/bin/pip"
            info "Found virtual environment at $vp"
            break
        fi
    done

    if [[ -z "$pip_cmd" ]]; then
        warn "No virtual environment found for LuaTools plugin. Trying system pip (user install)."
        if command -v pip3 >/dev/null; then
            pip_cmd="pip3 install --user"
        elif command -v pip >/dev/null; then
            pip_cmd="pip install --user"
        else
            warn "pip not found. Skipping Python requirements installation."
            return
        fi
    else
        pip_cmd="$pip_cmd install"
    fi

    local packages=("httpx==0.27.2" "beautifulsoup4" "ruamel.yaml==0.18.6")
    for pkg in "${packages[@]}"; do
        info "Installing $pkg ..."
        if $pip_cmd "$pkg" 2>/dev/null; then
            ok "Installed $pkg"
        else
            warn "Failed to install $pkg"
        fi
    done
    ok "Python requirements installation completed."
}

# ---------- Additional Ubuntu/Debian libssl-dev:i386 prompt ----------
check_libssl_dev() {
    local family=$(get_distro_family)
    if [[ "$family" != "debian" ]]; then
        return
    fi
    if dpkg -s libssl-dev:i386 2>/dev/null | grep -q '^Status:.*installed'; then
        ok "libssl-dev:i386 is already installed."
        return
    fi
    warn "libssl-dev:i386 (32-bit development libraries) is missing."
    echo "This library is required for 32-bit compatibility with some components."
    local response=""
    printf "Do you want to install libssl-dev:i386 now? [y/N]: " > /dev/tty
    read -r response < /dev/tty
    if [[ "$response" =~ ^[Yy]$ ]]; then
        info "Enabling i386 architecture and installing libssl-dev:i386..."
        sudo dpkg --add-architecture i386 || true
        sudo apt update || true
        sudo apt install -y libssl-dev:i386 || warn "Installation failed. You may need to run 'sudo apt install -f' manually."
        if dpkg -s libssl-dev:i386 2>/dev/null | grep -q '^Status:.*installed'; then
            ok "libssl-dev:i386 installed successfully."
        else
            warn "libssl-dev:i386 could not be installed. Some features may not work."
        fi
    else
        info "Skipping libssl-dev:i386 installation."
    fi
}

# ---------- Installers ----------
install_millennium_beta() {
    info "Installing Millennium (beta via steambrew.app)..."
    curl -fsSL "https://steambrew.app/install.sh" | bash -s -- --beta || fail "Millennium beta installation failed."
    ok "Millennium beta installed."
}

install_plugin_for_version() {
    local version="$1"
    local plugin_url="$LUATOOLS_MILLENNIUM_URL"
    if [[ -n "$version" ]]; then
        local major_minor=$(echo "$version" | cut -d. -f1-2)
        if [[ "$(echo "$major_minor < 2.36" | bc -l 2>/dev/null)" == "1" ]]; then
            plugin_url="$LUATOOLS_LEGACY_URL"
            warn "Millennium version $version (< 2.36). Using legacy plugin."
        fi
    fi
    info "Installing LuaTools plugin for Millennium version ${version:-beta}"
    clean_plugin_dir
    run_remote_script "$plugin_url"
    install_python_requirements
    ok "Plugin installed."
}

install_accela_and_slssteam() {
    info "Installing accela and slssteam via enter-the-wired..."
    curl -fsSL https://raw.githubusercontent.com/ciscosweater/enter-the-wired/main/enter-the-wired | bash || warn "Accela installation failed."
    ok "Accela and slssteam installation completed."
}

# ---------- Option 1: Install All (forces Millennium reinstall) ----------
install_all() {
    info "Starting FULL installation (Millennium + plugin + accela & slssteam)..."
    run_fix_deps
    force_close_steam

    install_millennium_beta
    local new_version=$(get_millennium_version)
    install_plugin_for_version "$new_version"

    install_accela_and_slssteam
    start_steam
    ok "Full installation complete. Steam has been started."
}

# ---------- Option 2: Only Millennium + plugin (reinstall plugin if Millennium exists) ----------
install_millennium_flow() {
    run_fix_deps
    force_close_steam

    if is_millennium_installed; then
        local current_version=$(get_millennium_version)
        ok "Millennium already installed. Version: ${current_version:-unknown}"
        echo ""
        local response=""
        printf "Reinstall/update LuaTools plugin? [y/N]: " > /dev/tty
        read -r response < /dev/tty
        if [[ "$response" =~ ^[Yy]$ ]]; then
            install_plugin_for_version "$current_version"
        else
            info "No action taken."
        fi
    else
        info "Millennium not installed. Installing Millennium beta + latest plugin..."
        install_millennium_beta
        local new_version=$(get_millennium_version)
        install_plugin_for_version "$new_version"
    fi
    start_steam
}

fix_remove_piracy_blocks() {
    local theme_css_dir="$HOME/.steam/steam/millennium/themes/Steam/src/css"
    local files_to_fix=(
        "libraryroot.custom.css"
        "overlay.custom.css"
        "regular.css"
        "startupLogin.custom.css"
        "webkit.css"
        "steam/gamepage.css"
    )

    echo ""
    if [[ ! -d "$theme_css_dir" ]]; then
        warn "Theme CSS directory not found: $theme_css_dir"
        warn "Make sure Millennium and the theme are installed correctly."
        return 1
    fi
    ok "Directory found: $theme_css_dir"

    local any_fixed=false

    for filename in "${files_to_fix[@]}"; do
        local filepath="$theme_css_dir/$filename"
        if [[ ! -f "$filepath" ]]; then
            echo "$filename -> NOT FOUND, skipping"
            continue
        fi

        echo -n "$filename ... "

        # Backup
        cp "$filepath" "$filepath.bak"

        # Remover linhas com a mensagem
        sed -i '/Pls remove any piracy plugin/d' "$filepath"

        # Remover linhas com seletores de luatools
        sed -i '/\[class\*="luatools"/d' "$filepath"
        sed -i '/\[data-millennium-plugin\*="luatools"/d' "$filepath"

        # Remover linhas com seletores de manilua
        sed -i '/\[class\*="manilua"/d' "$filepath"
        sed -i '/\[data-millennium-plugin\*="manilua"/d' "$filepath"

        # Remover linhas com seletores de lumea
        sed -i '/\[class\*="lumea"/d' "$filepath"
        sed -i '/\[data-millennium-plugin\*="lumea"/d' "$filepath"

        # Remover linhas vazias
        sed -i '/^[[:space:]]*$/d' "$filepath"

        # Verificar se houve mudança
        if ! cmp -s "$filepath" "$filepath.bak"; then
            echo "✔ Removed"
            any_fixed=true
        else
            rm -f "$filepath.bak"
            echo "○ No block found"
        fi
    done

    echo ""
    if $any_fixed; then
        ok "Anti-piracy blocks removed. Restart Steam for changes to take effect."
        info "You can restart Steam with: pkill -9 steam; nohup steam >/dev/null 2>&1 &"
    else
        warn "No changes made. The theme may already be clean."
    fi
}

# ---------- Fixes menu ----------
fix_purchase_error() {
    info "Fixing 'Purchase error' by running headcrab script..."
    curl -fsSL "https://raw.githubusercontent.com/Deadboy666/h3adcr-b/refs/heads/main/headcrab.sh" | bash || warn "Headcrab script failed."
    ok "Purchase error fix attempted. You may need to restart Steam."
}

fix_missing_keys() {
    info "Fixing 'Missing Keys'..."
    rm -rf ~/.config/SLSsteam ~/.config/headcrab
    info "Removed ~/.config/SLSsteam and ~/.config/headcrab"
    if [[ ! -d "$HOME/enter-the-wired" ]]; then
        info "Cloning enter-the-wired repository..."
        git clone "$ENTERTHEWIRED_REPO" "$HOME/enter-the-wired" || {
            warn "Git clone failed. Trying to download via curl..."
            mkdir -p "$HOME/enter-the-wired"
            curl -fsSL "https://raw.githubusercontent.com/ciscosweater/enter-the-wired/main/slssteam" -o "$HOME/enter-the-wired/slssteam"
            chmod +x "$HOME/enter-the-wired/slssteam"
        }
    fi
    if [[ -x "$HOME/enter-the-wired/slssteam" ]]; then
        ~/enter-the-wired/slssteam
    else
        warn "~/enter-the-wired/slssteam not found or not executable."
    fi
    ok "Missing Keys fix attempted."
}

fix_no_licenses_info() {
    echo ""
    echo -e "${YELLOW}No licenses error - Information${NC}"
    echo "This error usually occurs when:"
    echo "  1) You downloaded the game to the wrong folder, or"
    echo "  2) You haven't set the correct path to accela in the LuaTools menu."
    echo ""
    echo "To fix:"
    echo "  - Open Steam, go to LuaTools plugin settings."
    echo "  - Ensure the path to accela is correctly set (to ~/.local/share/ACCELA or wherever accela is located)."
    echo "  - In the accela menu, enable the option: 'Limit downloads to Steam Library'."
    echo ""
    read -p "Press Enter to continue..." < /dev/tty
}

fix_menu() {
    while true; do
        echo ""
        echo -e "${BOLD}Common Issues Fixes${NC}"
        echo "1) Purchase error (headcrab)"
        echo "2) Missing Keys"
        echo "3) No licenses (information)"
        echo "4) Run fix-deps (install system dependencies)"
        echo "5) Remove anti-piracy blocks from Steam theme CSS"
        echo "6) Back to main menu"
        echo ""
        printf "Choose an option [1-6]: " > /dev/tty
        local choice; read -r choice < /dev/tty
        case "$choice" in
            1) fix_purchase_error ;;
            2) fix_missing_keys ;;
            3) fix_no_licenses_info ;;
            4) run_fix_deps ;;
            5) fix_remove_piracy_blocks ;;
            6) break ;;
            *) warn "Invalid option." ;;
        esac
    done
}

# ---------- Uninstall (includes accela/slssteam removal) ----------
uninstall_all_flow() {
    info "Uninstalling everything (Millennium, plugin, accela, slssteam)..."

    # 1. Remove Millennium
    info "Removing Millennium Framework files..."
    sudo rm -rf /usr/lib/millennium /usr/share/millennium \
                "${XDG_CONFIG_HOME:-$HOME/.config}/millennium" \
                "${XDG_DATA_HOME:-$HOME/.local/share}/millennium"
    if [ -f "/usr/bin/steam.millennium.bak" ]; then
        info "Restoring original Steam executable..."
        sudo mv /usr/bin/steam.millennium.bak /usr/bin/steam
    fi
    rm -f "${HOME}/.steam/steam/ubuntu12_32/libXtst.so.6"

    # 2. Remove LuaTools plugin directories
    info "Removing LuaTools plugin remnants..."
    rm -rf "${XDG_DATA_HOME:-$HOME/.local/share}/luatools" \
           "${XDG_CONFIG_HOME:-$HOME/.config}/luatools" \
           "${HOME}/.luatools" 2>/dev/null || true
    clean_plugin_dir

    # 3. Uninstall accela and slssteam using the official uninstall script
    info "Uninstalling accela and slssteam via enter-the-wired uninstaller..."
    curl -fsSL https://raw.githubusercontent.com/ciscosweater/enter-the-wired/main/uninstall | bash || warn "Accela/slssteam uninstall may have failed."

    ok "Full uninstall completed."
}

# ---------- Main menu ----------
interactive_menu() {
    while true; do
        echo ""
        echo -e "${BOLD}LuaTools Installer${NC}"
        echo "1) Install All Millennium + plugin + accela & slssteam"
        echo "2) Install/Reinstall Millennium + LuaTools plugin"
        echo "3) Install accela and slssteam only"
        echo "4) Uninstall Everything (Millennium + plugin + accela + slssteam)"
        echo "5) Fix common issues"
        echo "6) Cancel"
        echo ""
        printf "Choose an option [1-6]: " > /dev/tty
        local choice; read -r choice < /dev/tty
        case "$choice" in
            1) install_all ; break ;;
            2) install_millennium_flow ; break ;;
            3) install_accela_and_slssteam ; break ;;
            4) uninstall_all_flow ; break ;;
            5) fix_menu ;;
            6) info "Cancelled." ; exit 0 ;;
            *) warn "Invalid option." ;;
        esac
    done
}

# ---------- Entry point ----------
main() {
    for arg in "$@"; do
        if [[ "$arg" == "--debug" ]]; then
            DEBUG=true
            set -x
        fi
    done

    require_cmd curl
    require_cmd bash
    if ! command -v git >/dev/null; then
        warn "git not installed. Some fix functions may fail."
    fi

    check_internet
    check_architecture
    check_steam_compatibility
    check_decky_loader

    echo ""
    if is_millennium_installed; then
        local mver=$(get_millennium_version)
        ok "Millennium: installed (version ${mver:-unknown})"
    else
        warn "Millennium: NOT installed"
    fi

    if is_accela_installed; then
        local atype=$(detect_accela_type)
        local fname=$(get_accela_filename)
        if [[ "$atype" == "appimage" ]]; then
            warn "Accela: installed as AppImage (file: $fname). You may need to manually set the path in LuaTools menu (point to ~/.local/share/ACCELA/$fname)."
        elif [[ "$atype" == "run.sh" ]]; then
            ok "Accela: installed as run.sh script."
        else
            ok "Accela: installed (type unknown)"
        fi
    else
        warn "Accela: NOT installed"
    fi

    check_libssl_dev

    case "${1:-}" in
        1|--install-all)       install_all ;;
        2|--millennium)        install_millennium_flow ;;
        3|--accela)            install_accela_and_slssteam ;;
        4|--uninstall)         uninstall_all_flow ;;
        5|--fix)               fix_menu ;;
        --cancel)              info "Cancelled." ; exit 0 ;;
        -h|--help)
            cat <<'EOF'
Usage: install.sh [option] [--debug]

Options:
    1, --install-all     Install all (Millennium + plugin + accela & slssteam)
    2, --millennium      Install/Reinstall Millennium + LuaTools plugin
    3, --accela          Install accela and slssteam only
    4, --uninstall       Uninstall everything (Millennium + plugin + accela + slssteam)
    5, --fix             Open the common issues fix menu
    --cancel             Exit without installing
    --debug              Enable debug output
    -h, --help           Show this help

If no option is given, an interactive menu is shown after status report.
EOF
            exit 0
            ;;
        "")
            interactive_menu
            ;;
        *)
            warn "Unknown argument: $1"
            echo "Use -h for help."
            exit 1
            ;;
    esac

    echo ""
    read -p "Press Enter to close this terminal..." < /dev/tty
}

main "$@"
