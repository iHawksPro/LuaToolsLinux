#!/usr/bin/env bash
set -euo pipefail

SELF_REPO_BASE="https://raw.githubusercontent.com/Star123451/LuaToolsLinux/main"
LUATOOLS_LEGACY_URL="$SELF_REPO_BASE/update_legacy.sh"
ENTERTHEWIRED_REPO="https://github.com/ciscosweater/enter-the-wired.git"
LEGACY_ACCELA_REPO="https://raw.githubusercontent.com/aglairdev/enter-the-wired/main/enter-the-wired"
ACCELA_FIX_REPO="https://github.com/Cybercountry/ACCELA_FIX.git"   # ===== NOVO =====

REPO_OWNER="Star123451"
REPO_NAME="LuaToolsLinux"
RELEASE_ASSET_NAME="ltsteamplugin.zip"
GITHUB_API_URL="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
PLUGIN_NAME="luatools"

HEADCRAB_URL="https://headcrab.pages.dev"

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

# ---------- Controle do modo read-only em sistemas imutáveis ----------
IMMUTABLE_DISABLED=false

is_immutable_system() {
    # Detecta SteamOS (Steam Deck)
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "$ID" == "steamos" ]]; then
            return 0
        fi
    fi
    # Detecta fedora Silverblue/Kinoite
    if command -v rpm-ostree &>/dev/null; then
        return 0
    fi
    # Detecta sistemas com ostree (ex: Endless OS)
    if [[ -d /sysroot/ostree || -f /run/ostree-booted ]]; then
        return 0
    fi
    # Comando específico do SteamOS
    if command -v steamos-readonly &>/dev/null; then
        return 0
    fi
    return 1
}

disable_readonly() {
    if ! is_immutable_system; then
        return 0
    fi
    if [[ "$IMMUTABLE_DISABLED" == "true" ]]; then
        return 0
    fi
    info "Sistema imutável detectado. Desabilitando read-only temporariamente..."
    if command -v steamos-readonly &>/dev/null; then
        sudo steamos-readonly disable || warn "steamos-readonly disable falhou"
    elif command -v rpm-ostree &>/dev/null; then
        # No Fedora imutável, desbloqueia para escrita (overlay)
        sudo ostree admin unlock --hotfix || warn "ostree unlock falhou"
    else
        warn "Não foi possível desabilitar read-only automaticamente. Continuando..."
    fi
    IMMUTABLE_DISABLED=true
}

reenable_readonly() {
    if ! is_immutable_system; then
        return 0
    fi
    if [[ "$IMMUTABLE_DISABLED" != "true" ]]; then
        return 0
    fi
    info "Reabilitando read-only do sistema imutável..."
    if command -v steamos-readonly &>/dev/null; then
        sudo steamos-readonly enable || warn "steamos-readonly enable falhou"
    elif command -v rpm-ostree &>/dev/null; then
        # No Fedora imutável, após desbloquear, apenas reiniciar resolve,
        # mas tentamos remover o overlay ou simplesmente avisar.
        warn "Sistema rpm-ostree: read-only será reativado após reinicialização."
    fi
    IMMUTABLE_DISABLED=false
}

# Garantir que readonly seja reabilitado ao sair do script (mesmo com erro)
trap reenable_readonly EXIT

# ---------- Instalar jq se ausente ----------
ensure_jq() {
    if command -v jq &>/dev/null; then
        return 0
    fi
    warn "jq não encontrado. Tentando instalar automaticamente..."
    disable_readonly   # Abre o sistema para escrita se necessário
    local family=$(get_distro_family)
    case "$family" in
        debian)
            sudo apt update && sudo apt install -y jq
            ;;
        fedora)
            sudo dnf install -y jq
            ;;
        arch)
            sudo pacman -S --noconfirm jq
            ;;
        opensuse)
            sudo zypper install -y jq
            ;;
        alpine)
            sudo apk add jq
            ;;
        *)
            warn "Não foi possível instalar jq automaticamente. Instale manualmente."
            return 1
            ;;
    esac
    if command -v jq &>/dev/null; then
        ok "jq instalado com sucesso."
    else
        fail "Falha ao instalar jq. Instale manualmente."
    fi
}

# ---------- SteamOS preparação (pip etc) ----------
prepare_steamos() {
    if ! is_immutable_system; then
        return
    fi
    info "Preparando ambiente SteamOS (instalando python-pip e dependências)..."
    disable_readonly
    sudo pacman-key --init || warn "pacman-key --init falhou"
    sudo pacman-key --populate archlinux || warn "populate archlinux falhou"
    sudo pacman-key --populate holo || warn "populate holo falhou"
    sudo pacman -S --noconfirm python-pip || warn "Instalação do python-pip falhou"
    ok "Preparação SteamOS concluída."
}

# ---------- extract zip (sem mudanças) ----------
extract_zip() {
    local archive_path="$1"
    local destination="$2"
    mkdir -p "$destination"
    if command -v unzip &>/dev/null; then
        unzip -qo "$archive_path" -d "$destination"
        return 0
    fi
    if command -v python3 &>/dev/null; then
        python3 - "$archive_path" "$destination" <<'PY'
import sys, zipfile
archive = sys.argv[1]
dest = sys.argv[2]
with zipfile.ZipFile(archive, "r") as zf:
    zf.extractall(dest)
PY
        return 0
    fi
    return 1
}

