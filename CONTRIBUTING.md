<!--
This file is part of OffgridDev
CONTRIBUTING.md
Author(s): OffgridDev contributors
Created: 2026-11-20
Summary: Explains how to make and check a first contribution to OffgridDev.
Notes: See README file for documentation and full license information.

Copyright © 2026 The Regents of the University of Michigan
Licensed under the GNU Free Documentation License v1.3 or later.
See <https://www.gnu.org/licenses/fdl-1.3.html>.
-->

# Contributing to OffgridDev

Pick a small [open issue](https://github.com/DepressionCenter/OffgridDev/issues)
and check whether someone already has a pull request for it. A documentation
change is a good way to start without downloading models.

## Find the files

| Path | What it contains |
| --- | --- |
| [`scripts/`](scripts/) | Start and stop scripts for Bash and PowerShell |
| [`config/models.env`](config/models.env) | Switches that turn individual models on or off |
| [`docker/`](docker/) | Docker Compose files for the base stack and NVIDIA GPU support |
| [`docs/`](docs/) | Installation, hardware, and troubleshooting guides |

Read [AGENTS.md](AGENTS.md) for project rules. Keep existing copyright and license
notices. Use made-up data in examples and test files. Keep passwords, API keys,
and private research data out of commits, logs, and screenshots.

## Make a change

1. Fork the repository on GitHub to make a copy under your account. Clone that
   copy to your computer. Replace `YOUR-USERNAME` with your GitHub username.

   ```bash
   git clone https://github.com/YOUR-USERNAME/OffgridDev.git
   cd OffgridDev
   git switch -c fix/short-description
   ```

2. Edit the files for your issue and run the checks below that apply to your
   change. A branch keeps your edits separate from the main project.
3. Review the diff, commit it, and push your branch to your fork.

   ```bash
   git diff --check
   git status --short
   git add README.md
   git commit -m "Clarify setup instructions"
   git push -u origin fix/short-description
   ```

   Replace `README.md` and the commit message with the files and purpose of your
   own change.
4. On GitHub, open a pull request from your branch to OffgridDev's `main` branch.
   A pull request asks the project maintainers to review your changes. Link the
   issue, explain the change, and list the checks you ran and anything you could
   not test.

## Check your work

- For edits to the macOS and Linux launchers, run the Bash syntax checks below.
  Try behavior changes on the relevant system with Docker when available.
- For Windows launcher behavior, verify with Windows PowerShell and Docker
  Desktop on Windows.
- For Compose changes, run the config checks below. They require the Docker
  Compose command, but they do not start containers or download models.

```bash
bash -n scripts/offgriddev-start.sh
bash -n scripts/offgriddev-stop.sh
docker compose -f docker/docker-compose.yml config --quiet
docker compose -f docker/docker-compose.yml -f docker/docker-compose.gpu.yml config --quiet
```

If a change depends on a system you cannot test, name the system in your pull
request and ask a maintainer for that check. NVIDIA behavior needs a machine with
a supported NVIDIA GPU and the appropriate Docker setup.
