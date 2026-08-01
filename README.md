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
- **Core VM's CPU type must expose AVX** — MongoDB 5.0+ (used by the Graylog stack) hard-requires it
  and crash-loops without it. On Proxmox, the default CPU types (`kvm64`, or the newer
  `x86-64-v2-AES` baseline) deliberately exclude AVX for migration compatibility — set the VM's
  **Hardware → Processor → Type** to `host` (or another AVX-including type, e.g. `x86-64-v3`)
  *before* first boot. The installer checks this itself and fails fast with instructions if it's
  wrong, but it's a VM-level setting that needs a full VM shutdown/start (not a guest reboot) to
  take effect, so better to set it upfront.
- **Monitored VMs/LXCs**: no special sizing — agents use tens of MB RAM at idle. Note: Rustinel/Falco/Sysmon
  need real eBPF access, so run them on full VMs, not unprivileged LXCs.
- Root/sudo access on every host, outbound internet access (to pull packages/images/CTI feeds).

## Troubleshooting core install

If `--role=core` seems stuck or the Graylog UI never comes up, check what's actually happening
before assuming it's hung — Java/OpenSearch startup is slow, but a genuine crash-loop looks
different from "still booting":

```bash
cd /opt/threadline && docker compose -f docker/graylog-compose.yml logs -f
```

(the `docker/.env` symlink created by the installer means this works without needing
`--env-file` explicitly, even run from inside `docker/`)

**`MongoDB 5.0+ requires a CPU with AVX support` repeating, or Graylog can't resolve `mongodb`**:
your VM's CPU type doesn't expose AVX — see the Requirements note above. The installer's own
preflight check should catch this before it ever gets this far; if you're seeing it anyway, the
CPU type change likely didn't fully take effect (needs a full VM **shutdown then start**, not a
guest reboot — verify with `grep -i avx /proc/cpuinfo` inside the guest after restarting).

**`No custom admin password found... OPENSEARCH_INITIAL_ADMIN_PASSWORD`, `soc-opensearch exited
with code 1 (restarting)`**: OpenSearch's Docker entrypoint (2.12+) refuses to start at all
without this variable, independent of `plugins.security.disabled`. The installer generates and
sets it automatically — if you're hitting this, your `.env` predates that fix; delete
`/opt/threadline/.env` and re-run `--role=core` to regenerate it with the current `.env.example`.
Always bring the stack up via `sudo ./run.sh --role=core`, never raw `docker compose up`/`logs` —
the latter won't pick up `.env` fixes on already-running containers, it just tails whatever's
already there.

**Image pulls fail with `dial tcp [2600:...]:443: connect: network is unreachable`**: not Docker
Hub rate limiting (that error looks completely different — an HTTP 429 with `toomanyrequests`).
This is an IPv6 routing problem: the registry resolved to an IPv6 address and your VM has no
working IPv6 route, common on Proxmox VMs that get a SLAAC IPv6 address with no real upstream
IPv6 connectivity behind it. Confirm with `curl -6 -m 5 https://registry-1.docker.io/v2/` (hangs/
errors) vs `curl -4 -m 5 https://registry-1.docker.io/v2/` (works). Fix by disabling IPv6 on the
VM:
```bash
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
sudo systemctl restart docker
# persist across reboots:
printf 'net.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\n' | \
  sudo tee /etc/sysctl.d/99-disable-ipv6.conf && sudo sysctl --system
```
Then just re-run the installer or `docker compose pull` again — layer pulls resume/cache, nothing
already-pulled gets re-downloaded.

## 1. Install the core (Graylog + MISP)

On the VM that will host both:

```bash
curl -fsSL https://raw.githubusercontent.com/R4z1xx/threadline/main/install.sh | sudo bash -s -- --role=core
```

This will:
- Install Docker if it's missing.
- Generate every secret (Graylog `password_secret`, admin password, MISP DB/Redis passwords, GPG passphrase) into `/opt/threadline/.env` (`chmod 600` — back this file up).
- Bring up Graylog (MongoDB + OpenSearch + Graylog server) via Docker Compose.
- Clone the official [`MISP/misp-docker`](https://github.com/MISP/misp-docker) project and bring it up alongside.
- Create the GELF UDP input every agent ships to (via Graylog's Inputs API directly, idempotent -- safe to re-run).
- Print the URLs and credentials you need.

Takes 5-15 minutes depending on your link speed (MISP's image pulls are the slow part).

## 2. Post-install Graylog setup (one-time, ~2 minutes)

The GELF input is created automatically during `--role=core`. The MISP enrichment lookup table
(data adapter → cache → lookup table) and the Sigma-based alert pipeline are created automatically
too, as soon as you provide a MISP API key -- the only genuinely manual step left:

1. **Get a MISP API key**: log in to MISP (URL/creds are in `.env` on the core VM) → **Administration
   → List Auth Keys → Add authentication key**. Copy it.
2. **Provide it and re-run**:
   ```bash
   echo "MISP_API_KEY=<the key>" >> /opt/threadline/.env
   sudo /opt/threadline/run.sh --role=core --link-misp
   ```
   This one command creates the `misp-adapter` data adapter, the `misp-cache` cache (TTL from
   `MISP_LOOKUP_CACHE_TTL_SECONDS` in `.env`, default 12h), the `misp_ioc_lookup` lookup table, the
   `enrich src_ip with MISP` pipeline rule, the pipeline itself, and connects it to Graylog's
   default stream. It's also safe to re-run any time -- every step checks for an existing entity by
   name before creating a duplicate, and re-running with a rotated `MISP_API_KEY` just updates the
   adapter's credentials in place. Same command also **loads MISP's default feed catalog, enables
   the feeds listed in `MISP_ENABLE_FEEDS`, adds anything in `MISP_CUSTOM_FEEDS`** — see the
   comments in `.env.example` for a Rösti example — **and triggers an initial fetch**.

If any individual step warns instead of confirming success (Graylog's Lookup Table/Pipeline REST
API schemas are more version-sensitive than the plain GELF input, so this is a real possibility,
not just defensive boilerplate) — the warning names exactly which piece failed and includes
Graylog's own error message plus a manual fallback for that one piece. The manual, click-through
version of every step is documented in [`docs/graylog-pipelines.md`](docs/graylog-pipelines.md) in
case you need to finish one of them by hand or want to understand what the automation is actually
doing.

## 3. Install agents on every VM you want monitored

```bash
curl -fsSL https://raw.githubusercontent.com/R4z1xx/threadline/main/install.sh | \
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