# ---------- Install plugin from GitHub release (agora com jq) ----------
install_plugin_from_release() {
    info "Installing LuaTools plugin from latest GitHub release..."
    ensure_jq
    if ! command -v curl &>/dev/null; then
        fail "curl is required"
    fi
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir:-}"' EXIT
    local meta_file="$tmp_dir/release.json"
    if ! curl -fsSL "$GITHUB_API_URL" -o "$meta_file"; then
        fail "Failed to fetch latest release metadata"
    fi
    local latest_tag asset_url
    latest_tag=$(jq -r '.tag_name' "$meta_file")
    asset_url=$(jq -r --arg name "$RELEASE_ASSET_NAME" '.assets[] | select(.name==$name) | .browser_download_url' "$meta_file")
    if [[ -z "$asset_url" || "$asset_url" == "null" ]]; then
        fail "Release asset '$RELEASE_ASSET_NAME' not found"
    fi
    info "Latest release: ${latest_tag:-unknown}"
    local zip_file="$tmp_dir/$RELEASE_ASSET_NAME"
    info "Downloading $RELEASE_ASSET_NAME ..."
    if ! curl -fL "$asset_url" -o "$zip_file"; then
        fail "Download failed"
    fi
    local millennium_dir=""
    local candidates=(
        "$HOME/.local/share/millennium/plugins"
        "$HOME/.millennium/plugins"
        "$HOME/.steam/steam/millennium/plugins"
        "$HOME/.local/share/Steam/millennium/plugins"
    )
    for dir in "${candidates[@]}"; do
        if [[ -d "$dir" ]]; then
            millennium_dir="$dir"
            break
        fi
    done
    if [[ -z "$millennium_dir" ]]; then
        millennium_dir="$HOME/.local/share/millennium/plugins"
        mkdir -p "$millennium_dir"
        warn "Created plugins directory at $millennium_dir"
    fi
    local install_dir="$millennium_dir/$PLUGIN_NAME"
    info "Installing to $install_dir"
    if [[ -d "$install_dir" ]]; then
        rm -rf "$install_dir"
    fi
    mkdir -p "$install_dir"
    if ! extract_zip "$zip_file" "$install_dir"; then
        fail "Extraction failed"
    fi
    ok "Plugin installed (version ${latest_tag:-latest})"
}

# ---------- Python dependencies (sem mudanças) ----------
check_python_dependencies() {
    info "Checking Python dependencies (httpx, beautifulsoup4, ruamel.yaml)..."
    if ! command -v python3 &>/dev/null; then
        warn "python3 not found. Cannot check dependencies."
        return 1
    fi
    if python3 -c "import httpx, bs4, ruamel.yaml" 2>/dev/null; then
        ok "All Python dependencies are already satisfied."
        return 0
    fi
    warn "Some Python dependencies are missing. Attempting to install them..."

    local pip_cmd=""
    if command -v pip3 &>/dev/null; then
        pip_cmd="pip3"
    elif command -v pip &>/dev/null; then
        pip_cmd="pip"
    else
        warn "pip not found. Trying to install pip via ensurepip..."
        python3 -m ensurepip --upgrade 2>/dev/null || {
            warn "Could not install pip. Please install pip manually."
            return 1
        }
        pip_cmd="python3 -m pip"
    fi

    local packages=("httpx==0.27.2" "beautifulsoup4" "ruamel.yaml==0.18.6")
    for pkg in "${packages[@]}"; do
        info "Installing $pkg ..."
        if $pip_cmd install --user --break-system-packages "$pkg" &>/dev/null; then
            ok "Installed $pkg"
        else
            warn "Failed to install $pkg. Trying without --user..."
            if $pip_cmd install --break-system-packages "$pkg" &>/dev/null; then
                ok "Installed $pkg (system-wide)"
            else
                warn "Could not install $pkg. Manual installation may be required."
            fi
        fi
    done

    if python3 -c "import httpx, bs4, ruamel.yaml" 2>/dev/null; then
        ok "Python dependencies successfully installed."
        return 0
    else
        warn "Python dependencies still missing. You may need to install them manually:"
        echo "  pip install httpx beautifulsoup4 ruamel.yaml"
        return 1
    fi
}

# ---------- Mostrar status (sem mudanças) ----------
show_status() {
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
}

# ---------- Post-install instructions ----------
show_post_install_instructions() {
    if ! is_accela_installed; then
        return
    fi
    echo ""
    echo -e "${BOLD}${YELLOW}+----------------------------------------------------------------------+${NC}"
    echo -e "${BOLD}${YELLOW}|                    IMPORTANT: Accela Configuration                    |${NC}"
    echo -e "${BOLD}${YELLOW}+----------------------------------------------------------------------+${NC}"
    echo -e "${BOLD}${YELLOW}|${NC}  1) Open accela, config options/downloads.                           ${BOLD}${YELLOW}|${NC}"
    echo -e "${BOLD}${YELLOW}|${NC}  2) Ensure the option ${BOLD}\"Limit downloads to Steam Library\"${NC} is ${BOLD}ENABLED${NC}.              ${BOLD}${YELLOW}|${NC}"
    echo -e "${BOLD}${YELLOW}|${NC}  3) In Steam, click the Steam name at the top-left corner.          ${BOLD}${YELLOW}|${NC}"
    echo -e "${BOLD}${YELLOW}|${NC}     Open Millennium → Plugins tab → Enable ${BOLD}LuaTools${NC}.                    ${BOLD}${YELLOW}|${NC}"
    echo -e "${BOLD}${YELLOW}|${NC}  4) Go to Lua tools menu on Steam/config ${BOLD}\"External Launcher (ACCELA)\"${NC}               ${BOLD}${YELLOW}|${NC}"
    echo -e "${BOLD}${YELLOW}|${NC}     and click the folder icon.                                        ${BOLD}${YELLOW}|${NC}"
    echo -e "${BOLD}${YELLOW}|${NC}  5) Navigate to ${BOLD}~/.local/share/ACCELA${NC} and select:                                   ${BOLD}${YELLOW}|${NC}"
    echo -e "${BOLD}${YELLOW}|${NC}       - ${GREEN}run.sh${NC} (if installed as script) or                                     ${BOLD}${YELLOW}|${NC}"
    echo -e "${BOLD}${YELLOW}|${NC}       - ${GREEN}ACCELA.AppImage${NC} (if using AppImage)                                  ${BOLD}${YELLOW}|${NC}"
    echo -e "${BOLD}${YELLOW}|${NC}  6) Click the save icon (diskette).                                      ${BOLD}${YELLOW}|${NC}"
    echo -e "${BOLD}${YELLOW}|${NC}  7) You can now add your game directly from the game page.                ${BOLD}${YELLOW}|${NC}"
    echo -e "${BOLD}${YELLOW}+----------------------------------------------------------------------+${NC}"
    echo ""
}

