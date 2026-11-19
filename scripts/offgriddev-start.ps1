# This file is part of OffgridDev
# offgriddev-start.ps1
# Author(s): Gabriel Mongefranco
# Created: 2026-04-23
# Last Modified: 2026-08-06
# Summary: Windows launcher for the OffgridDev stack. Starts Docker Desktop if needed,
#   detects NVIDIA GPU VRAM to gate which models are safe to run, starts the Ollama/Open
#   WebUI containers, pulls every enabled model from config/models.env, forces legacy
#   function calling on models that don't support Ollama tool calls, and writes VS Code's
#   Continue extension config.
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

$ErrorActionPreference = "Stop"

# Suppresses the Docker CLI's post-command "What's next: Try Docker Debug..." tips, which
# otherwise print after every `docker exec`/`docker compose` call below and bury the
# script's own progress output under noise unrelated to this project.
$env:DOCKER_CLI_HINTS = "false"

$Root = Resolve-Path "$PSScriptRoot\.."
$Config = Join-Path $Root "config\models.env"

Write-Host "=== OffgridDev ==="
Write-Host "Root: $Root"
Write-Host ""

# Tracks how the script left the try block below, so the `finally` handler can tell a
# normal finish or a deliberate Fail() apart from a Ctrl+C / unexpected interruption and
# only print an extra "Interrupted" message for the latter.
$script:ScriptCompletedNormally = $false
$script:ExpectedExit = $false

function Fail($msg) {
    Write-Host ""
    Write-Error $msg
    Write-Host ""
    Read-Host "Press Enter to exit"
    $script:ExpectedExit = $true
    exit 1
}

