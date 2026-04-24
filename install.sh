#!/usr/bin/env bash
set -euo pipefail

# Voice Dictation Installer for Ubuntu 24.04+ (X11 & Wayland)
# https://github.com/sunapi386/voice-dictation
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/jasonjgeiger/voice-dictation/main/install.sh | bash
#   curl -fsSL ... | bash -s -- --model distil-large-v3
#   curl -fsSL ... | bash -s -- --model large-v3

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

# Validate model name
echo "$VALID_MODELS" | tr ' ' '\n' | grep -qx "$MODEL" || \
    fail "Unknown model: $MODEL\nAvailable: $VALID_MODELS"

# Warn about RAM
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
    portaudio19-dev python3-venv python3-dev git \
    pulseaudio-utils libnotify-bin \
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

if [[ ! -d "$INSTALL_DIR/venv" ]]; then
    python3 -m venv "$INSTALL_DIR/venv"
fi

"$INSTALL_DIR/venv/bin/pip" install --upgrade pip -q 2>/dev/null
"$INSTALL_DIR/venv/bin/pip" install -q \
    faster-whisper numpy sounddevice soundfile 2>/dev/null

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

# Determine typing tool
if [[ "$SESSION_TYPE" == "wayland" ]]; then
    TYPE_CMD='ydotool type -- "$TEXT"'
else
    TYPE_CMD='xdotool type --delay 12 -- "$TEXT"'
fi

# ── dictate-stream.py ──

cat > "$BIN_DIR/dictate-stream.py" << 'PYEOF'
#!/usr/bin/env python3
"""Real-time voice dictation with VAD-based chunking.

Listens to microphone, detects pauses, transcribes each phrase,
and types it at the cursor. Text appears progressively as you speak.
"""

import argparse
import os
import signal
import subprocess
import sys

import numpy as np
import sounddevice as sd

SAMPLE_RATE = 16000
MODELS = [
    "tiny", "base", "small", "medium", "large-v3",
    "distil-large-v3", "distil-medium.en", "distil-small.en",
]

SESSION_TYPE = os.environ.get("XDG_SESSION_TYPE", "x11")


def type_text(text):
    if SESSION_TYPE == "wayland":
        subprocess.run(["ydotool", "type", "--", text], check=False)
    else:
        subprocess.run(["xdotool", "type", "--delay", "12", "--", text], check=False)


def notify(message):
    subprocess.run(["notify-send", "-t", "2000", "Dictation", message], check=False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="small", choices=MODELS)
    parser.add_argument("--language", default="en")
    parser.add_argument("--pause", type=float, default=0.7,
                        help="Seconds of silence before transcribing a phrase")
    parser.add_argument("--threshold", type=float, default=0.012,
                        help="RMS level below which audio counts as silence")
    args = parser.parse_args()

    from faster_whisper import WhisperModel

    notify(f"Loading {args.model}...")
    model = WhisperModel(args.model, device="cpu", compute_type="int8")
    notify("🎤 Listening — speak naturally")

    chunk_ms = 100
    chunk_size = SAMPLE_RATE * chunk_ms // 1000
    pause_chunks = int(args.pause / (chunk_ms / 1000))
    min_speech_chunks = int(0.4 / (chunk_ms / 1000))

    buf = []
    silence = 0
    speech = 0
    active = False
    running = True

    def stop(sig, frame):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    try:
        with sd.InputStream(samplerate=SAMPLE_RATE, channels=1, dtype="float32",
                            blocksize=chunk_size) as stream:
            while running:
                data, _ = stream.read(chunk_size)
                chunk = data[:, 0]
                rms = np.sqrt(np.mean(chunk ** 2))

                if rms > args.threshold:
                    buf.append(chunk)
                    speech += 1
                    silence = 0
                    active = True
                elif active:
                    buf.append(chunk)
                    silence += 1

                    if silence >= pause_chunks:
                        if speech >= min_speech_chunks:
                            audio = np.concatenate(buf)
                            segs, _ = model.transcribe(
                                audio, beam_size=5, language=args.language,
                                vad_filter=True,
                            )
                            text = " ".join(s.text.strip() for s in segs)
                            if text.strip():
                                type_text(text + " ")
                        buf.clear()
                        silence = 0
                        speech = 0
                        active = False
    except Exception as e:
        notify(f"❌ {e}")
        sys.exit(1)

    notify("🛑 Stopped")


if __name__ == "__main__":
    main()
PYEOF

# ── dictate-start ──

cat > "$BIN_DIR/dictate-start" << STARTEOF
#!/bin/bash
VENV="$INSTALL_DIR/venv/bin/python"
PID_FILE="/tmp/dictation.pid"
MODEL_FILE="\$HOME/.config/dictation-model"

