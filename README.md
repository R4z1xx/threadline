# ThreadLine

```
 _____ _                        _   __ _
/__   \ |__  _ __ ___  __ _  __| | / /(_)_ __   ___
  / /\/ '_ \| '__/ _ \/ _` |/ _` |/ / | | '_ \ / _ \
 / /  | | | | | |  __/ (_| | (_| / /__| | | | |  __/
 \/   |_| |_|_|  \___|\__,_|\__,_\____/_|_| |_|\___|

```

A tiny, self-hosted SOC for your homelab: **Graylog** (SIEM + Alerts UI) + **MISP** (CTI) on one VM,
and lightweight detection agents (**Vector**, **Rustinel**, **Falco**, **Sysmon for Linux**) on every
VM you want monitored. No Ansible, no Terraform, no inventory files required — just `curl | bash`
on each machine.

```
┌───────────────────────────────────────────────────────────┐
│  Monitored VM (Ubuntu 22.04/24.04)                         │
│   Rustinel (eBPF EDR: Sigma+YARA+IOC)  ──┐                 │
│   Falco (container/syscall runtime sec.) ─┼─> Vector ──────┼──> Graylog GELF :12201
│   Sysmon-Linux (process/net/file events) ┘   (journald,    │
│   docker logs / app logs / journald ─────────  file tails) │
└───────────────────────────────────────────────────────────┘
                                                     │
                                    ┌────────────────▼────────────────┐
                                    │  Core VM                        │
                                    │  Graylog (Alerts UI, pipelines,  │
                                    │  MISP lookup enrichment)         │
                                    │  MISP (CTI feeds)                │
                                    └───────────────────────────────────┘
```

## Requirements

- Proxmox (or any hypervisor) with a couple of Ubuntu 22.04/24.04 VMs.
- **Core VM**: 4 vCPU / 8 GB RAM / 60+ GB disk minimum (Graylog + OpenSearch + MISP all run here via Docker).
- **Monitored VMs/LXCs**: no special sizing — agents use tens of MB RAM at idle. Note: Rustinel/Falco/Sysmon
  need real eBPF access, so run them on full VMs, not unprivileged LXCs.
- Root/sudo access on every host, outbound internet access (to pull packages/images/CTI feeds).

## 1. Install the core (Graylog + MISP)

On the VM that will host both:

```bash
curl -fsSL https://raw.githubusercontent.com/YOURORG/threadline/main/install.sh | sudo bash -s -- --role=core
```