# Everything else runs inside this try so Ctrl+C (or any unhandled error) at any point -
# waiting on Docker, pulling images, pulling models - unwinds cleanly through `finally`
# instead of leaving a raw stack trace.
try {

# --------------------------------------------------
# Docker detection, with auto-launch if installed but not running
# --------------------------------------------------

function Test-Docker($cmd) {
    try {
        # Redirect every stream: a not-running daemon makes `docker info` print its own
        # noisy error, and we want our own clean message instead, not raw CLI output.
        & $cmd info *> $null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Find-DockerDesktopExe {
    $Candidates = @(
        "$env:LOCALAPPDATA\Programs\Docker\Docker\Docker Desktop.exe",
        "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    )
    foreach ($Candidate in $Candidates) {
        if (Test-Path $Candidate) {
            return $Candidate
        }
    }
    return $null
}

function Wait-ForDocker($cmd, [int]$TimeoutSeconds) {
    $Elapsed = 0
    $Interval = 2
    Write-Host "Waiting for Docker Desktop to start..." -NoNewline
    while ($Elapsed -lt $TimeoutSeconds) {
        Start-Sleep -Seconds $Interval
        $Elapsed += $Interval
        if (Test-Docker $cmd) {
            Write-Host " ready."
            return $true
        }
        Write-Host "." -NoNewline
    }
    Write-Host ""
    return $false
}

# Resolve a docker.exe path: PATH first, then the common per-user / system-wide Docker
# Desktop install locations.
$Docker = $null

if (Get-Command "docker" -ErrorAction SilentlyContinue) {
    $Docker = "docker"
} else {
    $UserDocker = "$env:LOCALAPPDATA\Programs\Docker\Docker\resources\bin\docker.exe"
    $SystemDocker = "C:\Program Files\Docker\Docker\resources\bin\docker.exe"
    if (Test-Path $UserDocker) {
        $Docker = $UserDocker
    } elseif (Test-Path $SystemDocker) {
        $Docker = $SystemDocker
    }
}

if (-not $Docker) {
    Fail "Docker Desktop is not installed. Install it from https://www.docker.com/products/docker-desktop, then re-run this script."
}

if (-not (Test-Docker $Docker)) {
    # docker.exe exists but the daemon isn't responding - Docker Desktop is closed.
    # Try to launch it and wait briefly rather than failing immediately.
    $DesktopExe = Find-DockerDesktopExe
    if ($DesktopExe) {
        Write-Host "Docker Desktop is not running. Launching it..."
        Start-Process -FilePath $DesktopExe | Out-Null
        if (-not (Wait-ForDocker $Docker 60)) {
            Fail "Docker Desktop did not become ready within 60 seconds. Start it manually, wait until it says 'Docker Desktop is running', then re-run this script."
        }
    } else {
        Fail "Docker Desktop is installed but not running, and it could not be launched automatically (Docker Desktop.exe not found). Start it manually, wait until it is ready, then re-run this script."
    }
}

# --------------------------------------------------
# Detect GPU VRAM (MB)
# --------------------------------------------------

function Get-NvidiaSmiPath {
    if (Get-Command "nvidia-smi" -ErrorAction SilentlyContinue) {
        return "nvidia-smi"
    }
    $SystemNvidiaSmi = "C:\Windows\System32\nvidia-smi.exe"
    if (Test-Path $SystemNvidiaSmi) {
        return $SystemNvidiaSmi
    }
    return $null
}

$NvidiaSmi = Get-NvidiaSmiPath
$VramMb = 0
$GpuCount = 0

if ($NvidiaSmi) {
    try {
        # nvidia-smi prints one line per NVIDIA GPU ("<name>, <VRAM MiB>"). Enumerate and
        # sum all of them: docker-compose.gpu.yml requests every NVIDIA GPU (count: all),
        # and Ollama can split a model's layers across multiple cards. This intentionally
        # only sees NVIDIA devices — integrated/other-vendor GPUs never appear here.
        $SmiLines = & $NvidiaSmi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null
        foreach ($line in $SmiLines) {
            $Parts = $line -split ",\s*"
            if ($Parts.Count -ge 2) {
                $GpuName = $Parts[0].Trim()
                $GpuVram = [int]($Parts[1].Trim())
                Write-Host "Detected GPU: $GpuName ($GpuVram MB)"
                $VramMb += $GpuVram
                $GpuCount++
            }
        }
    } catch {
        Write-Host "WARNING: Could not query GPU VRAM. Treating as CPU-only system."
        $VramMb = 0
        $GpuCount = 0
    }
} else {
    Write-Host "WARNING: nvidia-smi not found. Treating as CPU-only system."
}

if ($VramMb -gt 0) {
    if ($GpuCount -gt 1) {
        Write-Host "Combined GPU VRAM across $GpuCount NVIDIA GPUs: $VramMb MB"
    } else {
        Write-Host "Detected GPU VRAM: $VramMb MB"
    }
    if ($VramMb -lt 6000) {
        Write-Host "GPU tier: LOW VRAM (<= 6 GB)"
    } elseif ($VramMb -lt 12000) {
        Write-Host "GPU tier: MID VRAM (6-12 GB)"
    } else {
        Write-Host "GPU tier: HIGH VRAM (12+ GB)"
    }
} else {
    Write-Host "GPU tier: NONE / CPU-only"
}
Write-Host ""

# --------------------------------------------------
# Create data directories
# --------------------------------------------------

New-Item -ItemType Directory -Force (Join-Path $Root "data\ollama") | Out-Null
New-Item -ItemType Directory -Force (Join-Path $Root "data\open-webui") | Out-Null

# --------------------------------------------------
# Load config
# --------------------------------------------------

if (-not (Test-Path $Config)) {
    Fail "Missing config\models.env"
}

Get-Content $Config | ForEach-Object {
    if ($_ -match "^(ENABLE_\w+)=(\d)") {
        Set-Variable -Name $matches[1] -Value $matches[2]
    }
}

# --------------------------------------------------
# Enforce sane model selection by VRAM
# --------------------------------------------------
# This used to be a hard preflight Fail()/exit here, before Docker even started - one
# oversized enabled model killed the whole run even if every other enabled model would've
# fit fine. VRAM fit is now checked per model at pull time instead (see Pull-Model's
# -MinVramMb below): an out-of-budget model is skipped with a WARNING and folded into the
# same $ChatModelsRequested/$ChatModelsPulled counters a failed pull already uses. The run
# only stops with an error if nothing enabled ends up runnable - see the check right after
# the pull list below.

# --------------------------------------------------
# Start containers (GPU override attached only if a GPU was detected)
# --------------------------------------------------

$DockerDir = Join-Path $Root "docker"
if (-not (Test-Path $DockerDir)) {
    Fail "Missing docker directory"
}

# Compose files are referenced by absolute path instead of `cd`-ing into $DockerDir:
# Set-Location changes are process-wide in PowerShell (not scoped to this script), so a
# `cd` here would leave the user's own shell sitting in docker\ after the script exits.
$ComposeArgs = @("-f", (Join-Path $DockerDir "docker-compose.yml"))
if ($VramMb -gt 0) {
    $ComposeArgs += @("-f", (Join-Path $DockerDir "docker-compose.gpu.yml"))
}

& $Docker compose @ComposeArgs pull
& $Docker compose @ComposeArgs up -d

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
if ($VramMb -gt 0) {
    $DriverCheckElapsed = 0
    $DriverCheckInterval = 1
    $DriverCheckTimeout = 10
    while ($DriverCheckElapsed -lt $DriverCheckTimeout) {
        Start-Sleep -Seconds $DriverCheckInterval
        $DriverCheckElapsed += $DriverCheckInterval
        $OllamaStartupLogs = (& $Docker logs offgriddev-ollama) -join "`n"
        if ($OllamaStartupLogs -match 'NVIDIA driver too old"\s+device="([^"]+)"[^\n]*required_driver="([^"]+)"') {
            Write-Host ""
            Write-Host "WARNING: GPU detected ($($Matches[1])), but its NVIDIA driver is too old for this"
            Write-Host "  Ollama build (needs driver $($Matches[2])). Falling back to CPU - models will work"
            Write-Host "  but run much slower. Update the driver from https://www.nvidia.com/drivers, then"
            Write-Host "  re-run this script."
            Write-Host ""
            break
        }
    }
}

# --------------------------------------------------
# Pull enabled models
# --------------------------------------------------
# A pull can fail for reasons the VRAM gate above never checks - a registry hiccup, a
# full disk, a tag that's been retired - and previously any single failure called Fail()
# and killed the whole run, leaving every *other* enabled model unpulled too. Each
# failure is now reported and skipped instead, so the run keeps going through the rest of
# the list. Only the chat models (not the mandatory RAG embedding model below) count
# toward the "did anything usable come out of this" check right after the loop - if none
# of them pulled, there's nothing to chat with and the run stops there instead of handing
# the user a Web UI with an empty model list and no explanation.

$script:ChatModelsRequested = 0
$script:ChatModelsPulled = 0
$script:PulledChatModelLabels = @()
$script:FailedChatModelLabels = @()
# One entry per successfully pulled-and-aliased chat model, consumed below to generate
# Continue's config.yaml with explicit per-model entries instead of AUTODETECT-only.
$script:PulledModelEntries = @()

# Continue role sets by task, per this project's naming scheme (family-version:size-task):
# coding models keep the full role set Continue supports; reasoning models skip
# autocomplete/rerank (not meaningfully used in a reasoning workflow); Gemma (general) is
# chat/edit only; vision models are chat-only (no code-editing signal in an image).
$CodingRoles = @("chat", "edit", "apply", "autocomplete", "rerank")
$ReasoningRoles = @("chat", "edit", "apply")
$GeneralRoles = @("chat", "edit")
$VisionRoles = @("chat")

function Pull-Model($model, $label, [bool]$IsChatModel = $true, [string]$Alias = $null, [string[]]$Roles = @(), [int]$MinVramMb = 0) {
    if ($IsChatModel) { $script:ChatModelsRequested++ }
    # Per-model VRAM fit check, replacing the old preflight Fail()/exit: an enabled model
    # that doesn't fit this GPU is skipped (not downloaded) and reported the same way a
    # failed pull is, rather than killing the whole run before it starts. $MinVramMb of 0
    # means "no minimum" (small/medium models this project has never gated).
    if ($MinVramMb -gt 0 -and $VramMb -lt $MinVramMb) {
        Write-Host ""
        Write-Host "WARNING: Skipping $label ($model) - needs ~$([math]::Round($MinVramMb / 1000)) GB VRAM, this GPU has $VramMb MB. Not pulling it. Disable its ENABLE_* flag in models.env to silence this warning."
        Write-Host ""
        if ($IsChatModel) { $script:FailedChatModelLabels += $label }
        return
    }
    try {
        & $Docker exec offgriddev-ollama ollama pull $model
        if ($LASTEXITCODE -ne 0) {
            throw "ollama pull exited with code $LASTEXITCODE"
        }

        $FinalTag = $model
        if ($Alias) {
            # Renaming the Ollama tag itself (not an Open WebUI-only rename) is the only
            # mechanism visible to Continue's AUTODETECT scan and to FieldStationAI, both of
            # which read Ollama's /api/tags verbatim. `ollama cp` shares blobs (zero extra
            # disk); the `ollama rm` of the raw tag below is safe/refcounted - it only drops
            # the tag, never a blob the new alias still references.
            & $Docker exec offgriddev-ollama ollama cp $model $Alias
            if ($LASTEXITCODE -ne 0) {
                # `ollama cp` fails if the alias already exists - expected on a repeat run
                # of this script, not a real error. Confirm the alias is actually there
                # before treating this as success rather than assuming every cp failure is
                # the harmless idempotent case.
                & $Docker exec offgriddev-ollama ollama show $Alias *> $null
                if ($LASTEXITCODE -ne 0) {
                    throw "ollama cp $model -> $Alias failed and $Alias does not already exist"
                }
            }
            & $Docker exec offgriddev-ollama ollama rm $model *> $null
            $FinalTag = $Alias
        }

        if ($IsChatModel) {
            $script:ChatModelsPulled++
            $script:PulledChatModelLabels += $label
            if ($Alias) {
                $script:PulledModelEntries += @{ name = $label; model = $FinalTag; roles = $Roles }
            }
        }
    } catch {
        Write-Host ""
        Write-Host "WARNING: Failed to pull $label ($model). Skipping it and continuing with the remaining models."
        Write-Host "  $_"
        Write-Host ""
        if ($IsChatModel) { $script:FailedChatModelLabels += $label }
    }
}

# Always pulled, regardless of which chat models are enabled: docker-compose.yml points
# Open WebUI's RAG embeddings at this model over Ollama (RAG_EMBEDDING_ENGINE=ollama)
# instead of the default Hugging Face download, so it needs to already exist here before
# Open WebUI's first request for it - not a user-selectable chat model, so it's not
# gated behind an ENABLE_ flag in models.env, and its failure doesn't count against the
# "at least one chat model must succeed" check below (RAG degrades; chat still works).
# Left unaliased: docker-compose.yml's RAG_EMBEDDING_MODEL env var references this raw tag
# directly, and it's never chat-selectable, so aliasing it has no user-facing benefit.
Pull-Model "nomic-embed-text" "Nomic Embed Text (RAG embedding model)" $false

if ($ENABLE_QWEN25_CODER_0P5B -eq 1) {
    Pull-Model "qwen2.5-coder:0.5b" "Qwen 2.5 Coder 0.5B" -Alias "qwen25-coder:small-05b-coding" -Roles $CodingRoles
}

if ($ENABLE_QWEN25_CODER_1P5B -eq 1) {
    Pull-Model "qwen2.5-coder:1.5b" "Qwen 2.5 Coder 1.5B" -Alias "qwen25-coder:small-15b-coding" -Roles $CodingRoles
}

if ($ENABLE_QWEN25_CODER_3B -eq 1) {
    Pull-Model "qwen2.5-coder:3b" "Qwen 2.5 Coder 3B" -Alias "qwen25-coder:small-3b-coding" -Roles $CodingRoles
}

if ($ENABLE_QWEN25_CODER_7B -eq 1) {
    Pull-Model "qwen2.5-coder:7b" "Qwen 2.5 Coder 7B" -Alias "qwen25-coder:medium-coding" -Roles $CodingRoles -MinVramMb 6000
}

if ($ENABLE_QWEN25_CODER_14B -eq 1) {
    Pull-Model "qwen2.5-coder:14b" "Qwen 2.5 Coder 14B" -Alias "qwen25-coder:large-coding" -Roles $CodingRoles -MinVramMb 6000
}

if ($ENABLE_QWEN25_CODER_32B -eq 1) {
    Pull-Model "qwen2.5-coder:32b" "Qwen 2.5 Coder 32B" -Alias "qwen25-coder:xlarge-coding" -Roles $CodingRoles -MinVramMb 12000
}

if ($ENABLE_QWEN3_CODER_30B -eq 1) {
    Pull-Model "qwen3-coder:30b" "Qwen3 Coder 30B" -Alias "qwen3-coder:xlarge-coding" -Roles $CodingRoles -MinVramMb 12000
}

if ($ENABLE_DEVSTRAL_24B -eq 1) {
    Pull-Model "devstral:24b" "Devstral 24B" -Alias "devstral:xlarge-coding" -Roles $CodingRoles -MinVramMb 12000
}

if ($ENABLE_DEEPSEEK_CODER_1P3B -eq 1) {
    Pull-Model "deepseek-coder:1.3b" "DeepSeek Coder 1.3B" -Alias "deepseek-coder:small-coding" -Roles $CodingRoles
}

if ($ENABLE_DEEPSEEK_CODER_6P7B -eq 1) {
    Pull-Model "deepseek-coder:6.7b" "DeepSeek Coder 6.7B" -Alias "deepseek-coder:medium-coding" -Roles $CodingRoles -MinVramMb 6000
}

if ($ENABLE_DEEPSEEK_CODER_33B -eq 1) {
    Pull-Model "deepseek-coder:33b" "DeepSeek Coder 33B" -Alias "deepseek-coder:xlarge-coding" -Roles $CodingRoles -MinVramMb 12000
}

if ($ENABLE_GEMMA3_1B -eq 1) {
    Pull-Model "gemma3:1b" "Gemma 3 1B" -Alias "gemma3:small-general" -Roles $GeneralRoles
}

if ($ENABLE_GEMMA3_4B -eq 1) {
    Pull-Model "gemma3:4b" "Gemma 3 4B" -Alias "gemma3:medium-general" -Roles $GeneralRoles
}

if ($ENABLE_GEMMA4_E4B -eq 1) {
    Pull-Model "gemma4:e4b" "Gemma 4 E4B" -Alias "gemma4:medium-general" -Roles $GeneralRoles -MinVramMb 6000
}

if ($ENABLE_GEMMA4_26B_A4B -eq 1) {
    Pull-Model "gemma4:26b-a4b" "Gemma 4" -Alias "gemma4:large-general" -Roles $GeneralRoles -MinVramMb 12000
}

if ($ENABLE_DEEPSEEK_R1_7B -eq 1) {
    Pull-Model "deepseek-r1:7b" "DeepSeek-R1 7B" -Alias "deepseek-r1:medium-reasoning" -Roles $ReasoningRoles -MinVramMb 6000
}

if ($ENABLE_DEEPSEEK_R1_14B -eq 1) {
    Pull-Model "deepseek-r1:14b" "DeepSeek-R1 14B" -Alias "deepseek-r1:large-reasoning" -Roles $ReasoningRoles -MinVramMb 6000
}

if ($ENABLE_DEEPSEEK_R1_32B -eq 1) {
    Pull-Model "deepseek-r1:32b" "DeepSeek-R1 32B" -Alias "deepseek-r1:xlarge-reasoning" -Roles $ReasoningRoles -MinVramMb 12000
}

if ($ENABLE_QWEN3_8B -eq 1) {
    Pull-Model "qwen3:8b" "Qwen3 8B" -Alias "qwen3:medium-reasoning" -Roles $ReasoningRoles -MinVramMb 6000
}

if ($ENABLE_QWEN3_14B -eq 1) {
    Pull-Model "qwen3:14b" "Qwen3 14B" -Alias "qwen3:large-reasoning" -Roles $ReasoningRoles -MinVramMb 6000
}

if ($ENABLE_QWEN3_30B_A3B -eq 1) {
    Pull-Model "qwen3:30b-a3b" "Qwen3 30B A3B" -Alias "qwen3:xlarge-reasoning" -Roles $ReasoningRoles -MinVramMb 12000
}

if ($ENABLE_QWQ_32B -eq 1) {
    Pull-Model "qwq:32b" "QwQ 32B" -Alias "qwq:xlarge-reasoning" -Roles $ReasoningRoles -MinVramMb 12000
}

if ($ENABLE_HERMES3_3B -eq 1) {
    Pull-Model "hermes3:3b" "Hermes 3 3B" -Alias "hermes3:small-reasoning" -Roles $ReasoningRoles
}

if ($ENABLE_HERMES3_8B -eq 1) {
    Pull-Model "hermes3:8b" "Hermes 3 8B" -Alias "hermes3:medium-reasoning" -Roles $ReasoningRoles -MinVramMb 6000
}

if ($ENABLE_PHI4_MINI_REASONING_3P8B -eq 1) {
    Pull-Model "phi4-mini-reasoning:3.8b" "Phi4 Mini Reasoning 3.8B" -Alias "phi4:small-reasoning" -Roles $ReasoningRoles
}

if ($ENABLE_PHI4_REASONING_14B -eq 1) {
    Pull-Model "phi4-reasoning:14b" "Phi4 Reasoning 14B" -Alias "phi4:large-reasoning" -Roles $ReasoningRoles -MinVramMb 6000
}

if ($ENABLE_MOONDREAM_1P8B -eq 1) {
    Pull-Model "moondream:1.8b" "Moondream 1.8B" -Alias "moondream:small-vision" -Roles $VisionRoles
}

if ($ENABLE_QWEN25VL_7B -eq 1) {
    Pull-Model "qwen2.5vl:7b" "Qwen 2.5 VL 7B" -Alias "qwen25vl:medium-vision" -Roles $VisionRoles -MinVramMb 6000
}

if ($ChatModelsRequested -gt 0 -and $ChatModelsPulled -eq 0) {
    Fail "All $ChatModelsRequested enabled chat model(s) failed to pull. See the warnings above for why, fix the underlying issue (network, disk space, registry), then re-run this script."
}
if ($ChatModelsPulled -lt $ChatModelsRequested) {
    Write-Host "NOTE: $ChatModelsPulled of $ChatModelsRequested enabled chat models pulled successfully. Continuing with those."
    Write-Host ""
}

# --------------------------------------------------
# Health check
# --------------------------------------------------
# Polls the container's own Docker healthcheck instead of firing one HTTP request right
# after `up -d`: Open WebUI's first-boot init (loading its embedding model, running DB
# migrations) routinely takes 15-30+ seconds, so a single immediate request almost always
# hit it mid-startup and failed the whole script even though the container was fine.

function Wait-ForWebUI([int]$TimeoutSeconds) {
    $Elapsed = 0
    $Interval = 3
    Write-Host "Waiting for Web UI to finish starting..." -NoNewline
    while ($Elapsed -lt $TimeoutSeconds) {
        $HealthStatus = & $Docker inspect --format "{{.State.Health.Status}}" offgriddev-webui 2>$null
        if ($HealthStatus -eq "healthy") {
            Write-Host " ready."
            return $true
        }
        Start-Sleep -Seconds $Interval
        $Elapsed += $Interval
        Write-Host "." -NoNewline
    }
    Write-Host ""
    return $false
}

if (-not (Wait-ForWebUI 90)) {
    Fail "Web UI did not report healthy within 90 seconds. Check its logs: docker logs offgriddev-webui"
}

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
$NonToolCapableModels = @(
    @{ id = "deepseek-coder:small-coding";  name = "DeepSeek Coder 1.3B" },
    @{ id = "deepseek-coder:medium-coding"; name = "DeepSeek Coder 6.7B" },
    @{ id = "deepseek-coder:xlarge-coding"; name = "DeepSeek Coder 33B" },
    @{ id = "gemma3:small-general";         name = "Gemma 3 1B" },
    @{ id = "gemma3:medium-general";        name = "Gemma 3 4B" },
    @{ id = "phi4:small-reasoning";         name = "Phi4 Mini Reasoning 3.8B" },
    @{ id = "phi4:large-reasoning";         name = "Phi4 Reasoning 14B" },
    @{ id = "moondream:small-vision";       name = "Moondream 1.8B" },
    @{ id = "qwen25vl:medium-vision";       name = "Qwen 2.5 VL 7B" }
)
try {
    $SignIn = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/auths/signin" -Method Post `
        -ContentType "application/json" -Body '{"email":"admin@localhost","password":""}' -ErrorAction Stop
    $AuthHeaders = @{ Authorization = "Bearer $($SignIn.token)" }
    foreach ($ModelEntry in $NonToolCapableModels) {
        $Payload = @{
            id = $ModelEntry.id
            base_model_id = $ModelEntry.id
            name = $ModelEntry.name
            meta = @{}
            params = @{ function_calling = "legacy" }
            is_active = $true
        } | ConvertTo-Json -Depth 5
        try {
            Invoke-RestMethod -Uri "http://localhost:3000/api/v1/models/create" -Method Post `
                -ContentType "application/json" -Headers $AuthHeaders -Body $Payload -ErrorAction Stop | Out-Null
        } catch {
            # Most likely this model ID already exists (e.g. re-running this script, or a
            # manual edit in the UI left it misconfigured) - fall back to updating it in
            # place so the fix still applies. Failure here is non-fatal either way.
            try {
                Invoke-RestMethod -Uri "http://localhost:3000/api/v1/models/model/update" -Method Post `
                    -ContentType "application/json" -Headers $AuthHeaders -Body $Payload -ErrorAction Stop | Out-Null
            } catch {}
        }
    }
} catch {
    Write-Host "NOTE: Could not auto-configure DeepSeek Coder / Gemma 3 / Phi / Moondream / Qwen 2.5 VL for tool compatibility (Open WebUI auth may be enabled). See README's Troubleshooting section to do it manually."
}

# --------------------------------------------------
# Write Continue (VS Code) config
# --------------------------------------------------

$ContinueDir = Join-Path $env:USERPROFILE ".continue"
$ContinueConfig = Join-Path $ContinueDir "config.yaml"

New-Item -ItemType Directory -Force $ContinueDir | Out-Null

# One explicit named entry per model that actually pulled-and-aliased this run (friendly
# name, alias tag, and its task-appropriate role set), plus AUTODETECT kept as a trailing
# catch-all - that still picks up anything pulled out-of-band via Open WebUI's manual-pull
# UI, which never goes through the alias step above.
$ContinueConfigLines = @(
    "name: OffgridDev",
    "version: 0.0.1",
    "schema: v1",
    "models:"
)
foreach ($ModelEntry in $script:PulledModelEntries) {
    $ContinueConfigLines += "  - name: $($ModelEntry.name)"
    $ContinueConfigLines += "    provider: ollama"
    $ContinueConfigLines += "    model: $($ModelEntry.model)"
    $ContinueConfigLines += "    apiBase: http://localhost:11434"
    $ContinueConfigLines += "    roles:"
    foreach ($Role in $ModelEntry.roles) {
        $ContinueConfigLines += "      - $Role"
    }
}
$ContinueConfigLines += "  - name: OffgridDev Autodetect"
$ContinueConfigLines += "    provider: ollama"
$ContinueConfigLines += "    model: AUTODETECT"
$ContinueConfigLines += "    apiBase: http://localhost:11434"
$ContinueConfigLines += "    roles:"
foreach ($Role in @("chat", "edit", "apply", "rerank", "autocomplete")) {
    $ContinueConfigLines += "      - $Role"
}

$ContinueConfigLines | Set-Content -Path $ContinueConfig -Encoding utf8

Write-Host "Continue config written to:"
Write-Host $ContinueConfig
Write-Host ""

# --------------------------------------------------
# Success
# --------------------------------------------------

Write-Host ""
Write-Host "OffgridDev READY"
Write-Host "Web UI: http://localhost:3000"
Write-Host "API   : http://localhost:11434"
Write-Host ""
# Reflects what actually pulled, not just what was enabled in models.env - a model that
# failed above (see warnings) is not silently reported as available here.
Write-Host "Active models:"
if ($PulledChatModelLabels.Count -eq 0) {
    Write-Host "  (none)"
} else {
    foreach ($ModelLabel in $PulledChatModelLabels) { Write-Host "  - $ModelLabel" }
}
if ($FailedChatModelLabels.Count -gt 0) {
    Write-Host ""
    Write-Host "Failed to pull (not available in Web UI or Continue - see warnings above):"
    foreach ($ModelLabel in $FailedChatModelLabels) { Write-Host "  - $ModelLabel" }
}
Write-Host ""
Write-Host "#InfiniteTokens"
Write-Host ""
Read-Host "Press Enter to exit"

$script:ScriptCompletedNormally = $true

} finally {
    if (-not $script:ScriptCompletedNormally -and -not $script:ExpectedExit) {
        Write-Host ""
        Write-Host "Interrupted - stopping."
    }
}
