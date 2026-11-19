#!/usr/bin/env bash
# This file is part of OffgridDev
# offgriddev-start.sh
# Author(s): Gabriel Mongefranco
# Created: 2026-04-23
# Last Modified: 2026-08-06
# Summary: macOS/Linux launcher for the OffgridDev stack. Starts Docker if needed, detects
#   NVIDIA GPU VRAM to gate which models are safe to run, starts the Ollama/Open WebUI
#   containers, pulls every enabled model from config/models.env, forces legacy function
#   calling on models that don't support Ollama tool calls, and writes VS Code's Continue
#   extension config.
# Notes: See README file for documentation and full license information.
#
# Copyright © 2026 The Regents of the University of Michigan
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along
# with this program. If not, see <https://www.gnu.org/licenses/>.

set -e

# Suppresses the Docker CLI's post-command "What's next: Try Docker Debug..." tips, which
# otherwise print after every `docker exec`/`docker compose` call below and bury the
# script's own progress output under noise unrelated to this project.
export DOCKER_CLI_HINTS=false

# Print a clean message and stop on Ctrl+C / termination, wherever the script currently
# is - waiting on Docker, pulling images, pulling models - instead of a raw shell trace.
trap 'echo ""; echo "Interrupted - stopping."; exit 130' INT TERM

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$ROOT/config/models.env"

echo "=== OffgridDev ==="
echo "Root: $ROOT"

# Check Docker
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: Docker is not installed."
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker is installed but not running. Attempting to start it..."
  case "$(uname -s)" in
    Darwin)
      open -a Docker >/dev/null 2>&1 || true
      ;;
    Linux)
      # Docker Desktop for Linux ships a per-user systemd unit; native Docker Engine runs
      # as a system service. Try both, non-interactively (-n) so a missing sudo grant
      # never blocks on a password prompt - if neither is permitted, we just fall through
      # to polling and eventually the manual-start message below.
      systemctl --user start docker-desktop >/dev/null 2>&1 || true
      sudo -n systemctl start docker >/dev/null 2>&1 || true
      ;;
  esac

  echo -n "Waiting for Docker to start..."
  WAITED=0
  TIMEOUT=60
  INTERVAL=2
  until docker info >/dev/null 2>&1; do
    if [ "$WAITED" -ge "$TIMEOUT" ]; then
      echo ""
      echo "ERROR: Docker did not become ready within ${TIMEOUT}s."
      echo "Start Docker Desktop (or the docker service) manually, wait until it's ready, then re-run this script."
      exit 1
    fi
    sleep "$INTERVAL"
    WAITED=$((WAITED + INTERVAL))
    echo -n "."
  done
  echo " ready."
fi

# --------------------------------------------------
# Detect GPU VRAM (MB) via nvidia-smi
# --------------------------------------------------

VRAM_MB=0
GPU_COUNT=0

if command -v nvidia-smi >/dev/null 2>&1; then
  # nvidia-smi prints one line per NVIDIA GPU ("<name>, <VRAM MiB>"). Enumerate and sum
  # all of them: docker-compose.gpu.yml requests every NVIDIA GPU (count: all), and
  # Ollama can split a model's layers across multiple cards. This intentionally only
  # sees NVIDIA devices — integrated/other-vendor GPUs never appear here.
  while IFS=',' read -r gpu_name gpu_vram; do
    gpu_name="$(echo "$gpu_name" | sed 's/^ *//;s/ *$//')"
    gpu_vram="$(echo "$gpu_vram" | tr -d '[:space:]')"
    if [ -n "$gpu_vram" ]; then
      echo "Detected GPU: ${gpu_name} (${gpu_vram} MB)"
      VRAM_MB=$((VRAM_MB + gpu_vram))
      GPU_COUNT=$((GPU_COUNT + 1))
    fi
  done < <(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null)
else
  echo "WARNING: nvidia-smi not found. Treating as CPU-only system."
fi

