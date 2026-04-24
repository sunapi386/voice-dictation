# Voice Dictation for Ubuntu

Offline, real-time voice dictation for Ubuntu 24.04+. Press **Ctrl+Space** to start talking, press again to stop. Text appears phrase-by-phrase as you speak — works in any app.

Uses [faster-whisper](https://github.com/SYSTRAN/faster-whisper) (OpenAI Whisper) for transcription. No cloud, no API keys, no subscriptions.

Works on both **X11** and **Wayland**.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/sunapi386/voice-dictation/main/install.sh | bash
```

The installer auto-detects your RAM and picks a model. Override with:

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
| **Ctrl+Space** | Start listening — text appears as you speak |
| **Ctrl+Space** again | Stop dictation |
| `dictate-model` | Show/change the Whisper model |
| `dictate-model distil-large-v3` | Switch model (takes effect on next start) |

## Models

| Model | Size | RAM | Speed | Accuracy |
|---|---|---|---|---|
| `tiny` | 75 MB | ~1 GB | Fastest | Lower |
| `base` | 142 MB | ~1 GB | Fast | Decent |
| `small` | 466 MB | ~2 GB | Medium | Good |
| `medium` | 1.5 GB | ~5 GB | Slower | Great |
| `distil-medium.en` | 1.5 GB | ~5 GB | Fast | Great (English) |
| `distil-small.en` | 466 MB | ~2 GB | Fast | Good (English) |
| `distil-large-v3` | 2 GB | ~5 GB | Fast | Near-best |
| `large-v3` | 3 GB | ~10 GB | Slowest | Best |

**Recommendation:** `distil-large-v3` if you have 6GB+ RAM. It's nearly as accurate as `large-v3` but much faster.

## How it works

1. Records audio from your microphone
2. Detects natural pauses in speech (VAD-based chunking)
3. Transcribes each phrase with Whisper
4. Types the text at your cursor using `xdotool` (X11) or `ydotool` (Wayland)

All processing happens locally on your CPU. First start after boot takes a few seconds to load the model; subsequent starts are faster.

## Requirements

- Ubuntu 24.04 or later
- 2GB+ RAM (more = better model options)
- Working microphone

## Troubleshooting

**Ctrl+Space doesn't work**
- IBus may still be capturing it. Run: `gsettings set org.freedesktop.ibus.general.hotkey triggers "[]"`
- Log out and back in

**No speech detected**
- Test your mic: `parecord --channels=1 /tmp/test.wav` then `aplay /tmp/test.wav`
- Speak louder or move closer to the microphone
- Try lowering the threshold: edit `~/.local/bin/dictate-start` and add `--threshold 0.008`

**Transcription is slow**
- First run loads the model (~2-5s). Subsequent phrases are faster.
- Try a smaller model: `dictate-model small` or `dictate-model base`

**Wayland: ydotool not typing**
- Make sure you logged out and back in after install (for `input` group)
- Check: `groups | grep input`

## Uninstall

```bash
rm -rf ~/.local/share/voice-dictation
rm -f ~/.local/bin/dictate-{start,stop,toggle,model,stream.py}
rm -f ~/.config/dictation-model
```

## License

MIT