# ---------- Pre-flight checks (check_internet, arch, etc.) ----------
check_internet() {
    info "Checking internet connectivity..."
    if ! curl -fsS --head "https://github.com" >/dev/null 2>&1; then
        fail "No internet connection"
    fi
    ok "Internet reachable"
}

check_architecture() {
    if [[ "$(uname -m)" != "x86_64" ]]; then
        fail "Unsupported architecture: $(uname -m). Only x86_64 works."
    fi
    ok "Architecture x86_64 OK"
}

force_close_steam() {
    if pgrep -x "steam" >/dev/null; then
        warn "Steam is running. Closing it now..."
        pkill -x steam || true
        sleep 3
        if pgrep -x "steam" >/dev/null; then
            warn "Steam still running. Please close it manually."
        else
            ok "Steam closed"
        fi
    fi
}

start_steam() {
    info "Starting Steam..."
    nohup steam >/dev/null 2>&1 &
    ok "Steam launched"
}

# ---------- Steam compatibility (sem mudanças) ----------
detect_steam_type() {
    local steam_type="unknown"
    if command -v flatpak >/dev/null && flatpak list 2>/dev/null | grep -q "com.valvesoftware.Steam"; then
        steam_type="flatpak"
    elif command -v snap >/dev/null && snap list 2>/dev/null | grep -q "^steam "; then
        steam_type="snap"
    elif command -v steam >/dev/null && [[ -f /usr/bin/steam ]]; then
        steam_type="native"
    fi
    echo "$steam_type"
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
            warn "Could not determine Steam type. Assuming native, be careful."
            ;;
    esac
}

check_decky_loader() {
    if [[ -d "$HOME/.local/share/decky" ]] || [[ -f "$HOME/.steam/steam/plugins/decky-loader" ]] || ( command -v systemctl >/dev/null && systemctl --user list-units 2>/dev/null | grep -q decky ); then
        warn "Decky Loader detected! May conflict with Millennium."
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
                ok "Decky Loader removed"
                ;;
            *)
                warn "Continuing with Decky Loader present. Expect issues."
                ;;
        esac
    fi
}

# ---------- Millennium detection ----------
is_millennium_installed() {
    local result=""
    if command -v pacman >/dev/null; then
        result=$(pacman -Qs millennium 2>/dev/null)
    fi
    if [[ -z "$result" ]] && command -v dpkg >/dev/null; then
        result=$(dpkg -l | grep millennium 2>/dev/null)
    fi
    if [[ -z "$result" ]] && command -v rpm >/dev/null; then
        result=$(rpm -qa | grep millennium 2>/dev/null)
    fi
    if [[ -z "$result" ]] && command -v flatpak >/dev/null; then
        result=$(flatpak list | grep -i millennium 2>/dev/null)
    fi
    if [[ -z "$result" ]] && [[ -f "$HOME/.local/share/millennium/bootstrap.log" ]]; then
        result=$(grep -i "version" "$HOME/.local/share/millennium/bootstrap.log" 2>/dev/null)
    fi
    [[ -n "$result" ]] && return 0
    [[ -f "/usr/lib/millennium/libmillennium.so" ]] || [[ -f "/usr/bin/steam.millennium.bak" ]]
}

