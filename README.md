# Voice Dictation for Ubuntu

Offline, real-time voice dictation for Ubuntu 24.04+. Press **Ctrl+Space** to start talking, press again to stop. Text appears phrase-by-phrase as you speak — works in any app.

Uses [faster-whisper](https://github.com/SYSTRAN/faster-whisper) (OpenAI Whisper) for transcription. No cloud, no API keys, no subscriptions.

- Works on both **X11** and **Wayland**
- **System tray icon** shows recording status (idle / recording / transcribing)
- **Model stays loaded in RAM** — no startup delay when you press the hotkey
- **Auto-starts on login** via systemd user service
- **Switch models from the tray menu** — no restart needed

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/sunapi386/voice-dictation/main/install.sh | bash
```

The installer auto-detects your RAM and picks the best model. Override with:

```bash
# Best accuracy (needs 10GB+ RAM)
curl -fsSL ... | bash -s -- --model large-v3

# Best speed/accuracy tradeoff (needs 5GB+ RAM)
curl -fsSL ... | bash -s -- --model distil-large-v3

# Lightweight (needs 2GB+ RAM)
curl -fsSL ... | bash -s -- --model small
```

## Usage

| Action | What happens |
|---|---|
| **Ctrl+Space** | Toggle recording on/off |
| **Tray icon** | Shows status: muted mic (idle), active mic (recording), medium mic (transcribing) |
| **Right-click tray icon** | Start/stop, switch model, quit |
| `dictate-model large-v3` | Switch model (reloads automatically) |
| `dictate-model` | Show current model and all options |

## How it works

```
┌─────────────────────────────────────────────────────┐
│  Daemon (always running, model loaded in RAM)       │
│                                                     │
│  Ctrl+Space → SIGUSR1 → toggle recording            │
│                                                     │
│  Recording → VAD detects pause → transcribe phrase  │
│           → type text at cursor → keep listening    │
│                                                     │
│  Tray icon updates: idle ↔ recording ↔ transcribing │
└─────────────────────────────────────────────────────┘
```

1. A daemon loads the Whisper model once and stays resident (~300-500MB RAM)
2. Pressing Ctrl+Space signals the daemon to start/stop recording — instant response
3. While recording, it detects natural pauses (VAD-based chunking) and transcribes each phrase
4. Text is typed at your cursor using `xdotool` (X11) or `ydotool` (Wayland)
5. The tray icon reflects current state

## Models

| Model | Size | RAM | Speed | Accuracy | Notes |
|---|---|---|---|---|---|
| `tiny` | 75 MB | ~1 GB | Fastest | Lower | |
| `base` | 142 MB | ~1 GB | Fast | Decent | |
| `small` | 466 MB | ~2 GB | Medium | Good | Default for 4-8GB |
| `distil-small.en` | 466 MB | ~2 GB | Fast | Good | English only |
| `medium` | 1.5 GB | ~5 GB | Slower | Great | |
| `distil-medium.en` | 1.5 GB | ~5 GB | Fast | Great | English only |
| `distil-large-v3` | 2 GB | ~5 GB | Fast | Near-best | **Recommended for 16GB+** |
| `large-v3` | 3 GB | ~10 GB | Slowest | Best | Max accuracy |

## Managing the daemon

```bash
# Check status
systemctl --user status voice-dictation

# Restart
systemctl --user restart voice-dictation

# Stop
systemctl --user stop voice-dictation

# Disable auto-start
systemctl --user disable voice-dictation
```

## Requirements

- Ubuntu 24.04 or later
- 2GB+ RAM (more = better model options)
- Working microphone
- GNOME desktop (for tray icon and keyboard shortcuts)

## Troubleshooting

**Ctrl+Space doesn't work**
- IBus may still be capturing it: `gsettings set org.freedesktop.ibus.general.hotkey triggers "[]"`
- Log out and back in

**No tray icon visible**
- Ensure the AppIndicator GNOME extension is enabled: `gnome-extensions enable appindicatorsupport@rgcjonas.gmail.com`

**No speech detected**
- Test your mic: `parecord --channels=1 /tmp/test.wav` then `aplay /tmp/test.wav`
- Speak louder or move closer to the microphone

**Transcription is slow**
- Switch to a smaller/faster model: `dictate-model distil-small.en`
- Or try: `dictate-model base`

**Wayland: ydotool not typing**
- Log out and back in after install (for `input` group)
- Check: `groups | grep input`

## Uninstall

```bash
systemctl --user stop voice-dictation
systemctl --user disable voice-dictation
rm -f ~/.config/systemd/user/voice-dictation.service
rm -rf ~/.local/share/voice-dictation
rm -f ~/.local/bin/dictate-{daemon.py,start,stop,toggle,model}
rm -f ~/.config/dictation-model
systemctl --user daemon-reload
```

## License

MIT
