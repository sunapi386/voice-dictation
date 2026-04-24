#!/usr/bin/env bash
set -euo pipefail

# Voice Dictation Installer for Ubuntu 24.04+ (X11 & Wayland)
# https://github.com/sunapi386/voice-dictation
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/sunapi386/voice-dictation/main/install.sh | bash
#   curl -fsSL ... | bash -s -- --model distil-large-v3
#   curl -fsSL ... | bash -s -- --model large-v3

REPO_URL="https://raw.githubusercontent.com/sunapi386/voice-dictation/main"
INSTALL_DIR="$HOME/.local/share/voice-dictation"
BIN_DIR="$HOME/.local/bin"
MODEL=""
SKIP_SHORTCUT=false

# ─── Parse args ──────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model) MODEL="$2"; shift 2 ;;
        --skip-shortcut) SKIP_SHORTCUT=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Helpers ─────────────────────────────────────────────────────────────────

info()  { echo -e "\033[1;34m→\033[0m $*"; }
ok()    { echo -e "\033[1;32m✓\033[0m $*"; }
warn()  { echo -e "\033[1;33m!\033[0m $*"; }
fail()  { echo -e "\033[1;31m✗\033[0m $*"; exit 1; }

# ─── Preflight checks ───────────────────────────────────────────────────────

info "Checking system..."

[[ -f /etc/os-release ]] || fail "Cannot detect OS — expected Ubuntu 24.04+"
source /etc/os-release
if [[ "$ID" != "ubuntu" ]] || [[ "${VERSION_ID%%.*}" -lt 24 ]]; then
    fail "Requires Ubuntu 24.04 or later (detected: $PRETTY_NAME)"
fi
ok "Ubuntu $VERSION_ID"

RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_GB=$((RAM_KB / 1024 / 1024))
ok "${RAM_GB}GB RAM"

SESSION_TYPE="${XDG_SESSION_TYPE:-x11}"
ok "Display server: $SESSION_TYPE"

# ─── Model selection ─────────────────────────────────────────────────────────

recommend_model() {
    if [[ $RAM_GB -ge 16 ]]; then
        echo "distil-large-v3"
    elif [[ $RAM_GB -ge 8 ]]; then
        echo "small"
    elif [[ $RAM_GB -ge 4 ]]; then
        echo "base"
    else
        echo "tiny"
    fi
}

VALID_MODELS="tiny base small medium large-v3 distil-large-v3 distil-medium.en distil-small.en"
RECOMMENDED=$(recommend_model)

if [[ -z "$MODEL" ]]; then
    MODEL="$RECOMMENDED"
fi

echo "$VALID_MODELS" | tr ' ' '\n' | grep -qx "$MODEL" || \
    fail "Unknown model: $MODEL\nAvailable: $VALID_MODELS"

case "$MODEL" in
    large-v3)
        [[ $RAM_GB -lt 12 ]] && warn "large-v3 needs ~10GB RAM. You have ${RAM_GB}GB — may be slow or OOM."
        ;;
    distil-large-v3|medium)
        [[ $RAM_GB -lt 6 ]] && warn "$MODEL needs ~5GB RAM. You have ${RAM_GB}GB — may be tight."
        ;;
esac

info "Model: $MODEL (recommended for ${RAM_GB}GB RAM: $RECOMMENDED)"

# ─── Install system packages ────────────────────────────────────────────────

info "Installing system dependencies..."

sudo apt-get update -qq 2>/dev/null || true
sudo apt-get install -y -qq \
    portaudio19-dev python3-venv python3-dev git curl \
    pulseaudio-utils libnotify-bin \
    gir1.2-ayatanaappindicator3-0.1 \
    > /dev/null 2>&1

if [[ "$SESSION_TYPE" == "wayland" ]]; then
    sudo apt-get install -y -qq ydotool > /dev/null 2>&1
    ok "Installed ydotool (Wayland)"
else
    sudo apt-get install -y -qq xdotool > /dev/null 2>&1
    ok "Installed xdotool (X11)"
fi

ok "System dependencies installed"

# ─── Wayland-specific setup ─────────────────────────────────────────────────

if [[ "$SESSION_TYPE" == "wayland" ]]; then
    info "Configuring ydotool for Wayland..."

    if ! groups | grep -q '\binput\b'; then
        sudo usermod -aG input "$USER"
        warn "Added $USER to 'input' group — you must log out and back in for this to take effect"
    fi

    if [[ ! -f /etc/udev/rules.d/60-uinput.rules ]]; then
        sudo tee /etc/udev/rules.d/60-uinput.rules > /dev/null << 'UDEV'
KERNEL=="uinput", MODE="0660", GROUP="input"
UDEV
        sudo udevadm control --reload-rules && sudo udevadm trigger
    fi

    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/ydotool.service" << 'UNIT'
[Unit]
Description=ydotool daemon

[Service]
ExecStart=/usr/bin/ydotoold

[Install]
WantedBy=default.target
UNIT
    systemctl --user daemon-reload
    systemctl --user enable --now ydotool 2>/dev/null || true
    ok "ydotool configured"
fi

# ─── Python environment ─────────────────────────────────────────────────────

