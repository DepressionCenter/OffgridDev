<!--
This file is part of OffgridDev
troubleshooting.md
Author(s): Gabriel Mongefranco
Created: 2026-08-06
Last Modified: 2026-11-02
Summary: Documents known failure modes and their fixes for the OffgridDev stack, including
  stale model aliases and chat history migration, referenced from the README's
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

# Troubleshooting

[← Back to README](../README.md)

## Viewing container logs
The startup scripts run everything inside Docker, so failures don't print to your terminal. To see what a
container is actually doing:
```
docker logs offgriddev-webui        # Web UI - one-shot dump
docker logs -f offgriddev-webui     # Web UI - live tail, Ctrl+C to stop
docker logs offgriddev-ollama       # Ollama, same options
```
To check whether a container is currently healthy:
```
docker inspect --format "{{.State.Health.Status}}" offgriddev-webui
```

## A model fails to pull, or doesn't fit your VRAM
If a single enabled model can't be pulled — a registry hiccup, a full disk, a tag that's been retired, or the
model is simply bigger than your detected GPU VRAM can cover — the startup scripts print a `WARNING:` for
that model and move on to the rest of the list rather than aborting the whole run. A VRAM-too-small skip
looks like:
```
WARNING: Skipping DeepSeek-R1 14B (deepseek-r1:14b) - needs ~10 GB VRAM, this GPU has 6144 MB. Not pulling
it. Disable its ENABLE_* flag in models.env to silence this warning.
```
The final "Active models" list (printed once the script finishes) only shows models that actually pulled;
anything that failed or was skipped for VRAM is called out separately underneath it, e.g.:
```
Active models:
  - Qwen 2.5 Coder 7B

Failed to pull (not available in Web UI or Continue - see warnings above):
  - Gemma 3 4B
  - DeepSeek-R1 14B
```
The run only stops outright with an `ERROR:` if **every** enabled chat model failed to pull or didn't fit —
at that point there's nothing to chat with, so continuing wouldn't leave you with a usable stack. Scroll back
through the warnings to see why each one happened (usually network, disk space, an outdated tag, or VRAM),
fix what you can, and re-run the startup script — it's safe to run repeatedly.

## Stale model aliases after disabling a model
Disabling a model in `config/models.env` (setting its `ENABLE_*` flag back to `0`) only stops the startup
scripts from pulling it on the *next* run — it does **not** remove the alias tag (e.g.
`qwen25-coder:medium-coding`) a previous run already created in Ollama. The model stays fully usable in Open
WebUI and Continue until you remove it yourself:
```
docker exec offgriddev-ollama ollama rm qwen25-coder:medium-coding
```
This is safe to run any time — it only removes that one tag; blobs shared with any other alias you still
have pulled are untouched. Run `docker exec offgriddev-ollama ollama list` first if you're not sure of the
exact alias tag to remove.