if [ "$VRAM_MB" -gt 0 ]; then
  if [ "$GPU_COUNT" -gt 1 ]; then
    echo "Combined GPU VRAM across ${GPU_COUNT} NVIDIA GPUs: ${VRAM_MB} MB"
  else
    echo "Detected GPU VRAM: ${VRAM_MB} MB"
  fi
  if [ "$VRAM_MB" -lt 6000 ]; then
    echo "GPU tier: LOW VRAM (<= 6 GB)"
  elif [ "$VRAM_MB" -lt 12000 ]; then
    echo "GPU tier: MID VRAM (6-12 GB)"
  else
    echo "GPU tier: HIGH VRAM (12+ GB)"
  fi
else
  echo "GPU tier: NONE / CPU-only"
fi
echo ""

# --------------------------------------------------
# Native Linux Docker Engine: verify NVIDIA Container Toolkit.
# Docker Desktop (macOS, or Linux with the "desktop-linux" context) handles
# GPU passthrough itself and doesn't need the toolkit, so it's skipped there.
# --------------------------------------------------

GPU_USABLE=0
if [ "$VRAM_MB" -gt 0 ]; then
  GPU_USABLE=1
  if [ "$(uname -s)" = "Linux" ]; then
    DOCKER_CONTEXT="$(docker context show 2>/dev/null || echo "")"
    if [ "$DOCKER_CONTEXT" != "desktop-linux" ] && ! command -v nvidia-ctk >/dev/null 2>&1; then
      GPU_USABLE=0
      echo "WARNING: NVIDIA GPU detected but nvidia-container-toolkit is not installed."
      echo "  Install it, then re-run this script to enable GPU acceleration:"
      echo "    sudo apt-get install -y nvidia-container-toolkit"
      echo "    sudo nvidia-ctk runtime configure --runtime=docker"
      echo "    sudo systemctl restart docker"
      echo "  Continuing without GPU acceleration."
      echo ""
    fi
  fi
fi

# Load config
source "$CONFIG"

# --------------------------------------------------
# Enforce sane model selection by VRAM
# --------------------------------------------------
# This used to be a hard preflight `exit 1` here, before Docker even started - one
# oversized enabled model killed the whole run even if every other enabled model would've
# fit fine. VRAM fit is now checked per model at pull time instead (see pull()'s
# min_vram_mb arg below): an out-of-budget model is skipped with a WARNING and folded into
# the same CHAT_MODELS_REQUESTED/CHAT_MODELS_PULLED counters a failed pull already uses.
# The run only stops with an error if nothing enabled ends up runnable - see the check
# right after the pull list below.

# Create dirs
mkdir -p "$ROOT/data/ollama" "$ROOT/data/open-webui"

# --------------------------------------------------
# Start containers (GPU override attached only if a GPU was detected and usable)
# --------------------------------------------------

# Compose files are referenced by absolute path instead of `cd`-ing into docker/, so this
# script never leaves the caller's shell in a different directory than it started in.
COMPOSE_FILES=(-f "$ROOT/docker/docker-compose.yml")
if [ "$GPU_USABLE" -eq 1 ]; then
  COMPOSE_FILES+=(-f "$ROOT/docker/docker-compose.gpu.yml")
fi

docker compose "${COMPOSE_FILES[@]}" pull
docker compose "${COMPOSE_FILES[@]}" up -d

