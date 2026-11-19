# This file is part of OffgridDev
# offgriddev-stop.ps1
# Author(s): Gabriel Mongefranco
# Created: 2026-04-23
# Last Modified: 2026-08-06
# Summary: Windows launcher that stops the OffgridDev Docker stack (Ollama and Open WebUI
#   containers) without touching the bind-mounted data/ directory.
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

$Root = Resolve-Path "$PSScriptRoot\.."
$ComposeFile = Join-Path $Root "docker\docker-compose.yml"

try {
  docker info *> $null
  $dockerReady = $LASTEXITCODE -eq 0
} catch {
  $dockerReady = $false
}
if (-not $dockerReady) {
  [Console]::Error.WriteLine("ERROR: Docker is unavailable. Start Docker Desktop and try again.")
  exit 1
}

# Referenced by absolute path (no `cd`) so this doesn't leave the user's shell sitting in
# docker\ afterward - Set-Location changes persist in the caller's session in PowerShell.
docker compose -f $ComposeFile down
if ($LASTEXITCODE -ne 0) {
  [Console]::Error.WriteLine("ERROR: Docker Compose could not stop OffgridDev (exit code $LASTEXITCODE). Check Docker's output and try again.")
  exit 1
}
Write-Host "OffgridDev stopped."