## Old chat history referencing a raw model tag
Pre-existing Open WebUI chat history created before this project switched to aliased model names may still
reference the old raw tag (e.g. `deepseek-coder:6.7b` instead of `deepseek-coder:medium-coding`). Those
messages continue to display normally — Open WebUI stores the model ID as plain text alongside each message
— but **"regenerate" on one of them will fail** once the raw tag no longer exists in Ollama (see
[Model Naming](hardware-and-model-configuration.md#model-naming) for why the raw tag goes away). Start a new
chat with the model's current alias name instead; there's no supported way to retarget old messages at the
new tag.

## Tools errors on DeepSeek Coder / Gemma 3
```
registry.ollama.ai/library/deepseek-coder:medium-coding does not support tools
```
This is Ollama's own error, not Open WebUI's — it means a request reached Ollama with a `tools` definition
attached, and the model's template has no way to use one. DeepSeek Coder, Gemma 3, Phi (`phi4-mini-reasoning`,
`phi4-reasoning`), and both vision models (Moondream, Qwen2.5-VL) never support Ollama tool calling, at any
size (confirmed against each model's capability tags on ollama.com/library) — this isn't specific to
Sub-agents. Open WebUI defaults every model to attempt **native** (tool-based) function calling the moment
*any* builtin tool is enabled for a request, and **Code Interpreter is enabled by default** in stock Open
WebUI, independent of the [Sub-agents](installation-and-usage.md#sub-agents) setting.

The startup scripts handle this automatically: after Web UI comes up, they configure all of the models above
(all sizes used by this project) with Function Calling forced to **Legacy** via Open WebUI's Models API — the
one setting that, per Open WebUI's own source, unconditionally skips native tool injection for a model,
regardless of which builtin tool triggered it. This step is non-fatal and silently skipped if you've turned
`WEBUI_AUTH` back on (it signs in as the default admin using a blank password, which only works with auth
disabled).

**If you still see this error after re-running the startup script:** check it manually — open
**Workspace → Models**, edit the model in question, and confirm **Function Calling** reads **Legacy** (not
*Default* — despite the name, *Default* still triggers native tool calls if unset in this version). If it's
not applying, or you hit this on a model not listed above, that's a real bug worth reporting with the exact
request shown in your browser's Network tab (DevTools → Network → the failing `/api/chat/completions` call)
for the `tools` field it's sending — that's the detail needed to track down which feature is attaching it.

## Web UI is slow to start, returns a 500, or restarts itself
The startup scripts wait up to 90 seconds for Open WebUI's own Docker healthcheck to go green before
declaring success or failure — normal startup (loading its embedding model, running DB migrations) is
usually well under 30 seconds, but a fresh/first boot or a slow disk can take longer. If it still isn't
healthy after 90 seconds, check `docker logs offgriddev-webui` (see above) for the actual error rather than
guessing. See [RAG embeddings](#rag-embeddings) below for the Hugging Face network dependency this used to
have and no longer does for RAG specifically.

## RAG embeddings
Open WebUI needs an embedding model to power document/"chat with your files" search. By default it fetches
one (`sentence-transformers/all-MiniLM-L6-v2`) from Hugging Face. This project instead points it at Ollama —
`docker-compose.yml` sets `RAG_EMBEDDING_ENGINE=ollama` and `RAG_EMBEDDING_MODEL=nomic-embed-text`, and the
startup scripts always pull `nomic-embed-text` (~274 MB) into Ollama, matching Open WebUI's own documented
recommendation for air-gapped deployments (`docs.openwebui.com/troubleshooting/rag/`). Actual RAG queries
route through `ollama:11434`, the same connection already used for chat — no Hugging Face involved.

**Caveat, found by testing this directly against a real container, not assumed:** in the current image
(v0.11.0), Open WebUI still loads a small local copy of the Hugging Face embedding model at every boot
regardless of this setting — a known quirk, not something these env vars can fully suppress. This is
harmless once it's cached: `HF_HUB_OFFLINE=1` (still set, belt-and-suspenders) forces it to load from the
local cache with zero network calls, confirmed by grepping a full startup log for any `huggingface.co`
reference and finding none. **What this means in practice:** a machine that has already booted this stack
once needs no internet, ever, for Open WebUI to start — verified. A **completely fresh clone on a brand-new
machine** still needs one working internet connection on its very first boot, to let Open WebUI fetch and
cache that small local copy — there's no way to avoid this without committing ~90 MB of binary model weights
into this git repo, which conflicts with `.gitignore`'s `data/` policy (runtime state, not source) and adds
permanent repo bloat. If you'd rather have byte-for-byte zero-network-ever-including-first-clone at the cost
of that repo size, that's a deliberate tradeoff to make on purpose — ask before assuming it's wanted.

## Models respond correctly but are painfully slow / "is it even using my GPU?"
A GPU can be correctly detected on your machine and passed through to the container and Ollama will *still*
silently fall back to CPU — with no error — if your NVIDIA driver is older than the CUDA build this Ollama
image needs. The startup scripts now check for this automatically after starting containers and print a
warning naming the required driver version if it happens; you can also check by hand at any time:
```
docker inspect --format "{{.State.Health.Status}} " offgriddev-ollama
docker exec offgriddev-ollama ollama ps
```
`ollama ps` only lists currently-loaded models, so send a chat message first — ideally run the command while
the model is still actively generating a reply, since the container may unload the model (dropping it from
this list entirely) shortly after the reply finishes, depending on its keep-alive setting. The `PROCESSOR`
column reads `100% GPU` when a model fits entirely in VRAM, `100% CPU` when the driver/GPU isn't being used
at all, or a split like `64%/36% CPU/GPU` when the model is larger than available VRAM and Ollama offloaded
only part of it — e.g.:
```
NAME                            ID              SIZE      PROCESSOR          CONTEXT    UNTIL
deepseek-coder:medium-coding    ce298d984115    6.1 GB    64%/36% CPU/GPU    4096       4 minutes from now
```
A split like this is expected, not a bug, whenever a model's loaded size (weights + KV cache for the active
context) exceeds your GPU's VRAM — see [Hardware & Model Configuration](hardware-and-model-configuration.md)
for which models fit which VRAM tiers. If it says **100% CPU** and you have an NVIDIA GPU, that's the driver
issue above: update your driver from [nvidia.com/drivers](https://www.nvidia.com/drivers) (search your exact
GPU model), then re-run the startup script. On a University-managed laptop, driver updates may require your
department's IT support if you don't have local admin rights.

## Resetting a stuck container
Run the matching pair below from the repository root. Use the NVIDIA example if your stack was started
with NVIDIA GPU support; restarting with only the base file removes the GPU request and can make Ollama
fall back to CPU.

**CPU-only:** no NVIDIA tools or GPU override required.

```
docker compose -f docker/docker-compose.yml down
docker compose -f docker/docker-compose.yml up -d
```

**NVIDIA GPU:** requires the same working NVIDIA container support used for the original startup. Keep
the base file first and the GPU override second in both commands.

```
docker compose -f docker/docker-compose.yml -f docker/docker-compose.gpu.yml down
docker compose -f docker/docker-compose.yml -f docker/docker-compose.gpu.yml up -d
```

Both examples recreate the containers while preserving models in `data/ollama` and chat history and
uploads in `data/open-webui`. These directories are bind-mounted from the repository's `data/` directory;
do not delete them when resetting containers.

For automatic hardware selection, use the normal [stop and start scripts](installation-and-usage.md#starting-offgriddev)
instead. The startup scripts explicitly request container image pulls and model pulls (including the RAG
embedding model), so they may need internet access even when restarting an existing installation.

For an offline container reset, use the applicable manual example above with images, models, and required
caches already available locally. Add `--pull never` to its `up -d` command to prevent Compose from pulling
images; a missing image will fail instead. These manual commands do not run the launcher's model pulls.
See [RAG embeddings](#rag-embeddings) for the first-boot cache requirements.

---

Copyright © 2026 The Regents of the University of Michigan. Licensed under the GNU General Public License
v3.0 or later (software) and the GNU Free Documentation License v1.3 or later (this document). See
[LICENSE](../LICENSE) and [NOTICE](../NOTICE) for full terms.
