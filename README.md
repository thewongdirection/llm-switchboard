# LLM Switchboard

A small local dashboard to pick a GGUF model, start it with llama.cpp, and open Claude Code against it.

## Run

Double-click `start.cmd` (needs PowerShell 7 - `pwsh`). It opens http://127.0.0.1:8787/.
Closing the console stops the dashboard; a running model keeps running and is re-detected next time.

## What it does

- **Hardware** - auto-detects GPU/VRAM (nvidia-smi), RAM and CPU. If VRAM can't be determined
  (non-NVIDIA GPU, no GPU...) it asks you to enter it; you can also override at any time via *Edit hardware*.
- **Installed models** - scans the Hugging Face cache and `~\models` for `.gguf` files and rates each one
  against your hardware (fits on GPU / GPU+RAM MoE / partial offload / too large).
- **Discover** - pulls trending and newly released GGUF models from Hugging Face, suggests the best quant for
  your hardware, flags new releases, and downloads into `~\models` (resumable).
  The list refreshes automatically when older than 12 h. Anonymous API access is rate-limited;
  set a `HF_TOKEN` environment variable to raise the limit.
- **Launch** - starts `llama-server` (context size, KV-cache compression, optional vision, extra args),
  then opens Claude Code in Windows Terminal in a project folder, pointed at the local model
  via `ANTHROPIC_BASE_URL` (llama-server speaks the Anthropic Messages API).

## Files

| Path | Purpose |
| --- | --- |
| `server.ps1` | HTTP server + API (binds to 127.0.0.1 only) |
| `lib.ps1` | Name parsing, quant grouping and hardware-fit heuristics |
| `ui/` | Static front end |
| `%LOCALAPPDATA%\llm-switchboard\` | Settings, logs, catalogue cache (kept out of the synced folder) |

## Notes

- Claude Code CLI must be installed separately (not found on this machine when this was built).
  Set its path under Settings if it isn't on PATH.
- Fit ratings are heuristics (file size vs. VRAM/RAM budget). llama-server's `--fit` handles the final
  layer placement when a model loads.
