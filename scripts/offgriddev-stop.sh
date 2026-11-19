#!/usr/bin/env bash
# This file is part of OffgridDev
# offgriddev-stop.sh
# Author(s): Gabriel Mongefranco
# Created: 2026-04-23
# Last Modified: 2026-08-06
# Summary: macOS/Linux launcher that stops the OffgridDev Docker stack (Ollama and Open
#   WebUI containers) without touching the bind-mounted data/ directory.
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

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

docker info >/dev/null 2>&1 || {
  echo "Docker is not running."
  exit 1
}

# Referenced by absolute path (no `cd`) so this doesn't leave the caller's shell sitting
# in docker/ afterward.
docker compose -f "$ROOT/docker/docker-compose.yml" down
echo "OffgridDev stopped."
