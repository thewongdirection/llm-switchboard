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

- **Storage** - lists where everything lives (model folders and files, download folder, llama-server,
  Claude CLI, dashboard data/logs, projects folder) with sizes, drive free space, and Copy / Open buttons.
- **Cloud restore** - *Restore: launch with cloud Claude* opens a Claude Code session with the local-model
  settings cleared (optionally stopping the local model). **Force stop** kills any llama-server, including
  ones not started from the dashboard.

- **256k context by default** - the dashboard reads each model's real architecture from its GGUF header
  (layers, KV heads, sliding-window / hybrid layers) to estimate KV-cache memory, and defaults to the largest
  window your VRAM + RAM can hold, capped at the model's trained length. It compresses the KV cache to 8-bit
  automatically when full precision wouldn't stay on the GPU, and labels slow cases (a dense model that spills
  into RAM). Override both under *Context window* / *KV cache*.
- **Template patch** - some models (e.g. Qwen3.x) reject the mid-conversation system message Claude Code sends
  (`System message must be at the beginning`). The dashboard detects this and starts such models with a patched
  chat template (`--chat-template-file`); the original model file is never modified.

## Testing

`tests\verify-claude.ps1` checks, end to end, that the model started from the dashboard works through Claude Code:
the server runs the selected file/context, the dashboard-launched terminal is correct, and headless Claude Code
handles replies, reasoning, code generation (the generated code is then run), Read/Write/Edit/Bash tools,
multi-turn memory, long-context recall and a two-file program. Start a model in the dashboard first, then:

```
pwsh -File tests\verify-claude.ps1            # all tests (slow for big models)
pwsh -File tests\verify-claude.ps1 -Quick     # skip the long ones
pwsh -File tests\verify-claude.ps1 -Only T4,T10
```

## Files

| Path | Purpose |
| --- | --- |
| `server.ps1` | HTTP server + API (binds to 127.0.0.1 only) |
| `lib.ps1` | Name parsing, quant grouping and hardware-fit heuristics |
| `gguf.ps1` | GGUF header reader, KV-cache / context planner, chat-template patching |
| `tests/` | End-to-end Claude Code verification suite |
| `ui/` | Static front end |
| `%LOCALAPPDATA%\llm-switchboard\` | Settings, logs, catalogue cache (kept out of the synced folder) |

## Notes

- Claude Code CLI must be installed separately (not found on this machine when this was built).
  Set its path under Settings if it isn't on PATH.
- Fit ratings are heuristics (file size vs. VRAM/RAM budget). llama-server's `--fit` handles the final
  layer placement when a model loads.