if [ -f "\$PID_FILE" ] && kill -0 "\$(cat "\$PID_FILE")" 2>/dev/null; then
    notify-send -t 2000 "Dictation" "Already running — press hotkey to stop"
    exit 0
fi

MODEL="$MODEL"
[ -f "\$MODEL_FILE" ] && MODEL=\$(cat "\$MODEL_FILE")

\$VENV "$BIN_DIR/dictate-stream.py" --model "\$MODEL" &
echo \$! > "\$PID_FILE"
STARTEOF

# ── dictate-stop ──

cat > "$BIN_DIR/dictate-stop" << 'STOPEOF'
#!/bin/bash
PID_FILE="/tmp/dictation.pid"

if [ ! -f "$PID_FILE" ]; then
    notify-send -t 2000 "Dictation" "Not running"
    exit 0
fi

PID=$(cat "$PID_FILE")
if kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null
    tail --pid="$PID" -f /dev/null 2>/dev/null || sleep 0.5
fi
rm -f "$PID_FILE"
STOPEOF

# ── dictate-toggle ──

cat > "$BIN_DIR/dictate-toggle" << TOGGLEEOF
#!/bin/bash
PID_FILE="/tmp/dictation.pid"

if [ -f "\$PID_FILE" ] && kill -0 "\$(cat "\$PID_FILE")" 2>/dev/null; then
    $BIN_DIR/dictate-stop
else
    $BIN_DIR/dictate-start
fi
TOGGLEEOF

# ── dictate-model ──

cat > "$BIN_DIR/dictate-model" << 'MODELEOF'
#!/bin/bash
MODEL_FILE="$HOME/.config/dictation-model"
MODELS="tiny base small medium large-v3 distil-large-v3 distil-medium.en distil-small.en"

if [ -z "$1" ]; then
    CURRENT="small"
    [ -f "$MODEL_FILE" ] && CURRENT=$(cat "$MODEL_FILE")
    echo "Current model: $CURRENT"
    echo ""
    echo "  tiny              75MB   ~1GB RAM   Fastest, lower accuracy"
    echo "  base             142MB   ~1GB RAM   Fast, decent accuracy"
    echo "  small            466MB   ~2GB RAM   Good balance (default)"
    echo "  medium           1.5GB   ~5GB RAM   Better accuracy, slower"
    echo "  distil-medium.en 1.5GB   ~5GB RAM   Fast + accurate (English)"
    echo "  distil-large-v3    2GB   ~5GB RAM   Near-best accuracy, fast"
    echo "  large-v3           3GB  ~10GB RAM   Best accuracy, slowest"
    echo "  distil-small.en  466MB   ~2GB RAM   Fast (English only)"
    echo ""
    echo "Usage: dictate-model <model>"
    echo "Takes effect next time you start dictation."
    exit 0
fi

for m in $MODELS; do
    if [ "$1" = "$m" ]; then
        echo "$1" > "$MODEL_FILE"
        echo "Model set to: $1"
        echo "Press Ctrl+Space twice (stop + start) to use the new model."
        exit 0
    fi
done

echo "Unknown model: $1"
echo "Available: $MODELS"
exit 1
MODELEOF

chmod +x "$BIN_DIR"/dictate-{start,stop,toggle,model,stream.py}

ok "Scripts installed"

# ─── Keyboard shortcut ──────────────────────────────────────────────────────

if [[ "$SKIP_SHORTCUT" == true ]]; then
    warn "Skipping keyboard shortcut setup (--skip-shortcut)"
else
    info "Setting up Ctrl+Space shortcut..."

    # Disable IBus Ctrl+Space (preserving other xkb options)
    CURRENT_XKB=$(gsettings get org.gnome.desktop.input-sources xkb-options 2>/dev/null || echo "@as []")
    gsettings set org.freedesktop.ibus.general.hotkey triggers "[]" 2>/dev/null || true

    # Find next free custom keybinding slot
    EXISTING=$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings 2>/dev/null || echo "@as []")

    # Check if we already have a dictation binding
    SLOT=""
    for i in $(seq 0 9); do
        NAME=$(gsettings get org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom${i}/ name 2>/dev/null || echo "''")
        if [[ "$NAME" == "'Dictation Toggle'" ]]; then
            SLOT=$i
            break
        fi
    done

    # If no existing dictation slot, find the first unused one
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

    # Add slot to the list if not already present
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
echo "  Press Ctrl+Space    Start listening"
echo "  Press Ctrl+Space    Stop and transcribe"
echo "  dictate-model       Change whisper model"
echo ""
echo "  Current model: $MODEL"
echo "  Display server: $SESSION_TYPE"
echo ""
if [[ "$SESSION_TYPE" == "wayland" ]] && ! groups | grep -q '\binput\b'; then
    warn "Log out and back in for Wayland input permissions to take effect."
    echo ""
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