This will:
- Install Docker if it's missing.
- Generate every secret (Graylog `password_secret`, admin password, MISP DB/Redis passwords, GPG passphrase) into `/opt/threadline/.env` (`chmod 600` — back this file up).
- Bring up Graylog (MongoDB + OpenSearch + Graylog server) via Docker Compose.
- Clone the official [`MISP/misp-docker`](https://github.com/MISP/misp-docker) project and bring it up alongside.
- Import a starter Graylog content pack (the GELF input every agent ships to).
- Print the URLs and credentials you need.

Takes 5-15 minutes depending on your link speed (MISP's image pulls are the slow part).

## 2. Post-install Graylog setup (one-time, ~5 minutes)

The GELF input is ready out of the box, but the MISP enrichment lookup table and Sigma-based alert
pipeline are set up by hand once, because their exact JSON schema shifts between Graylog versions
and a stale imported schema causes more confusion than a short guided setup. Copy-paste, no
Graylog expertise required:

1. **Get a MISP API key**: log in to MISP (URL/creds are in `.env` on the core VM) → **Administration
   → List Auth Keys → Add authentication key**. Copy it.
2. **Create the lookup data adapter**: Graylog UI → **System → Lookup Tables → Data Adapters →
   Create data adapter** → type **HTTP JSON** →
   - Name/ID: `misp-adapter`
   - URL: `https://<misp-vm-ip>/attributes/restSearch`
   - Header: `Authorization: <the key from step 1>`
3. Or, skip the UI for step 2's header and just:
   ```bash
   echo "MISP_API_KEY=<the key>" >> /opt/threadline/.env
   sudo /opt/threadline/run.sh --role=core --link-misp
   ```
   (only works if you already created the `misp-adapter` data adapter once via the UI in step 2 —
   this patches in the key automatically on every future re-run/rotation. It also **loads MISP's
   default feed catalog, enables the feeds listed in `MISP_ENABLE_FEEDS`, adds anything in
   `MISP_CUSTOM_FEEDS` — see the comments in `.env.example` for a Rösti example — and triggers an
   initial fetch**, so this one command is doing double duty.)
4. **Create a cache**: **System → Lookup Tables → Caches → Create cache**, TTL 12-24h is reasonable for a homelab.
5. **Create the lookup table**: bind adapter + cache, name it `misp_ioc_lookup`.
6. **Add a pipeline rule** enriching `src_ip`/`dst_ip` fields with it (Sigma alert pipelines and the
   exact enrichment rule DSL are in [`docs/graylog-pipelines.md`](docs/graylog-pipelines.md) — copy/paste ready).

## 3. Install agents on every VM you want monitored

```bash
curl -fsSL https://raw.githubusercontent.com/YOURORG/threadline/main/install.sh | \
  sudo bash -s -- --role=agent --graylog=<core-vm-ip>
```

Vector is always installed. You'll be prompted interactively for Rustinel / Falco (only offered if
Docker is present on that host) / Sysmon-Linux / ATR (AI agent threat scanning) / the Ollama ATR
proxy. To skip prompts (e.g. for scripting a few hosts):

```bash
sudo bash -s -- --role=agent --graylog=<core-vm-ip> --agents=rustinel,sysmon --yes

# On a host running MCP servers / Claude Code / agent frameworks, add ATR:
export ATR_SCAN_PATHS="/root/.claude/skills,/opt/mcp-servers"
sudo bash -s -- --role=agent --graylog=<core-vm-ip> --agents=rustinel,atr --yes

# On a host running Ollama:
sudo bash -s -- --role=agent --graylog=<core-vm-ip> --agents=ollama-atr-proxy --yes
```

Re-running the installer on a host you've already set up is safe — it updates configs/binaries and
refreshes rule files from this repo rather than erroring out.

## Detection rules

Three sources, kept separate on disk so provenance is always obvious:

| Path (on each agent host, under `/opt/rustinel/rules/`) | Source | Update mechanism |
|---|---|---|
| `sigma/custom/` | `rules/sigma/` in this repo | copied by the installer every run |
| `sigma/vendor/sigmahq/` | [SigmaHQ/sigma](https://github.com/SigmaHQ/sigma) default repo, filtered to `linux`, `cloud`, `network`, `web` categories | `git sparse-checkout` + pull, re-synced every agent install/re-run |
| `yara/custom/` | `rules/yara/` in this repo | copied by the installer every run |
| `yara/vendor/yara-collection/` | your own [R4z1xx/yara-collection](https://github.com/R4z1xx/yara-collection) | `git clone`/pull, re-synced every agent install/re-run |

Falco intentionally stays on the **stock `falcosecurity/rules` default set only** (installed with the `falco` package, no extra sync) — deliberate choice, add more manually later if you want broader coverage.

Sysmon-Linux syncs the real **[MSTIC-Sysmon](https://github.com/microsoft/MSTIC-Sysmon)** config at install time (sparse-checkout of `linux/configs/`, same pattern as the Sigma/YARA vendor sync above) — `main.xml` by default, which merges MSTIC's dozens of individual ATT&CK-technique XML snippets into one inclusion-only ruleset. Override to `collect-all.xml` for unfiltered logging (heavier, useful for active threat-hunting labs, not recommended as a steady-state default):

```bash
export MSTIC_SYSMON_CONFIG="collect-all.xml"
```

**ATR** ([agentthreatrule.org](https://agentthreatrule.org)) is a different threat surface entirely —
AI agent security (prompt injection, tool poisoning, malicious MCP skills/configs) rather than
host/container behavior. Opt-in only, and only useful on hosts actually running AI agent tooling
(MCP servers, Claude Code, LangChain-style frameworks). Set `ATR_SCAN_PATHS` (comma-separated
directories to scan) before installing it — without that variable the install step skips itself
with a reminder rather than doing nothing silently. It runs on a systemd timer (`ATR_SCAN_INTERVAL`,
default 15min) rather than a live event stream — SARIF output gets flattened to NDJSON and shipped
to Graylog the same way as Rustinel/Falco findings, tagged `source_tool=atr`.

Vendor rule checkouts live under `/opt/threadline-cache/` on each agent host (gitignored, not part of this repo) so the repo itself stays small and update cadence is a `git pull` away from current rather than pinned in this project. To point at a fork or different commit, export before running the installer:

```bash
export YARA_COLLECTION_REPO="https://github.com/you/your-fork.git"
export SIGMAHQ_CATEGORIES="linux cloud"   # narrower/wider than the default linux/cloud/network/web
```

## AI/LLM telemetry (Claude Code, Claude Cowork, Ollama)

The core stack also brings up an **OTel Collector** (`docker/graylog-compose.yml`), bridging
OpenTelemetry-emitting apps to Graylog's native OTLP input — covers Claude Code CLI, the VS Code
extension, and Claude Cowork, including over Remote-SSH. Ollama has no OTel equivalent, so
`docker/ollama-atr-proxy/` is a small reverse proxy with a real embedded ATR engine instead —
install it as the `ollama-atr-proxy` agent, point n8n's Ollama node at it instead of Ollama
directly, and it can either just log matches (`alert` mode) or block high/critical ones outright
(`enforce` mode).

Full walkthrough, including the Remote-SSH extension-placement gotcha and known upstream bugs to
check for first: [`docs/ai-agent-telemetry.md`](docs/ai-agent-telemetry.md).

Rustinel hot-reloads all of this without a restart. To refresh rules on a host without touching the binary or systemd unit:

```bash
cd /opt/threadline && source lib/agent_rustinel.sh && sync_sigmahq && sync_yara_collection
```

Edit `rules/sigma/`/`rules/yara/` in this repo for your own hand-written rules and re-run the agent installer on each host to push updates.

## Project layout

```
threadline/
├── install.sh              # the only file you fetch by hand; clones this repo, hands off to run.sh
├── run.sh                  # real entrypoint, dispatches --role=core|agent
├── .env.example
├── docker/
│   ├── graylog-compose.yml
│   ├── otel-collector-config.yaml
│   └── ollama-atr-proxy/
│       ├── package.json
│       └── server.js
├── content-packs/
│   └── graylog-threadline.json
├── lib/
│   ├── common.sh
│   ├── docker.sh
│   ├── core_bootstrap.sh
│   ├── agent_vector.sh
│   ├── agent_rustinel.sh
│   ├── agent_falco.sh
│   ├── agent_sysmon.sh
│   ├── agent_atr.sh
│   └── agent_ollama_atr_proxy.sh
├── rules/
│   ├── sigma/  yara/  falco/
└── docs/
    ├── graylog-pipelines.md
    └── ai-agent-telemetry.md
```

## What this deliberately does not do

- No fleet-wide orchestration (no Ansible/Terraform requirement) — you run the one-liner per VM,
  by hand. Fine for a homelab's handful of machines; if you're managing dozens, nothing stops you
  wrapping this same `install.sh` in your own Ansible `shell:` task.
- No dry-run/plan step before applying changes — mitigated by idempotent re-runs and interactive
  prompts before anything that changes host firewall/security posture.
- MISP lookup table / alert pipelines are a guided manual step (§2), not blindly auto-imported,
  because getting that silently wrong is worse than a five-minute walkthrough.

## License note

This project only glues together and configures upstream tools — it doesn't vendor their code.
Each dependency keeps its own license: Graylog (SSPL/GPL depending on edition), MISP (AGPL-3.0),
Vector (MPL-2.0), Rustinel (check upstream repo), Falco (Apache-2.0), Sysmon for Linux (MIT, eBPF
components GPL-2.0). Review each before relying on this in anything beyond a personal homelab.