info "Setting up Python environment..."
mkdir -p "$INSTALL_DIR"

if [[ ! -d "$INSTALL_DIR/venv" ]] || [[ ! -f "$INSTALL_DIR/venv/bin/python" ]]; then
    rm -rf "$INSTALL_DIR/venv"
    python3 -m venv --system-site-packages "$INSTALL_DIR/venv"
fi

"$INSTALL_DIR/venv/bin/pip" install --upgrade pip -q 2>/dev/null
"$INSTALL_DIR/venv/bin/pip" install -q \
    faster-whisper numpy sounddevice soundfile pynput 2>/dev/null

ok "Python environment ready"

# ─── Download model ──────────────────────────────────────────────────────────

info "Downloading $MODEL model (this may take a minute)..."

"$INSTALL_DIR/venv/bin/python" -c "
from faster_whisper import WhisperModel
WhisperModel('$MODEL', device='cpu', compute_type='int8')
print('done')
" 2>/dev/null

ok "Model $MODEL downloaded and cached"

# ─── Install scripts ────────────────────────────────────────────────────────

info "Installing scripts to $BIN_DIR..."
mkdir -p "$BIN_DIR"

SCRIPTS="dictate-daemon.py dictate-start dictate-stop dictate-toggle dictate-model"
for script in $SCRIPTS; do
    curl -fsSL "$REPO_URL/scripts/$script" -o "$BIN_DIR/$script"
    chmod +x "$BIN_DIR/$script"
done

# Patch paths in shell scripts to match this install
sed -i "s|\\\$HOME/.local/share/voice-dictation|$INSTALL_DIR|g" "$BIN_DIR/dictate-start"

# Save chosen model
echo "$MODEL" > "$HOME/.config/dictation-model"

ok "Scripts installed"

# ─── Systemd service ────────────────────────────────────────────────────────

info "Setting up auto-start service..."
mkdir -p "$HOME/.config/systemd/user"

cat > "$HOME/.config/systemd/user/voice-dictation.service" << SVCEOF
[Unit]
Description=Voice Dictation Daemon
After=graphical-session.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/venv/bin/python $BIN_DIR/dictate-daemon.py
Restart=always
RestartSec=5

[Install]
WantedBy=graphical-session.target
SVCEOF

systemctl --user daemon-reload
systemctl --user enable voice-dictation 2>/dev/null
systemctl --user restart voice-dictation 2>/dev/null || true

ok "Daemon enabled (auto-starts on login)"

# ─── Keyboard shortcut ──────────────────────────────────────────────────────

if [[ "$SKIP_SHORTCUT" == true ]]; then
    warn "Skipping keyboard shortcut setup (--skip-shortcut)"
else
    info "Setting up Ctrl+Space shortcut..."

    gsettings set org.freedesktop.ibus.general.hotkey triggers "[]" 2>/dev/null || true

    EXISTING=$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings 2>/dev/null || echo "@as []")

    SLOT=""
    for i in $(seq 0 9); do
        NAME=$(gsettings get org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom${i}/ name 2>/dev/null || echo "''")
        if [[ "$NAME" == "'Dictation Toggle'" ]]; then
            SLOT=$i
            break
        fi
    done

    if [[ -z "$SLOT" ]]; then
        for i in $(seq 0 9); do
            NAME=$(gsettings get org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom${i}/ name 2>/dev/null || echo "''")
            if [[ "$NAME" == "''" ]]; then
                SLOT=$i
                break
            fi
        done
    fi

    [[ -z "$SLOT" ]] && SLOT=0

    SLOT_PATH="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom${SLOT}/"

    if ! echo "$EXISTING" | grep -q "custom${SLOT}"; then
        if [[ "$EXISTING" == "@as []" ]]; then
            NEW_LIST="['$SLOT_PATH']"
        else
            NEW_LIST=$(echo "$EXISTING" | sed "s/]$/, '$SLOT_PATH']/")
        fi
        gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$NEW_LIST"
    fi

    gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${SLOT_PATH} name 'Dictation Toggle'
    gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${SLOT_PATH} command "$BIN_DIR/dictate-toggle"
    gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${SLOT_PATH} binding '<Ctrl>space'

    ok "Ctrl+Space bound to dictation toggle"
fi

# ─── PATH check ──────────────────────────────────────────────────────────────

if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
    warn "$BIN_DIR is not in your PATH"
    warn "Add this to your shell config (~/.bashrc or ~/.config/fish/config.fish):"
    warn "  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# ─── Done ────────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ok "Voice dictation installed!"
echo ""
echo "  Ctrl+Space          Toggle recording"
echo "  Tray icon           Status + settings (model, sensitivity, hotkey)"
echo "  dictate-model       Show/change whisper model"
echo "  dictate-stop        Stop the daemon"
echo "  dictate-start       Start the daemon"
echo ""
echo "  Model: $MODEL"
echo "  Display: $SESSION_TYPE"
echo "  Auto-start: enabled (starts on login)"
echo ""
if [[ "$SESSION_TYPE" == "wayland" ]] && ! groups | grep -q '\binput\b'; then
    warn "Log out and back in for Wayland input permissions to take effect."
    echo ""
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