# --------------------------------------------------
# Verify the GPU override actually got used, not just requested
# --------------------------------------------------
# A GPU can be correctly detected and passed through to the container and Ollama will
# still silently fall back to CPU if the host's NVIDIA driver is older than the CUDA
# build this Ollama image needs - there's no error, just a much slower model that looks
# identical from the outside. Ollama logs this a few seconds into container startup
# (during its GPU discovery phase), so this polls for up to 10 seconds instead of taking
# one snapshot immediately - a single fixed sleep intermittently missed the log line
# entirely on slower first-boot startups, silently skipping this warning.
if [ "$GPU_USABLE" -eq 1 ]; then
  DRIVER_CHECK_ELAPSED=0
  DRIVER_CHECK_INTERVAL=1
  DRIVER_CHECK_TIMEOUT=10
  while [ "$DRIVER_CHECK_ELAPSED" -lt "$DRIVER_CHECK_TIMEOUT" ]; do
    sleep "$DRIVER_CHECK_INTERVAL"
    DRIVER_CHECK_ELAPSED=$((DRIVER_CHECK_ELAPSED + DRIVER_CHECK_INTERVAL))
    DRIVER_WARNING="$(docker logs offgriddev-ollama 2>&1 | grep "NVIDIA driver too old" || true)"
    if [ -n "$DRIVER_WARNING" ]; then
      GPU_DEVICE_NAME="$(echo "$DRIVER_WARNING" | sed -n 's/.*device="\([^"]*\)".*/\1/p')"
      REQUIRED_DRIVER="$(echo "$DRIVER_WARNING" | sed -n 's/.*required_driver="\([^"]*\)".*/\1/p')"
      echo ""
      echo "WARNING: GPU detected (${GPU_DEVICE_NAME}), but its NVIDIA driver is too old for this"
      echo "  Ollama build (needs driver ${REQUIRED_DRIVER}). Falling back to CPU - models will work"
      echo "  but run much slower. Update the driver, then re-run this script."
      echo ""
      break
    fi
  done
fi

# --------------------------------------------------
# Pull enabled models
# --------------------------------------------------
# A pull can fail for reasons the VRAM gate above never checks - a registry hiccup, a
# full disk, a tag that's been retired. `pull()` always returns 0 (reporting the failure
# itself as a warning instead of propagating it) so `set -e` never aborts the run over
# one bad model, and the loop keeps going through the rest of the list. Only the chat
# models (not the mandatory RAG embedding model below) count toward the "did anything
# usable come out of this" check right after the loop - if none of them pulled, there's
# nothing to chat with and the run stops there instead of handing the user a Web UI with
# an empty model list and no explanation.

CHAT_MODELS_REQUESTED=0
CHAT_MODELS_PULLED=0
PULLED_CHAT_MODEL_LABELS=()
FAILED_CHAT_MODEL_LABELS=()
# Parallel arrays: one entry per successfully pulled-and-aliased chat model, consumed
# below to generate Continue's config.yaml with explicit per-model entries.
PULLED_MODEL_NAMES=()
PULLED_MODEL_TAGS=()
PULLED_MODEL_ROLES=()

# Continue role sets by task, per this project's naming scheme (family-version:size-task):
# coding models keep the full role set Continue supports; reasoning models skip
# autocomplete/rerank (not meaningfully used in a reasoning workflow); Gemma (general) is
# chat/edit only; vision models are chat-only (no code-editing signal in an image).
CODING_ROLES="chat edit apply autocomplete rerank"
REASONING_ROLES="chat edit apply"
GENERAL_ROLES="chat edit"
VISION_ROLES="chat"

pull() {
  local model="$1"
  local label="${2:-$1}"
  local is_chat_model="${3:-1}"
  local alias="${4:-}"
  local roles="${5:-}"
  local min_vram_mb="${6:-0}"
  if [ "$is_chat_model" = "1" ]; then
    CHAT_MODELS_REQUESTED=$((CHAT_MODELS_REQUESTED + 1))
  fi
  # Per-model VRAM fit check, replacing the old preflight `exit 1`: an enabled model that
  # doesn't fit this GPU is skipped (not downloaded) and reported the same way a failed
  # pull is, rather than killing the whole run before it starts. min_vram_mb of 0 means "no
  # minimum" (small/medium models this project has never gated).
  if [ "$min_vram_mb" -gt 0 ] && [ "$VRAM_MB" -lt "$min_vram_mb" ]; then
    echo ""
    echo "WARNING: Skipping ${label} (${model}) - needs ~$((min_vram_mb / 1000)) GB VRAM, this GPU has ${VRAM_MB} MB. Not pulling it. Disable its ENABLE_* flag in models.env to silence this warning."
    echo ""
    if [ "$is_chat_model" = "1" ]; then
      FAILED_CHAT_MODEL_LABELS+=("$label")
    fi
    return 0
  fi
  if docker exec -it offgriddev-ollama ollama pull "$model"; then
    local final_tag="$model"
    if [ -n "$alias" ]; then
      # Renaming the Ollama tag itself (not an Open WebUI-only rename) is the only
      # mechanism visible to Continue's AUTODETECT scan and to FieldStationAI, both of
      # which read Ollama's /api/tags verbatim. `ollama cp` shares blobs (zero extra
      # disk); the `ollama rm` of the raw tag below is safe/refcounted - it only drops
      # the tag, never a blob the new alias still references.
      if ! docker exec -it offgriddev-ollama ollama cp "$model" "$alias"; then
        # `ollama cp` fails if the alias already exists - expected on a repeat run of
        # this script, not a real error. Confirm the alias is actually there before
        # treating this as success rather than assuming every cp failure is harmless.
        if ! docker exec -it offgriddev-ollama ollama show "$alias" >/dev/null 2>&1; then
          echo ""
          echo "WARNING: Failed to pull ${label} (${model}). Skipping it and continuing with the remaining models."
          echo "  ollama cp ${model} -> ${alias} failed and ${alias} does not already exist"
          echo ""
          if [ "$is_chat_model" = "1" ]; then
            FAILED_CHAT_MODEL_LABELS+=("$label")
          fi
          return 0
        fi
      fi
      docker exec -it offgriddev-ollama ollama rm "$model" >/dev/null 2>&1
      final_tag="$alias"
    fi
    if [ "$is_chat_model" = "1" ]; then
      CHAT_MODELS_PULLED=$((CHAT_MODELS_PULLED + 1))
      PULLED_CHAT_MODEL_LABELS+=("$label")
      if [ -n "$alias" ]; then
        PULLED_MODEL_NAMES+=("$label")
        PULLED_MODEL_TAGS+=("$final_tag")
        PULLED_MODEL_ROLES+=("$roles")
      fi
    fi
  else
    echo ""
    echo "WARNING: Failed to pull ${label} (${model}). Skipping it and continuing with the remaining models."
    echo ""
    if [ "$is_chat_model" = "1" ]; then
      FAILED_CHAT_MODEL_LABELS+=("$label")
    fi
  fi
  return 0
}

# Always pulled, regardless of which chat models are enabled: docker-compose.yml points
# Open WebUI's RAG embeddings at this model over Ollama (RAG_EMBEDDING_ENGINE=ollama)
# instead of the default Hugging Face download, so it needs to already exist here before
# Open WebUI's first request for it - not a user-selectable chat model, so it's not
# gated behind an ENABLE_ flag in models.env, and its failure doesn't count against the
# "at least one chat model must succeed" check below (RAG degrades; chat still works).
# Left unaliased: docker-compose.yml's RAG_EMBEDDING_MODEL env var references this raw tag
# directly, and it's never chat-selectable, so aliasing it has no user-facing benefit.
pull nomic-embed-text "Nomic Embed Text (RAG embedding model)" 0

[ "$ENABLE_QWEN25_CODER_0P5B" = "1" ] && pull qwen2.5-coder:0.5b "Qwen 2.5 Coder 0.5B" 1 "qwen25-coder:small-05b-coding" "$CODING_ROLES"
[ "$ENABLE_QWEN25_CODER_1P5B" = "1" ] && pull qwen2.5-coder:1.5b "Qwen 2.5 Coder 1.5B" 1 "qwen25-coder:small-15b-coding" "$CODING_ROLES"
[ "$ENABLE_QWEN25_CODER_3B" = "1" ] && pull qwen2.5-coder:3b "Qwen 2.5 Coder 3B" 1 "qwen25-coder:small-3b-coding" "$CODING_ROLES"
[ "$ENABLE_QWEN25_CODER_7B" = "1" ] && pull qwen2.5-coder:7b "Qwen 2.5 Coder 7B" 1 "qwen25-coder:medium-coding" "$CODING_ROLES" 6000
[ "$ENABLE_QWEN25_CODER_14B" = "1" ] && pull qwen2.5-coder:14b "Qwen 2.5 Coder 14B" 1 "qwen25-coder:large-coding" "$CODING_ROLES" 6000
[ "$ENABLE_QWEN25_CODER_32B" = "1" ] && pull qwen2.5-coder:32b "Qwen 2.5 Coder 32B" 1 "qwen25-coder:xlarge-coding" "$CODING_ROLES" 12000
[ "$ENABLE_QWEN3_CODER_30B" = "1" ] && pull qwen3-coder:30b "Qwen3 Coder 30B" 1 "qwen3-coder:xlarge-coding" "$CODING_ROLES" 12000
[ "$ENABLE_DEVSTRAL_24B" = "1" ] && pull devstral:24b "Devstral 24B" 1 "devstral:xlarge-coding" "$CODING_ROLES" 12000
[ "$ENABLE_DEEPSEEK_CODER_1P3B" = "1" ] && pull deepseek-coder:1.3b "DeepSeek Coder 1.3B" 1 "deepseek-coder:small-coding" "$CODING_ROLES"
[ "$ENABLE_DEEPSEEK_CODER_6P7B" = "1" ] && pull deepseek-coder:6.7b "DeepSeek Coder 6.7B" 1 "deepseek-coder:medium-coding" "$CODING_ROLES" 6000
[ "$ENABLE_DEEPSEEK_CODER_33B" = "1" ] && pull deepseek-coder:33b "DeepSeek Coder 33B" 1 "deepseek-coder:xlarge-coding" "$CODING_ROLES" 12000
[ "$ENABLE_GEMMA3_1B" = "1" ] && pull gemma3:1b "Gemma 3 1B" 1 "gemma3:small-general" "$GENERAL_ROLES"
[ "$ENABLE_GEMMA3_4B" = "1" ] && pull gemma3:4b "Gemma 3 4B" 1 "gemma3:medium-general" "$GENERAL_ROLES"
[ "$ENABLE_GEMMA4_E4B" = "1" ] && pull gemma4:e4b "Gemma 4 E4B" 1 "gemma4:medium-general" "$GENERAL_ROLES" 6000
[ "$ENABLE_GEMMA4_26B_A4B" = "1" ] && pull gemma4:26b-a4b "Gemma 4 26B A4B" 1 "gemma4:large-general" "$GENERAL_ROLES" 12000
[ "$ENABLE_DEEPSEEK_R1_7B" = "1" ] && pull deepseek-r1:7b "DeepSeek-R1 7B" 1 "deepseek-r1:medium-reasoning" "$REASONING_ROLES" 6000
[ "$ENABLE_DEEPSEEK_R1_14B" = "1" ] && pull deepseek-r1:14b "DeepSeek-R1 14B" 1 "deepseek-r1:large-reasoning" "$REASONING_ROLES" 6000
[ "$ENABLE_DEEPSEEK_R1_32B" = "1" ] && pull deepseek-r1:32b "DeepSeek-R1 32B" 1 "deepseek-r1:xlarge-reasoning" "$REASONING_ROLES" 12000
[ "$ENABLE_QWEN3_8B" = "1" ] && pull qwen3:8b "Qwen3 8B" 1 "qwen3:medium-reasoning" "$REASONING_ROLES" 6000
[ "$ENABLE_QWEN3_14B" = "1" ] && pull qwen3:14b "Qwen3 14B" 1 "qwen3:large-reasoning" "$REASONING_ROLES" 6000
[ "$ENABLE_QWEN3_30B_A3B" = "1" ] && pull qwen3:30b-a3b "Qwen3 30B A3B" 1 "qwen3:xlarge-reasoning" "$REASONING_ROLES" 12000
[ "$ENABLE_QWQ_32B" = "1" ] && pull qwq:32b "QwQ 32B" 1 "qwq:xlarge-reasoning" "$REASONING_ROLES" 12000
[ "$ENABLE_HERMES3_3B" = "1" ] && pull hermes3:3b "Hermes 3 3B" 1 "hermes3:small-reasoning" "$REASONING_ROLES"
[ "$ENABLE_HERMES3_8B" = "1" ] && pull hermes3:8b "Hermes 3 8B" 1 "hermes3:medium-reasoning" "$REASONING_ROLES" 6000
[ "$ENABLE_PHI4_MINI_REASONING_3P8B" = "1" ] && pull phi4-mini-reasoning:3.8b "Phi4 Mini Reasoning 3.8B" 1 "phi4:small-reasoning" "$REASONING_ROLES"
[ "$ENABLE_PHI4_REASONING_14B" = "1" ] && pull phi4-reasoning:14b "Phi4 Reasoning 14B" 1 "phi4:large-reasoning" "$REASONING_ROLES" 6000
[ "$ENABLE_MOONDREAM_1P8B" = "1" ] && pull moondream:1.8b "Moondream 1.8B" 1 "moondream:small-vision" "$VISION_ROLES"
[ "$ENABLE_QWEN25VL_7B" = "1" ] && pull qwen2.5vl:7b "Qwen 2.5 VL 7B" 1 "qwen25vl:medium-vision" "$VISION_ROLES" 6000

if [ "$CHAT_MODELS_REQUESTED" -gt 0 ] && [ "$CHAT_MODELS_PULLED" -eq 0 ]; then
  echo "ERROR: All ${CHAT_MODELS_REQUESTED} enabled chat model(s) failed to pull. See the warnings above for why, fix the underlying issue (network, disk space, registry), then re-run this script."
  exit 1
fi
if [ "$CHAT_MODELS_PULLED" -lt "$CHAT_MODELS_REQUESTED" ]; then
  echo "NOTE: ${CHAT_MODELS_PULLED} of ${CHAT_MODELS_REQUESTED} enabled chat models pulled successfully. Continuing with those."
  echo ""
fi

# Health check - polls the container's own Docker healthcheck instead of firing one curl
# right after `up -d`: Open WebUI's first-boot init (loading its embedding model, running
# DB migrations) routinely takes 15-30+ seconds, so a single immediate request almost
# always hit it mid-startup and failed the whole script even though the container was fine.
echo -n "Waiting for Web UI to finish starting..."
WEBUI_WAITED=0
WEBUI_TIMEOUT=90
WEBUI_INTERVAL=3
WEBUI_READY=0
while [ "$WEBUI_WAITED" -lt "$WEBUI_TIMEOUT" ]; do
  if [ "$(docker inspect --format '{{.State.Health.Status}}' offgriddev-webui 2>/dev/null)" = "healthy" ]; then
    WEBUI_READY=1
    break
  fi
  sleep "$WEBUI_INTERVAL"
  WEBUI_WAITED=$((WEBUI_WAITED + WEBUI_INTERVAL))
  echo -n "."
done

if [ "$WEBUI_READY" -eq 1 ]; then
  echo " ready."
else
  echo ""
  echo "ERROR: Web UI did not report healthy within ${WEBUI_TIMEOUT}s. Check its logs: docker logs offgriddev-webui"
  exit 1
fi

# --------------------------------------------------
# Configure non-tool-capable models to skip native function calling
# --------------------------------------------------
# DeepSeek Coder, Gemma 3, Phi (reasoning), and both vision models don't support Ollama's
# tool-calling capability at all, but Open WebUI defaults every model to attempt native
# tool calls whenever a builtin tool (Code Interpreter, Sub-agents, etc.) is enabled for
# the request - Ollama then rejects every message for these models with "does not support
# tools". Setting each one's Function Calling param to "legacy" here (equivalent to
# Workspace -> Models -> Edit -> Function Calling -> Legacy in the UI) makes Open WebUI
# fall back to prompt-based tool use instead, which these models do support. Non-fatal and
# silently skipped if WEBUI_AUTH has been turned back on, since the blank-password sign-in
# this relies on only works with auth off. IDs use the alias tags written above, since the
# raw tags stop existing once `ollama rm` runs.
NON_TOOL_MODEL_IDS=(deepseek-coder:small-coding deepseek-coder:medium-coding deepseek-coder:xlarge-coding gemma3:small-general gemma3:medium-general phi4:small-reasoning phi4:large-reasoning moondream:small-vision qwen25vl:medium-vision)
NON_TOOL_MODEL_NAMES=("DeepSeek Coder 1.3B" "DeepSeek Coder 6.7B" "DeepSeek Coder 33B" "Gemma 3 1B" "Gemma 3 4B" "Phi4 Mini Reasoning 3.8B" "Phi4 Reasoning 14B" "Moondream 1.8B" "Qwen 2.5 VL 7B")

SIGNIN_RESPONSE="$(curl -s -X POST http://localhost:3000/api/v1/auths/signin -H "Content-Type: application/json" -d '{"email":"admin@localhost","password":""}')"
WEBUI_TOKEN="$(echo "$SIGNIN_RESPONSE" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"

if [ -n "$WEBUI_TOKEN" ]; then
  for i in "${!NON_TOOL_MODEL_IDS[@]}"; do
    MODEL_ID="${NON_TOOL_MODEL_IDS[$i]}"
    MODEL_NAME="${NON_TOOL_MODEL_NAMES[$i]}"
    MODEL_PAYLOAD="{\"id\":\"${MODEL_ID}\",\"base_model_id\":\"${MODEL_ID}\",\"name\":\"${MODEL_NAME}\",\"meta\":{},\"params\":{\"function_calling\":\"legacy\"},\"is_active\":true}"
    CREATE_HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST http://localhost:3000/api/v1/models/create \
      -H "Content-Type: application/json" -H "Authorization: Bearer $WEBUI_TOKEN" -d "$MODEL_PAYLOAD")"
    if [ "$CREATE_HTTP_CODE" != "200" ]; then
      # Most likely this model ID already exists (e.g. re-running this script, or a manual
      # edit in the UI left it misconfigured) - fall back to updating it in place so the
      # fix still applies. Failure here is non-fatal either way.
      curl -s -o /dev/null -X POST http://localhost:3000/api/v1/models/model/update \
        -H "Content-Type: application/json" -H "Authorization: Bearer $WEBUI_TOKEN" -d "$MODEL_PAYLOAD"
    fi
  done
else
  echo "NOTE: Could not auto-configure DeepSeek Coder / Gemma 3 / Phi / Moondream / Qwen 2.5 VL for tool compatibility (Open WebUI auth may be enabled). See README's Troubleshooting section to do it manually."
fi

# --------------------------------------------------
# Write Continue (VS Code) config
# --------------------------------------------------
# One explicit named entry per model that actually pulled-and-aliased this run (friendly
# name, alias tag, and its task-appropriate role set), plus AUTODETECT kept as a trailing
# catch-all - that still picks up anything pulled out-of-band via Open WebUI's manual-pull
# UI, which never goes through the alias step above.
CONTINUE_DIR="$HOME/.continue"
CONTINUE_CONFIG="$CONTINUE_DIR/config.yaml"
mkdir -p "$CONTINUE_DIR"

{
  echo "name: OffgridDev"
  echo "version: 0.0.1"
  echo "schema: v1"
  echo "models:"
  for i in "${!PULLED_MODEL_NAMES[@]}"; do
    echo "  - name: ${PULLED_MODEL_NAMES[$i]}"
    echo "    provider: ollama"
    echo "    model: ${PULLED_MODEL_TAGS[$i]}"
    echo "    apiBase: http://localhost:11434"
    echo "    roles:"
    for ROLE in ${PULLED_MODEL_ROLES[$i]}; do
      echo "      - ${ROLE}"
    done
  done
  echo "  - name: OffgridDev Autodetect"
  echo "    provider: ollama"
  echo "    model: AUTODETECT"
  echo "    apiBase: http://localhost:11434"
  echo "    roles:"
  for ROLE in chat edit apply rerank autocomplete; do
    echo "      - ${ROLE}"
  done
} > "$CONTINUE_CONFIG"

echo "Continue config written to:"
echo "$CONTINUE_CONFIG"
echo ""

echo "OffgridDev READY"
echo "Web UI: http://localhost:3000"
echo "API   : http://localhost:11434"
echo ""
# Reflects what actually pulled, not just what was enabled in models.env - a model that
# failed above (see warnings) is not silently reported as available here.
echo "Active models:"
if [ "${#PULLED_CHAT_MODEL_LABELS[@]}" -eq 0 ]; then
  echo "  (none)"
else
  for MODEL_LABEL in "${PULLED_CHAT_MODEL_LABELS[@]}"; do
    echo "  - ${MODEL_LABEL}"
  done
fi
if [ "${#FAILED_CHAT_MODEL_LABELS[@]}" -gt 0 ]; then
  echo ""
  echo "Failed to pull (not available in Web UI or Continue - see warnings above):"
  for MODEL_LABEL in "${FAILED_CHAT_MODEL_LABELS[@]}"; do
    echo "  - ${MODEL_LABEL}"
  done
fi
echo ""
echo "#InfiniteTokens"
echo ""