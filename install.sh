#!/usr/bin/env bash
set -uo pipefail

# URLs
STABLE_M_URL="https://github.com/SteamClientHomebrew/Millennium/releases/download/v2.35.0/millennium-v2.35.0-linux-x86_64.tar.gz"
LT_18_URL="https://github.com/Star123451/LuaToolsLinux/releases/download/1.8/ltsteamplugin.zip"
LT_17_URL="https://github.com/Star123451/LuaToolsLinux/releases/download/1.7/LuaTools.zip"
REMOTE_UPDATE_URL="https://raw.githubusercontent.com/Star123451/LuaToolsLinux/main/update.sh"

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

info() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok() { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1."
}

# --- OPTION 1: MILLENNIUM 2.35.0 STABLE + LUATOOLS ---
install_millennium_235() {
    info "Installing Millennium 2.35.0 (Stable)..."
    
    local install_dir="/tmp/millennium_235"
    rm -rf "$install_dir" && mkdir -p "$install_dir/files"

    info "Downloading Millennium v2.35.0..."
    curl -L "$STABLE_M_URL" -o "$install_dir/millennium.tar.gz"
    tar xzf "$install_dir/millennium.tar.gz" -C "$install_dir/files"

    info "Cleaning old system files..."
    sudo rm -rf /usr/lib/millennium /usr/share/millennium

    info "Copying files to system folders..."
    sudo cp -r "$install_dir/files"/* / || true

    local target="${HOME}/.steam/steam/ubuntu12_32/libXtst.so.6"
    info "Setting up Steam hook..."
    mkdir -p "$(dirname "$target")"
    ln -sf /usr/lib/millennium/libmillennium_bootstrap_86x.so "$target"

    rm -rf "$install_dir"

    info "Running LuaTools update script..."
    curl -fsSL "$REMOTE_UPDATE_URL" | bash

    ok "Millennium 2.35.0 and LuaTools installed!"
}

# --- OPTION 2: PLUGIN 1.8 FOR BETA MILLENNIUM 3.0 ---
install_plugin_30() {
    local plugins_base="${XDG_DATA_HOME:-$HOME/.local/share}/millennium/plugins"
    local luatools_dir="$plugins_base/luatools"
    
    info "Installing Plugin 1.8 (ltsteamplugin.zip)..."
    
    if [ -d "$plugins_base" ]; then
        info "Clearing Millennium plugins folder..."
        rm -rf "$plugins_base"
    fi

    info "Creating directory: $luatools_dir"
    mkdir -p "$luatools_dir"

    info "Downloading ltsteamplugin.zip v1.8..."
    if curl -L "$LT_18_URL" -o /tmp/ltsteamplugin.zip; then
        info "Extracting to $luatools_dir..."
        unzip -o /tmp/ltsteamplugin.zip -d "$luatools_dir"
        rm /tmp/ltsteamplugin.zip
        ok "Plugin 1.8 successfully extracted to $luatools_dir!"
    else
        fail "Failed to download ltsteamplugin.zip"
    fi
}

# --- OPTION 3: PLUGIN 1.7 FOR MILLENNIUM 2.35/2.36 ---
install_plugin_legacy() {
    local plugins_base="${XDG_DATA_HOME:-$HOME/.local/share}/millennium/plugins"
    local luatools_dir="$plugins_base/luatools"
    
    info "Installing Plugin 1.7 (LuaTools.zip) for Millennium 2.35/2.36..."
    
    if [ -d "$plugins_base" ]; then
        info "Clearing Millennium plugins folder..."
        rm -rf "$plugins_base"
    fi

    info "Creating directory: $luatools_dir"
    mkdir -p "$luatools_dir"

    info "Downloading LuaTools.zip v1.7..."
    if curl -L "$LT_17_URL" -o /tmp/LuaTools_17.zip; then
        info "Extracting to $luatools_dir..."
        unzip -o /tmp/LuaTools_17.zip -d "$luatools_dir"
        rm /tmp/LuaTools_17.zip
        ok "Plugin 1.7 successfully extracted to $luatools_dir!"
    else
        fail "Failed to download LuaTools.zip"
    fi
}

# --- OPTION 4: UNINSTALL ---
uninstall_all() {
    info "Uninstalling everything..."
    sudo rm -rf /usr/lib/millennium /usr/share/millennium
    rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/millennium"
    rm -rf "${XDG_DATA_HOME:-$HOME/.local/share}/millennium"
    
    [ -f "/usr/bin/steam.millennium.bak" ] && sudo mv /usr/bin/steam.millennium.bak /usr/bin/steam
    rm -f "${HOME}/.steam/steam/ubuntu12_32/libXtst.so.6"
    
    ok "System is clean."
}

# --- MENU ---
interactive_menu() {
    echo -e "\n${BOLD}LuaTools Linux All-in-One Installer${NC}"
    echo "1) Install Millennium 2.35.0 (Stable) + LuaTools Plugin"
    echo "2) Install Only Plugin 1.8 to BETA Millennium 3.0"
    echo "3) Install Only Plugin 1.7 to Millennium 2.35/2.36 and olders"
    echo "4) Uninstall Everything"
    echo "5) Exit"
    echo ""
    
    # FORÇA a leitura vir do teclado e não do curl
    exec < /dev/tty
    
    printf "Choice [1-5]: "
    local choice=""
    read -r choice
    
    case "$choice" in
        1) install_millennium_235 ;;
        2) install_plugin_30 ;;
        3) install_plugin_legacy ;;
        4) uninstall_all ;;
        5) exit 0 ;;
        *) fail "Invalid option." ;;
    esac
}

main() {
    require_cmd curl
    require_cmd unzip
    require_cmd tar

    if [[ $# -gt 0 ]]; then
        case "$1" in
            --stable) install_millennium_235 ;;
            --plugin-18) install_plugin_30 ;;
            --plugin-17) install_plugin_legacy ;;
            --uninstall) uninstall_all ;;
            *) interactive_menu ;;
        esac
    else
        interactive_menu
    fi

    echo -e "\n${GREEN}[ FINISHED ]${NC}"
    
    exec < /dev/tty
    read -p "Press Enter to exit..."
}

main "$@"
