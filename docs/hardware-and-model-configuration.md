<!--
This file is part of OffgridDev
hardware-and-model-configuration.md
Author(s): Gabriel Mongefranco
Created: 2026-08-06
Last Modified: 2026-08-06
Summary: Documents GPU/VRAM/disk requirements, the config/models.env model-enable workflow,
  and the family-version:size-task model naming scheme, referenced from the README's
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

# Hardware & Model Configuration

[← Back to README](../README.md)

## GPU

A **GPU (Graphics Processing Unit)** accelerates AI workloads. Without one, only very small models are usable.

OffgridDev only supports GPU acceleration on **NVIDIA GPUs**. It runs CPU-only automatically if no NVIDIA GPU
is detected — no configuration needed.

- **Windows / macOS:** Enable GPU support in Docker Desktop's settings, and make sure your NVIDIA driver is
  up to date. No extra install required.
- **Linux, native Docker Engine (not Docker Desktop):** Also install the
  [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html):
  ```
  sudo apt-get install -y nvidia-container-toolkit
  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker
  ```
  `offgriddev-start.sh` detects this automatically and warns (without failing) if the toolkit isn't configured.

## VRAM

**VRAM** is memory on the GPU. It determines which models you can run.

This project buckets models into four size tiers by parameter count (MoE models are bucketed by their
effective VRAM tier, not their active-parameter count — e.g. Qwen3 30B A3B is `xlarge` despite only 3B
active):

| Bucket | Params | VRAM | Practical Models |
|---|---:|-----:|------------------|
| `small` | ≤3B | ~2–4 GB | Lightweight coding, reasoning, and vision models |
| `medium` | 4–9B | ~4–8 GB | Best balance for most systems; most families' default tier |
| `large` | 10–34B | ~10 GB | Stronger reasoning/coding on mid-tier GPUs |
| `xlarge` | 35B+ (or MoE already treated as high-end, e.g. 30B total) | ~16–22 GB | Large coder / reasoning models, high-end GPUs only |

OffgridDev automatically detects VRAM and skips pulling any enabled model that doesn't fit it (see
[Model Configuration](#model-configuration) below) — it doesn't stop the whole run over one oversized
selection.

**Multiple NVIDIA GPUs:** their VRAM is summed for tier purposes (e.g. two 12GB cards qualify for the 24GB
tier), and `docker-compose.gpu.yml` exposes all of them to Ollama so it can split a large model's layers
across cards. Only NVIDIA GPUs count — an integrated Intel/AMD GPU alongside an NVIDIA card is ignored, not
summed in.

## Disk Space Requirements

- **Absolute minimum:** ~12 GB download, plus a fixed ~274 MB for `nomic-embed-text` (see
  [RAG embeddings](troubleshooting.md#rag-embeddings)) — pulled automatically every run regardless of which
  chat models you enable.
- **Recommended:** ~28 GB+ for the full set of default-enabled models (coding, reasoning, general, and
  vision)

## Model Configuration

Models are controlled in:

```
config/models.env
```

You enable which models to pull — enable as many as you like. The startup script does **not** pick a single
"best" model for you: every enabled model that fits your detected VRAM gets pulled, and you choose which one
to actually use per-session (VS Code's Continue dropdown, or the Open WebUI model switcher — see
[Web Interface](installation-and-usage.md#web-interface)).

Enabling a model your GPU can't cover doesn't stop the run: the startup script prints a `WARNING` and skips
just that one model, the same way it handles a failed pull (see [A model fails to pull, or doesn't fit your
VRAM](troubleshooting.md#a-model-fails-to-pull-or-doesnt-fit-your-vram)). The whole run only stops with an
error if **none** of your enabled models end up runnable.

Example:
```env
ENABLE_QWEN25_CODER_3B=0
ENABLE_QWEN25_CODER_7B=1
ENABLE_QWEN25_CODER_32B=0
```

Use `ENABLE_NAME=0` or `ENABLE_NAME=1` for each setting. Blank lines and `#` comments
are allowed. Separate an inline comment from the value with a space. Both Unix (LF)
and Windows (CRLF) line endings work.

Supported families:
- **Coding:** Qwen 2.5 Coder (0.5B–32B), Qwen3 Coder (30B, MoE), DeepSeek Coder, Devstral (24B)
- **Reasoning:** DeepSeek-R1, Qwen3, QwQ, Hermes 3 (Llama-based), Phi (`phi4-mini-reasoning`, `phi4-reasoning`)
- **General:** Gemma 3 / Gemma 4
- **Vision:** Moondream (small), Qwen2.5-VL (medium)

Three models/variants were evaluated and intentionally left out:

- **Kimi** — no official, locally-runnable Kimi build is currently published to Ollama's library. The last
  local release (`kimi-k2`) was retired; the newer `kimi-k3` is cloud-only and requires a paid Ollama
  subscription, which conflicts with this project's fully offline design.
- **Qwen3-Coder 480B** — Ollama's other official Qwen3-Coder size, at ~290 GB+ download, is far outside the
  disk/VRAM range any machine this project targets can realistically run.
- **DeepSeek-R1's Llama-distilled variants** — deferred this round in favor of curated defaults. Hermes 3
  (genuinely Llama 3.1/3.2-based, unlike the R1 distills) covers the Llama-family reasoning use case instead,
  and also mirrors a "Hermes-3-Llama-3.1-8B" entry already present in FieldStationAI's own model list.

## Model Naming

Every model this project pulls is aliased via `ollama cp` (zero extra disk — the alias shares the same
underlying blobs as the raw tag) to a consistent `family-version:size-task` tag immediately after it's
pulled, then the raw tag is removed (`ollama rm`, safe/refcounted — it only ever drops a tag, never a blob a
surviving alias still needs). Examples: `qwen25-coder:medium-coding`, `deepseek-r1:medium-reasoning`,
`moondream:small-vision`.

`size` is one of the four buckets above (`small` / `medium` / `large` / `xlarge`); `task` is `coding`,
`reasoning`, `vision`, or `general`. The one collision — Qwen 2.5 Coder's 0.5B/1.5B/3B all land in `small` —
is disambiguated with an exact-size token (`small-05b-coding`, `small-15b-coding`, `small-3b-coding`); every
other family's bucket has just one tag pulled by default, so it keeps the plain `bucket-task` form.

Because this renames Ollama's own tag (not just an Open WebUI-only alias), the friendly name shows up
everywhere that reads Ollama's `/api/tags` directly — Open WebUI's model selector, VS Code's Continue
extension (see [VS Code Integration](installation-and-usage.md#vs-code-integration)), and FieldStationAI —
without needing separate configuration in each tool. `nomic-embed-text` (the RAG embedding model) is the one
exception: it's not chat-selectable and `docker-compose.yml`'s `RAG_EMBEDDING_MODEL` env var references its
raw tag directly, so it's left unaliased.

---

Copyright © 2026 The Regents of the University of Michigan. Licensed under the GNU General Public License
v3.0 or later (software) and the GNU Free Documentation License v1.3 or later (this document). See
[LICENSE](../LICENSE) and [NOTICE](../NOTICE) for full terms.