get_millennium_version() {
    local result=""
    if command -v pacman >/dev/null; then
        result=$(pacman -Qs millennium 2>/dev/null)
    fi
    if [[ -z "$result" ]] && command -v dpkg >/dev/null; then
        result=$(dpkg -l | grep millennium 2>/dev/null)
    fi
    if [[ -z "$result" ]] && command -v rpm >/dev/null; then
        result=$(rpm -qa | grep millennium 2>/dev/null)
    fi
    if [[ -z "$result" ]] && command -v flatpak >/dev/null; then
        result=$(flatpak list | grep -i millennium 2>/dev/null)
    fi
    if [[ -z "$result" ]] && [[ -f "$HOME/.local/share/millennium/bootstrap.log" ]]; then
        result=$(grep -i "version" "$HOME/.local/share/millennium/bootstrap.log" 2>/dev/null)
    fi
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

# ---------- Accela detection ----------
is_accela_installed() {
    local accela_dir="$HOME/.local/share/ACCELA"
    [[ -d "$accela_dir" ]] || return 1
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
    [[ -d "$accela_dir" ]] || { echo "none"; return; }
    if [[ -f "$accela_dir/run.sh" && -x "$accela_dir/run.sh" ]]; then
        echo "run.sh"
        return
    fi
    if [[ -f "$accela_dir/ACCELA.AppImage" && -x "$accela_dir/ACCELA.AppImage" ]]; then
        echo "appimage"
        return
    fi
    while IFS= read -r file; do
        if [[ -f "$file" && -x "$file" ]] && file "$file" 2>/dev/null | grep -q "ELF.*executable"; then
            echo "appimage"
            return
        fi
    done < <(find "$accela_dir" -maxdepth 1 -type f -executable 2>/dev/null)
    echo "unknown"
}

get_accela_filename() {
    local accela_dir="$HOME/.local/share/ACCELA"
    [[ -d "$accela_dir" ]] || { echo ""; return; }
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

clean_plugin_dir() {
    local plugin_paths=(
        "$HOME/.local/share/millennium/plugins/LuaToolsLinux"
        "$HOME/.steam/steam/millennium/plugins/LuaToolsLinux"
        "$HOME/.steam/steam/steamui/millennium/plugins/LuaToolsLinux"
    )
    for path in "${plugin_paths[@]}"; do
        if [[ -d "$path" ]]; then
            rm -rf "$path"
        fi
    done
}

# ---------- fix-deps ----------
run_fix_deps() {
    info "Running dependency fix script (fix-deps)..."
    curl -fsSL https://raw.githubusercontent.com/ciscosweater/enter-the-wired/main/fix-deps | bash || warn "fix-deps failed, continuing..."
}

# ---------- libssl-dev check (Debian) ----------
check_libssl_dev() {
    local family=$(get_distro_family)
    [[ "$family" != "debian" ]] && return
    if dpkg -s libssl-dev:i386 2>/dev/null | grep -q '^Status:.*installed'; then
        ok "libssl-dev:i386 already installed."
        return
    fi
    warn "libssl-dev:i386 (32-bit dev libs) is missing."
    local response=""
    printf "Install libssl-dev:i386 now? [y/N]: " > /dev/tty
    read -r response < /dev/tty
    if [[ "$response" =~ ^[Yy]$ ]]; then
        sudo dpkg --add-architecture i386 || true
        sudo apt update || true
        sudo apt install -y libssl-dev:i386 || warn "Installation failed."
    else
        info "Skipping libssl-dev:i386."
    fi
}

# ---------- Installers ----------
install_millennium_beta() {
    info "Installing Millennium beta via steambrew.app..."
    curl -fsSL "https://steambrew.app/install.sh" | bash -s -- --beta || fail "Millennium beta installation failed."
    ok "Millennium beta installed"
}

install_millennium_legacy() {
    info "Installing Millennium Legacy (old version) + LuaTools plugin..."
    force_close_steam
    curl -fsSL "https://github.com/SteamClientHomebrew/Millennium/raw/refs/heads/legacy/scripts/install.sh" | bash || fail "Millennium Legacy installation failed."
    ok "Millennium Legacy installed"
    install_plugin_from_release
    check_python_dependencies
    start_steam
    info "Millennium Legacy + plugin installation completed. Steam started."
}

install_accela_and_slssteam() {
    info "Installing accela and slssteam via enter-the-wired (standard AppImage version)..."
    curl -fsSL https://raw.githubusercontent.com/ciscosweater/enter-the-wired/main/enter-the-wired | bash || warn "Accela installation failed."
    ok "Accela and slssteam installed"
}

install_legacy_accela_and_sls() {
    info "Installing Legacy Accela (source-based, run.sh) + SLSsteam (headcrab)..."
    info "This combination fixes AppImage compatibility issues by using the Python source version from aglairdev/enter-the-wired."
    curl -fsSL "$LEGACY_ACCELA_REPO" | bash || fail "Legacy Accela installation failed."
    ok "Legacy Accela (run.sh) and SLSsteam installed successfully."
    show_post_install_instructions
}

# ===== NOVA FUNÇÃO: Instalar Accela (Cybercountry) para corrigir illegal instruction =====
install_accela_fix_illegal_instruction() {
    info "Installing Accela to fix illegal instruction (by Cybercountry) + SLSsteam..."

    local temp_dir
    temp_dir="$(mktemp -d)"
    cd "$temp_dir"

    info "Cloning ACCELA_FIX repository from Cybercountry..."
    if ! git clone "$ACCELA_FIX_REPO" ACCELA_FIX; then
        warn "Git clone failed. Trying with curl fallback..."
        rm -rf ACCELA_FIX
        curl -fsSL "https://github.com/Cybercountry/ACCELA_FIX/archive/refs/heads/main.tar.gz" | tar xz --strip-components=1 -C "$temp_dir" || {
            fail "Failed to download ACCELA_FIX"
        }
        if [[ ! -f "$temp_dir/RUN_ME" ]]; then
            fail "Could not obtain ACCELA_FIX files."
        fi
    else
        cd ACCELA_FIX
    fi

    chmod +x RUN_ME 2>/dev/null || chmod +x "$temp_dir/ACCELA_FIX/RUN_ME" 2>/dev/null || warn "RUN_ME not found or not executable"

    info "Executing ACCELA_FIX installer (RUN_ME) - this will set up Accela..."
    if [[ -f "./RUN_ME" ]]; then
        ./RUN_ME || warn "ACCELA_FIX installer reported issues, but continuing..."
    elif [[ -f "$temp_dir/RUN_ME" ]]; then
        "$temp_dir/RUN_ME" || warn "ACCELA_FIX installer reported issues, but continuing..."
    else
        warn "RUN_ME script not found. Installation may be incomplete."
    fi

    cd - >/dev/null
    rm -rf "$temp_dir"

    info "Installing SLSsteam via headcrab..."
    if ! curl -fsSL "$HEADCRAB_URL" | bash; then
        warn "SLSsteam installation had issues. You may need to run headcrab manually later."
    else
        ok "SLSsteam installed successfully."
    fi

    ok "Accela (by Cybercountry) and SLSsteam installation completed."
    show_post_install_instructions
}
# ===== FIM DA NOVA FUNÇÃO =====

# ---------- Install All ----------
install_all() {
    info "Starting FULL installation (Millennium beta + plugin + accela standard)..."
    run_fix_deps
    force_close_steam
    install_millennium_beta
    install_plugin_from_release
    check_python_dependencies
    install_accela_and_slssteam
    start_steam
    show_status
    show_post_install_instructions
    ok "Full installation complete. Steam has been started."
}

install_millennium_flow() {
    run_fix_deps
    force_close_steam
    if is_millennium_installed; then
        local current_version=$(get_millennium_version)
        ok "Millennium already installed. Version: ${current_version:-unknown}"
    else
        info "Millennium not installed. Installing Millennium beta first..."
        install_millennium_beta
    fi
    install_plugin_from_release
    check_python_dependencies
    start_steam
    show_status
    if is_accela_installed; then
        show_post_install_instructions
    fi
    ok "Plugin installation complete. Steam has been started."
}

install_millennium_legacy_flow() {
    install_millennium_legacy
}

install_accela_only() {
    info "Installing accela and slssteam only (standard AppImage version)..."
    install_accela_and_slssteam
    show_status
    show_post_install_instructions
    ok "Accela installation completed."
}

install_legacy_accela_and_sls_only() {
    info "Installing Legacy Accela (source-based, run.sh) + SLSsteam only..."
    install_legacy_accela_and_sls
    show_status
    ok "Legacy Accela + SLSsteam installation completed."
}

# ---------- Fixes menu (com headcrab atualizado) + NOVAS OPÇÕES ----------
fix_purchase_error() {
    info "Fixing 'Purchase error' by running headcrab script..."
    curl -fsSL "$HEADCRAB_URL" | bash || warn "Headcrab script failed."
    ok "Purchase error fix attempted."
}

fix_missing_keys() {
    info "Fixing 'Missing Keys'..."
    rm -rf ~/.config/SLSsteam ~/.config/headcrab
    info "Removed ~/.config/SLSsteam and ~/.config/headcrab"
    if [[ ! -d "$HOME/enter-the-wired" ]]; then
        info "Cloning enter-the-wired repository..."
        git clone "$ENTERTHEWIRED_REPO" "$HOME/enter-the-wired" || {
            warn "Git clone failed. Trying curl..."
            mkdir -p "$HOME/enter-the-wired"
            curl -fsSL "https://raw.githubusercontent.com/ciscosweater/enter-the-wired/main/slssteam" -o "$HOME/enter-the-wired/slssteam"
            chmod +x "$HOME/enter-the-wired/slssteam"
        }
    fi
    if [[ -x "$HOME/enter-the-wired/slssteam" ]]; then
        ~/enter-the-wired/slssteam
    else
        warn "slssteam not found."
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

fix_remove_piracy_blocks() {
    # Auto-detect theme directory
    local theme_dirs=(
        "$HOME/.steam/steam/millennium/themes/Steam"
        "$HOME/.local/share/Steam/millennium/themes/Steam"
        "$HOME/.millennium/themes/Steam"
    )
    local theme_dir=""
    for dir in "${theme_dirs[@]}"; do
        if [[ -d "$dir/src/css" ]]; then
            theme_dir="$dir"
            break
        fi
    done

    if [[ -z "$theme_dir" ]]; then
        warn "Theme directory not found."
        warn "Make sure Millennium and the SpaceTheme are installed."
        return 1
    fi

    local css_dir="$theme_dir/src/css"
    local files=(
        "friends.custom.css"
        "inputs/inputs.css"
        "plugins/hltb.css"
        "webkit.css"
        "startupLogin.custom.css"
        "regular.css"
        "libraryroot.custom.css"
    )

    echo ""
    ok "Theme directory found: $theme_dir"
    echo ""

    local any_fixed=false
    for filename in "${files[@]}"; do
        local filepath="$css_dir/$filename"
        if [[ ! -f "$filepath" ]]; then
            echo "  $filename -> NOT FOUND, skipping"
            continue
        fi

        echo -n "  $filename ... "
        cp "$filepath" "$filepath.bak"

        python3 -c "
import re, sys
with open('$filepath', 'r') as f:
    c = f.read()
old = c
c = re.sub(r'/\*.*?Ban piracy plugins.*?\*/.*?color: #fff !important;\n\}', '', c, flags=re.DOTALL)
c = re.sub(r'.*?(luatools|manilua|lumea).*?\n', '', c)
c = re.sub(r'\n{3,}', '\n\n', c)
if c != old:
    with open('$filepath', 'w') as f:
        f.write(c)
    sys.exit(0)
else:
    sys.exit(1)
"

        if [[ $? -eq 0 ]]; then
            echo "✔ Removed"
            any_fixed=true
        else
            rm -f "$filepath.bak"
            echo "○ No block found"
        fi
    done

    echo ""
    if $any_fixed; then
        ok "Anti-piracy blocks removed. Restart Steam/Millennium to apply."
    else
        warn "No blocks found."
    fi
}

fix_reinstall_steam_clean() {
    echo ""
    echo -e "${BOLD}${RED}⚠️  WARNING: COMPLETE STEAM REINSTALL ⚠️${NC}"
    echo -e "${YELLOW}This will REMOVE ALL DOWNLOADED GAMES, configurations,"
    echo -e "Proton prefixes and any other Steam-related data (except saves"
    echo -e "that live outside Steam's folder, like Stardew Valley in ~/.config/StardewValley).${NC}"
    echo ""
    echo -e "${BOLD}To keep your downloaded games, BACKUP the following folder BEFORE proceeding:${NC}"
    echo -e "  ${GREEN}~/.local/share/Steam/steamapps/${NC}  or  ${GREEN}~/.steam/steam/steamapps/${NC}"
    echo ""
    echo -e "${BOLD}Backup example:${NC}"
    echo "  cp -r ~/.local/share/Steam/steamapps ~/backup_steamapps"
    echo ""
    echo -e "${RED}Have you backed up your games?${NC}"
    printf "Type [y/N]: " > /dev/tty
    local backup_ok; read -r backup_ok < /dev/tty
    if [[ ! "$backup_ok" =~ ^[Yy]$ ]]; then
        warn "Operation cancelled. Please backup and run again."
        return
    fi

    echo ""
    echo -e "${YELLOW}Continuing... Closing Steam if running.${NC}"
    force_close_steam

    info "Removing Steam package..."
    if command -v pacman >/dev/null; then
        sudo pacman -Rdd steam --noconfirm 2>/dev/null || warn "Steam package not installed?"
    elif command -v apt >/dev/null; then
        sudo apt remove --purge steam -y
    elif command -v dnf >/dev/null; then
        sudo dnf remove steam -y
    else
        warn "Package manager not recognized. Please remove Steam manually."
    fi

    info "Removing Steam config and data folders..."
    rm -rf ~/.steam ~/.local/share/Steam ~/.var/app/com.valvesoftware.Steam ~/.steampath ~/.steampid
    sudo rm -rf /usr/lib/steam /usr/share/steam 2>/dev/null || true

    info "Cleaning icon cache and shortcuts..."
    rm -f ~/.local/share/applications/steam*.desktop
    sudo update-desktop-database 2>/dev/null || true

    ok "Steam completely removed from system."

    echo ""
    echo -e "${BOLD}Do you want to reinstall Steam now?${NC}"
    printf "[y/N]: " > /dev/tty
    local reinstall_choice; read -r reinstall_choice < /dev/tty
    if [[ "$reinstall_choice" =~ ^[Yy]$ ]]; then
        info "Reinstalling Steam..."
        if command -v pacman >/dev/null; then
            sudo pacman -S steam --noconfirm
        elif command -v apt >/dev/null; then
            sudo apt install steam -y
        elif command -v dnf >/dev/null; then
            sudo dnf install steam -y
        else
            echo "Please install Steam manually."
        fi
        ok "Steam reinstalled."
        echo -e "${CYAN}To restore your games, copy the 'steamapps' folder back to ~/.local/share/Steam/ before launching Steam.${NC}"
    else
        info "You can reinstall Steam later with: sudo pacman -S steam"
    fi

    echo ""
    read -p "Press Enter to return to menu..." < /dev/tty
}

fix_missing_game_executable() {
    echo ""
    echo -e "${BOLD}${CYAN}Error: 'Missing game executable' or 'Fail on compatibility tool'${NC}"
    echo -e "${YELLOW}Troubleshooting steps:${NC}"
    echo ""
    echo "1) Right-click on the game in your Steam library."
    echo "2) Go to Properties → Compatibility."
    echo "3) Check the box 'Force the use of a specific Steam Play compatibility tool'."
    echo "4) For Linux native games: select 'Steam Linux Runtime' or 'Legacy Runtime'."
    echo "5) For Windows games: select a Proton version."
    echo "   - Check ProtonDB (https://www.protondb.com) for the best Proton version for your game."
    echo "   - 'Proton Experimental' often works well for many games."
    echo "6) Launch the game again."
    echo ""
    read -p "Press Enter to continue..." < /dev/tty
}

fix_content_still_encrypted() {
    echo ""
    echo -e "${BOLD}${CYAN}Error: 'Content Still Encrypted'${NC}"
    echo -e "${YELLOW}Troubleshooting steps:${NC}"
    echo ""
    echo "1) Right-click on the game in your Steam library."
    echo "2) Go to Properties → Compatibility."
    echo "3) Check the box 'Force the use of a specific Steam Play compatibility tool'."
    echo "4) For Linux native games: select 'Steam Linux Runtime' or 'Legacy Runtime'."
    echo "5) For Windows games: select a Proton version (check ProtonDB for best choice or use Experimental)."
    echo "6) Still in Properties, go to 'Installed Files'."
    echo "7) Click 'Verify integrity of game files'."
    echo "8) Wait for verification to complete, then launch the game."
    echo ""
    read -p "Press Enter to continue..." < /dev/tty
}

fix_online_fix_not_working() {
    echo ""
    echo -e "${BOLD}${CYAN}Error: Online Fix doesn't work${NC}"
    echo -e "${YELLOW}Troubleshooting steps:${NC}"
    echo ""
    echo "1) Apply the online fix files to the game installation folder."
    echo "2) In Steam, right-click on the game → Properties."
    echo "3) In 'Launch Options', paste the following:"
    echo ""
    echo -e "${GREEN}WINEDLLOVERRIDES=\"OnlineFix64=n;SteamOverlay64=n;winmm=n,b;dnet=n;steam_api64=n;winhttp=n,b\" %command%${NC}"
    echo ""
    echo "4) Close Properties and launch the game."
    echo ""
    read -p "Press Enter to continue..." < /dev/tty
}

# ===== NOVAS FUNÇÕES DE FIX =====
fix_crack_dll_config() {
    echo ""
    echo -e "${BOLD}${CYAN}Crack don't work?${NC}"
    echo -e "${YELLOW}If your crack/online fix includes one or more .dll files, you need to tell Wine/Proton to load them properly.${NC}"
    echo ""
    echo -e "${BOLD}Steps:${NC}"
    echo "1) Identify the DLL file(s) that came with the crack (e.g., voices38.dll, steam_api64.dll, OnlineFix64.dll, etc.)."
    echo "2) In Steam, right-click on the game → Properties → General."
    echo "3) In the 'LAUNCH OPTIONS' field, add:"
    echo ""
    echo -e "${GREEN}WINEDLLOVERRIDES=\"dllname=n,b\" %command%${NC}"
    echo ""
    echo -e "${YELLOW}Replace \"dllname\" with the actual DLL filename (without the .dll extension).${NC}"
    echo ""
    echo "Examples:"
    echo -e "  - If the DLL is called ${GREEN}voices38.dll${NC} → ${GREEN}WINEDLLOVERRIDES=\"voices38=n,b\" %command%${NC}"
    echo -e "  - If the DLL is called ${GREEN}OnlineFix64.dll${NC} → ${GREEN}WINEDLLOVERRIDES=\"OnlineFix64=n,b\" %command%${NC}"
    echo -e "  - For multiple DLLs, separate with semicolons: ${GREEN}WINEDLLOVERRIDES=\"dll1=n,b;dll2=n,b\" %command%${NC}"
    echo ""
    echo "4) Close Properties and launch the game."
    echo ""
    read -p "Press Enter to continue..." < /dev/tty
}

fix_game_not_downloading() {
    echo ""
    echo -e "${BOLD}${RED}⚠️  GAME NOT DOWNLOADING? ⚠️${NC}"
    echo -e "${YELLOW}You probably skipped the post-installation configuration.${NC}"
    echo -e "${YELLOW}You did NOT set the Accela path in LuaTools menu, or you are trying to download directly from Steam without Accela.${NC}"
    echo ""
    echo -e "${BOLD}Follow the instructions below that you skipped earlier:${NC}"
    echo ""
    echo -e "${BOLD}${YELLOW}+----------------------------------------------------------------------+${NC}"
    echo -e "${BOLD}${YELLOW}|                    IMPORTANT: Accela Configuration                    |${NC}"
    echo -e "${BOLD}${YELLOW}+----------------------------------------------------------------------+${NC}"
    echo -e "${BOLD}${YELLOW}|${NC}  1) Open accela, config options/downloads.                           ${BOLD}${YELLOW}|${NC}"
    echo -e "${BOLD}${YELLOW}|${NC}  2) Ensure the option ${BOLD}\"Limit downloads to Steam Library\"${NC} is ${BOLD}ENABLED${NC}.              ${BOLD}${YELLOW}|${NC}"
    echo -e "${BOLD}${YELLOW}|${NC}  3) In Steam, click the Steam name at the top-left corner.          ${BOLD}${YELLOW}|${NC}"
    echo -e "${BOLD}${YELLOW}|${NC}     Open Millennium → Plugins tab → Enable ${BOLD}LuaTools${NC}.                    ${BOLD}${YELLOW}|${NC}"
    echo -e "${BOLD}${YELLOW}|${NC}  4) Go to Lua tools menu on Steam/config ${BOLD}\"External Launcher (ACCELA)\"${NC}               ${BOLD}${YELLOW}|${NC}"
    echo -e "${BOLD}${YELLOW}|${NC}     and click the folder icon.                                        ${BOLD}${YELLOW}|${NC}"
    echo -e "${BOLD}${YELLOW}|${NC}  5) Navigate to ${BOLD}~/.local/share/ACCELA${NC} and select:                                   ${BOLD}${YELLOW}|${NC}"
    echo -e "${BOLD}${YELLOW}|${NC}       - ${GREEN}run.sh${NC} (if installed as script) or                                     ${BOLD}${YELLOW}|${NC}"
    echo -e "${BOLD}${YELLOW}|${NC}       - ${GREEN}ACCELA.AppImage${NC} (if using AppImage)                                  ${BOLD}${YELLOW}|${NC}"
    echo -e "${BOLD}${YELLOW}|${NC}  6) Click the save icon (diskette).                                      ${BOLD}${YELLOW}|${NC}"
    echo -e "${BOLD}${YELLOW}|${NC}  7) You can now add your game directly from the game page.                ${BOLD}${YELLOW}|${NC}"
    echo -e "${BOLD}${YELLOW}+----------------------------------------------------------------------+${NC}"
    echo ""
    echo -e "${GREEN}After completing these steps, try downloading your game again.${NC}"
    echo ""
    read -p "Press Enter to continue..." < /dev/tty
}

fix_speed_units_explanation() {
    echo ""
    echo -e "${BOLD}${CYAN}Accela download speed seems slower than Steam?${NC}"
    echo -e "${YELLOW}This is usually just a difference in units!${NC}"
    echo ""
    echo -e "${BOLD}Explanation:${NC}"
    echo -e "  - Steam shows download speed in ${BOLD}Megabits per second (Mbps)${NC} (symbol: Mb/s or Mbit/s)."
    echo -e "  - Accela (and most browser download managers) shows speed in ${BOLD}Megabytes per second (MB/s)${NC}."
    echo ""
    echo -e "${BOLD}1 Megabyte (MB) = 8 Megabits (Mb)${NC}"
    echo ""
    echo "Example:"
    echo "  Steam shows 600 Mb/s  →  divided by 8  →  equals 75 MB/s in Accela."
    echo "  If Accela shows 60 MB/s → multiplied by 8 → equals 480 Mb/s on Steam."
    echo ""
    echo -e "${BOLD}So your speeds are actually the same, just displayed differently!${NC}"
    echo ""
    echo "-------------------------------------------"
    echo ""
    echo -e "${BOLD}Why does Accela's percentage update slowly on large files?${NC}"
    echo -e "  - Accela downloads files ${BOLD}one by one${NC} (sequentially)."
    echo "  - Steam downloads many small files in parallel, updating percentage more frequently."
    echo -e "  - The ${BOLD}download speed${NC} (in MB/s) is what really matters."
    echo "  - As long as the speed number matches your internet bandwidth, everything is fine."
    echo ""
    echo "To check if a download is actually progressing:"
    echo -e "  - Look at the ${BOLD}speed indicator${NC} (MB/s in Accela). If it's > 0, you're downloading."
    echo "  - The percentage may freeze for a few seconds on very large files, but it will jump once the file finishes."
    echo ""
    read -p "Press Enter to continue..." < /dev/tty
}
# ===== FIM DAS NOVAS FUNÇÕES =====

fix_menu() {
    while true; do
        echo ""
        echo -e "${BOLD}Common Issues Fixes${NC}"
        echo "1) Purchase error or slssteam issues (headcrab)"
        echo "2) Missing Keys"
        echo "3) No licenses (information)"
        echo "4) Run fix-deps (install system dependencies)"
        echo "5) Remove anti-piracy blocks from Steam theme CSS"
        echo "6) Reinstall Steam completely (clean) - WILL DELETE GAMES!"
        echo "7) Missing game executable / Fail on compatibility tool (info)"
        echo "8) Content Still Encrypted (info)"
        echo "9) Online Fix doesn't work (info)"
        echo "10) Crack don't work?"                     # ===== NOVA =====
        echo "11) Game not downloading? Read Important Configuration Note"  # ===== NOVA =====
        echo "12) Accela download speed slower than Steam? Read explanation" # ===== NOVA =====
        echo "13) Back to main menu"
        echo ""
        printf "Choose an option [1-13]: " > /dev/tty
        local choice; read -r choice < /dev/tty
        case "$choice" in
            1) fix_purchase_error ;;
            2) fix_missing_keys ;;
            3) fix_no_licenses_info ;;
            4) run_fix_deps ;;
            5) fix_remove_piracy_blocks ;;
            6) fix_reinstall_steam_clean ;;
            7) fix_missing_game_executable ;;
            8) fix_content_still_encrypted ;;
            9) fix_online_fix_not_working ;;
            10) fix_crack_dll_config ;;      # ===== NOVA =====
            11) fix_game_not_downloading ;;   # ===== NOVA =====
            12) fix_speed_units_explanation ;; # ===== NOVA =====
            13) break ;;
            *) warn "Invalid option." ;;
        esac
    done
}

