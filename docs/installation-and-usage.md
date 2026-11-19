<!--
This file is part of OffgridDev
installation-and-usage.md
Author(s): Gabriel Mongefranco
Created: 2026-08-06
Last Modified: 2026-08-06
Summary: Documents installation, starting/stopping the stack, the Open WebUI web
  interface, and VS Code Continue integration, referenced from the README's
  Documentation section.
Notes: See README file for documentation and full license information.

Copyright © 2026 The Regents of the University of Michigan

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.
You should have received a copy of the GNU General Public License along
with this program. If not, see <https://www.gnu.org/licenses/>.

-->
![Eisenberg Family Depression Center](https://code.depressioncenter.org/images/EFDCLogo_375w.png "depressioncenter.org")

# Installation & Usage

[← Back to README](../README.md)

## Installation

### Prerequisites
- Docker Desktop (must be running)
  https://www.docker.com/products/docker-desktop

### Windows
1. Download repo as ZIP
2. Extract to:
```
C:\OffgridDev
```

### macOS / Linux
```
~/offgriddev
```

## Starting OffgridDev

> Docker Desktop **must already be running**.

### Windows
```
powershell -ExecutionPolicy Bypass -File scripts\offgriddev-start.ps1
```
(PowerShell's default execution policy blocks double-clicking `.ps1` files; the flag above runs this script
without changing your system-wide policy.)

### macOS / Linux
```
./scripts/offgriddev-start.sh
```

## Stopping

### Windows
```
powershell -ExecutionPolicy Bypass -File scripts\offgriddev-stop.ps1
```

### macOS / Linux
```
./scripts/offgriddev-stop.sh
```

## Web Interface

Open:

http://localhost:3000

Use it to chat, test prompts, and debug models.

### Login
There isn't one. `docker/docker-compose.yml` sets `WEBUI_AUTH=False`, so Open WebUI skips its
sign-in screen and runs as a single implicit local user — matching this project's
offline, single-developer-machine design.

Note: This is only safe because port 3000 is published to `localhost` by default. If you
ever change `docker-compose.yml` to expose that port on your network (or forward it
through a tunnel), remove `WEBUI_AUTH=False` first — anyone who can reach the port would
otherwise have unauthenticated access to your chats, uploaded files, and any model the
container can pull.

### Switching models
The chat model selector (top of the page) lists whatever models are currently pulled into Ollama — by
default, that's exactly the set you enabled in `config/models.env`, since VRAM gating already kept it to
models this machine can run. Switching is instant; nothing downloads at that point.

Models pulled through the startup scripts show their friendly alias name (e.g. `deepseek-r1:medium-reasoning`
instead of `deepseek-r1:7b`) — see [Model Naming](hardware-and-model-configuration.md#model-naming). Models
pulled manually via the Admin Panel (below) still show their raw Ollama tag, since they never go through the
alias step.

### Pulling additional models from the browser
You don't need the CLI to add a model later. Go to **Settings → Admin Panel → Settings → Connections →
Ollama**, enter a model tag (e.g. `qwen2.5-coder:14b`), and pull it from there — it appears in the chat
selector once the download finishes.

**This bypasses the VRAM gate.** `models.env` and the startup scripts are the only place VRAM checking
happens; pulling a model directly through Open WebUI does not check whether it fits your GPU. Stick to sizes
your [VRAM tier](hardware-and-model-configuration.md#vram) supports, or the model will fail to load or run
painfully slowly on CPU.

For a cleaner, curated switcher (friendly names instead of raw tags, or hiding the raw model list from other
users of this instance), see Open WebUI's **Workspace → Models** feature — it builds named presets on top of
already-pulled base models but doesn't change the pull/VRAM behavior above.

### Sub-agents
Open WebUI has a "Sub-agents" feature (a chat model hands off a focused piece of a task to a second
background model call, then uses the result to keep going) — **off by default in this project**, matching
Open WebUI's own default. It stays off deliberately: turning it on globally (`ENABLE_SUBAGENTS=True`)
auto-enables the Sub-agents Builtin Tool for *every* model, and several of this project's model families —
DeepSeek Coder, Gemma 3, Phi (reasoning), and both vision models — don't support Ollama tool calling at all.
Every request to one of those models then fails outright with `does not support tools`, and there's no
compose-level way to exclude just those models from the global flag. (See
[Tools errors on DeepSeek Coder / Gemma 3](troubleshooting.md#tools-errors-on-deepseek-coder--gemma-3) for
why this same failure can happen even with Sub-agents off, and how it's handled.)

If you only ever use Qwen 2.5 Coder, Qwen 3 Coder, or Devstral (all three support Ollama's tool-calling
capability) and want sub-agents, add this to the `webui` service's `environment` in `docker-compose.yml`,
then run `docker compose -f docker/docker-compose.yml -f docker/docker-compose.gpu.yml up -d`:
```yaml
- ENABLE_SUBAGENTS=True
- SUBAGENTS_MAX_CONCURRENT=2   # upstream default is 20 - this stack pins OLLAMA_NUM_PARALLEL=1, so
                               # Ollama only ever runs one completion at a time regardless; extra
                               # slots just queue rather than parallelize on a single local GPU.
- SUBAGENTS_MAX_ITERATIONS=10 # upstream default is 30 - bounds a model looping on tool calls instead
                               # of finishing a sub-task, each iteration being a full extra completion.
```
Then, per model, go to **Workspace → Models → (edit) → Builtin Tools → Sub-agents** and set **Function
Calling** to **Native**. DeepSeek Coder and Gemma 3 already have Function Calling forced to **Legacy** by the
startup scripts, so they're unaffected either way.

## VS Code Integration

### Requirements
- VS Code
- Continue extension
  https://marketplace.visualstudio.com/items?itemName=Continue.continue

### Automatic Setup

On the first run without a Continue configuration, the startup script creates:
```
C:\Users\<you>\.continue\config.yaml     (Windows)
~/.continue/config.yaml                  (macOS/Linux)
```

If `config.yaml` exists, the launcher preserves it and writes
`offgriddev.config.yaml` in the same directory. To use the generated models,
copy the model entries you want into the `models:` section of your existing
`config.yaml`. Subsequent runs refresh `offgriddev.config.yaml`.

One named entry is generated per model that pulled successfully this run — friendly name, alias tag, and a
task-appropriate role set (coding models get the full `chat`/`edit`/`apply`/`autocomplete`/`rerank` set;
reasoning models get `chat`/`edit`/`apply`; Gemma (general) gets `chat`/`edit`; vision models get `chat`
only) — plus a trailing **OffgridDev Autodetect** entry that still picks up anything pulled out-of-band
through Open WebUI's manual-pull UI (see [Pulling additional models from the
browser](#pulling-additional-models-from-the-browser)), since those never go through the alias step.

Then:
1. Restart VS Code
2. Continue → Select Model → pick the named model you want (e.g. **Qwen 2.5 Coder 7B**), or
   **OffgridDev Autodetect** to see everything currently pulled into Ollama

---

Copyright © 2026 The Regents of the University of Michigan. Licensed under the GNU General Public License
v3.0 or later (software) and the GNU Free Documentation License v1.3 or later (this document). See
[LICENSE](../LICENSE) and [NOTICE](../NOTICE) for full terms.
