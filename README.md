<!--
This file is part of OffgridDev
README.md
Author(s): Gabriel Mongefranco
Created: 2026-04-23
Last Modified: 2026-08-06
Summary: Local, offline-first AI development environment for developers and researchers. This file provides an overview of the project, in Markdown format.
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

# OffgridDev™
​​​​​​​     _**#InfiniteTokens**_


## Description
OffgridDev™ is an open-source, local AI development environment for private and offline-first coding workflows. It combines Docker, Ollama, Open WebUI, and the Continue extension for Visual Studio Code so developers and researchers can use open-weight coding, reasoning, general-purpose, and vision models on their own hardware.

The setup detects GPU memory and recommends model options that fit the machine, with consistent model names across the included interfaces. After dependencies and models are installed, sensitive code and research scripts can stay on the local system instead of being sent to a hosted AI service.

Initial setup and model downloads require access to the relevant dependencies and model sources; offline operation is possible once the required components and selected models are present.


## Quick Start Guide
1. Install [Docker Desktop](https://www.docker.com/products/docker-desktop) and make sure it's running. Note: this may require administrator or super user rights.
2. Download this repo and extract it to `C:\OffgridDev` (Windows) or `~/offgriddev` (macOS/Linux).
3. Optionally edit `config/models.env` to choose which models to pull — sane defaults are already set.
4. Start the stack:
   - Windows: `powershell -ExecutionPolicy Bypass -File scripts\offgriddev-start.ps1`
   - macOS / Linux: `./scripts/offgriddev-start.sh`
5. Open http://localhost:3000 to chat, or use VS Code's Continue extension (config written automatically). Alternatively, you can download [FieldStationAI](https://github.com/DepressionCenter/FieldStationAI), launch it, and go to Menu -> Enable Ollama. It will automatically detect the local Ollama API and connect.
6. Stop the stack when done:
   - Windows: `powershell -ExecutionPolicy Bypass -File scripts\offgriddev-stop.ps1`
   - macOS / Linux: `./scripts/offgriddev-stop.sh`

For hardware requirements, full setup steps, and troubleshooting, see Documentation below.


## Documentation
+ Detailed setup and usage instructions are available at:
  - [Hardware & Model Configuration](docs/hardware-and-model-configuration.md) — GPU/VRAM/disk requirements, supported model families, and the `config/models.env` reference.
  - [Installation & Usage](docs/installation-and-usage.md) — full install steps, starting/stopping the stack, the Open WebUI web interface, and VS Code/Continue integration.
  - [Troubleshooting](docs/troubleshooting.md) — container logs, tool-calling errors, RAG embeddings, GPU fallback detection, and resetting a stuck container.


## Additional Resources
+ [Docker Desktop](https://www.docker.com/products/docker-desktop)
+ [Ollama](https://ollama.com)
+ [Open WebUI documentation](https://docs.openwebui.com)
+ [Continue for VS Code](https://marketplace.visualstudio.com/items?itemName=Continue.continue)
+ [FieldStationAI](https://github.com/DepressionCenter/FieldStationAI)


## About the Team
The [Mobile Technologies Core](https://depressioncenter.org/mobiletech) provides investigators across the University of Michigan the support and guidance needed to utilize mobile technologies and digital mental health measures in their studies. Experienced faculty and staff offer hands-on consultative services to researchers throughout the University – regardless of specialty or research focus.

Learn more at: [https://depressioncenter.org/mobiletech](https://depressioncenter.org/mobiletech).




## Contact
To get in touch, contact the individual developers in the check-in history.

If you need assistance identifying a contact person, email the EFDC's Mobile Technologies Core at: efdc-mobiletech@umich.edu.



## Credits
### Authors:
+ [Gabriel Mongefranco](https://gabriel.mongefranco.com) [(@gabrielmongefranco)](https://github.com/gabrielmongefranco)

### Contributors:
+ [Eisenberg Family Depression Center](https://depressioncenter.org) [(@DepressionCenter)](https://github.com/DepressionCenter)
+ [Sgt_Sinky (@Sinkleberg)](https://github.com/Sinkleberg)


#### This work is based in part on the following projects, libraries and/or studies:
+ [Ollama](https://ollama.com): Runs open-weight language models locally and serves them over a local API. This project's model runtime.
+ [Open WebUI](https://openwebui.com): Self-hosted chat interface for local LLMs. Provides this project's web UI at `localhost:3000`.
+ [Continue](https://www.continue.dev): Open-source AI coding assistant for VS Code. Provides in-editor chat, edit, and autocomplete against the local Ollama models.
+ [Docker](https://www.docker.com) / [Docker Compose](https://docs.docker.com/compose/): Containerizes and orchestrates the Ollama and Open WebUI services.


## License
### Copyright Notice
Copyright © 2026 The Regents of the University of Michigan


### Software and Library License Notice
This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program. If not, see <https://www.gnu.org/licenses/gpl-3.0-standalone.html>.


### Documentation License Notice
Permission is granted to copy, distribute and/or modify this document 
under the terms of the GNU Free Documentation License, Version 1.3 
or any later version published by the Free Software Foundation; 
with no Invariant Sections, no Front-Cover Texts, and no Back-Cover Texts. 
You should have received a copy of the license included in the section entitled "GNU 
Free Documentation License". If not, see <https://www.gnu.org/licenses/fdl-1.3-standalone.html>



## Citation
If you find this repository, code or paper useful for your research, please cite it.

#### Citation Example:
>_Mongefranco, Gabriel (2026). OffgridDev. University of Michigan. Software. https://github.com/DepressionCenter/OffgridDev_  
​​​​​​​     _DOI: [pending](https://doi.org/)_


----

Copyright © 2026 The Regents of the University of Michigan