# ---------- Uninstall ----------
uninstall_all_flow() {
    info "Uninstalling everything (Millennium, plugin, accela, slssteam)..."
    sudo rm -rf /usr/lib/millennium /usr/share/millennium \
                "${XDG_CONFIG_HOME:-$HOME/.config}/millennium" \
                "${XDG_DATA_HOME:-$HOME/.local/share}/millennium"
    if [ -f "/usr/bin/steam.millennium.bak" ]; then
        sudo mv /usr/bin/steam.millennium.bak /usr/bin/steam
    fi
    rm -f "${HOME}/.steam/steam/ubuntu12_32/libXtst.so.6"
    rm -rf "${XDG_DATA_HOME:-$HOME/.local/share}/luatools" \
           "${XDG_CONFIG_HOME:-$HOME/.config}/luatools" \
           "${HOME}/.luatools" 2>/dev/null || true
    clean_plugin_dir
    curl -fsSL https://raw.githubusercontent.com/ciscosweater/enter-the-wired/main/uninstall | bash || warn "Accela/slssteam uninstall may have failed."
    ok "Full uninstall completed."
}

# ---------- Menu principal ----------
interactive_menu() {
    while true; do
        echo ""
        echo -e "${BOLD}LuaTools Installer${NC}"
        echo "1) Install All (Millennium beta + plugin + accela standard)"
        echo "2) Install/Reinstall LuaTools plugin only (keeps Millennium)"
        echo "3) Install accela and slssteam only (standard - AppImage)"
        echo "4) Install Accela to issue illegal instructions (by Cybercountry) + slssteam"   # ===== NOVA =====
        echo "5) Install Legacy Accela (run.sh) + SLSsteam (fix for AppImage issues)"
        echo "6) Fix common issues"
        echo "7) Uninstall Everything"
        echo "8) Cancel"
        echo ""
        printf "Choose an option [1-8]: " > /dev/tty
        local choice; read -r choice < /dev/tty
        case "$choice" in
            1) install_all ; break ;;
            2) install_millennium_flow ; break ;;
            3) install_accela_only ; break ;;
            4) install_accela_fix_illegal_instruction ; break ;;   # ===== NOVA =====
            5) install_legacy_accela_and_sls_only ; break ;;
            6) fix_menu ;;
            7) uninstall_all_flow ; break ;;
            8) info "Cancelled." ; exit 0 ;;
            *) warn "Invalid option." ;;
        esac
    done
}

# ---------- Main ----------
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
    # Prepara ambiente SteamOS/imutável (desabilita readonly, instala pip)
    prepare_steamos
    check_steam_compatibility
    check_decky_loader
    show_status
    check_libssl_dev
    case "${1:-}" in
        1|--install-all)       install_all ;;
        2|--millennium)        install_millennium_flow ;;
        3|--accela)            install_accela_only ;;
        4|--fix-accela)        install_accela_fix_illegal_instruction ;;  # ===== NOVA =====
        5|--legacy-accela)     install_legacy_accela_and_sls_only ;;
        6|--fix)               fix_menu ;;
        7|--uninstall)         uninstall_all_flow ;;
        --cancel)              info "Cancelled." ; exit 0 ;;
        -h|--help)
            cat <<'EOF'
Usage: install.sh [option] [--debug]

Options:
    1, --install-all       Install all (Millennium beta + plugin + accela standard)
    2, --millennium        Install/Reinstall LuaTools plugin only (keeps Millennium)
    3, --accela            Install accela and slssteam only (standard - AppImage)
    4, --fix-accela        Install Accela to fix illegal instruction (by Cybercountry) + slssteam
    5, --legacy-accela     Install Legacy Accela (source-based, run.sh) + SLSsteam (FIX)
    6, --fix               Open fixes menu
    7, --uninstall         Uninstall everything
    --cancel               Exit
    --debug                Enable debug output
    -h, --help             Show this help
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
