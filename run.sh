#!/usr/bin/env bash
#
# threadline :: run.sh
# Dispatches to core or agent installation. Called by install.sh, but you can
# also run it directly from an existing checkout ($ sudo ./run.sh --role=agent ...).
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"

ROLE=""
GRAYLOG_HOST=""
AGENTS=""          # comma list: vector,rustinel,falco,sysmon,atr,ollama-atr-proxy (vector always added)
NONINTERACTIVE=0
LINK_MISP_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --role=*)       ROLE="${arg#*=}" ;;
    --graylog=*)    GRAYLOG_HOST="${arg#*=}" ;;
    --agents=*)     AGENTS="${arg#*=}" ;;
    --yes|--non-interactive) NONINTERACTIVE=1 ;;
    --link-misp)    LINK_MISP_ONLY=1 ;;
    -h|--help)
      cat <<'EOF'
Usage:
  run.sh --role=core
  run.sh --role=agent --graylog=<ip-or-hostname> [--agents=vector,rustinel,falco,sysmon,atr,ollama-atr-proxy] [--yes]

Roles:
  core    Installs Graylog stack + MISP + OTel Collector on this host (Docker-based).
  agent   Installs Vector (always) + optional detection tools on this host.

If --agents is omitted in agent mode, you'll be prompted interactively for
each tool. Falco is only offered on hosts where Docker is detected. ATR
(AI agent threat scanning) needs ATR_SCAN_PATHS exported before running.
ollama-atr-proxy needs Ollama reachable (OLLAMA_UPSTREAM, default
http://127.0.0.1:11434) -- see lib/agent_ollama_atr_proxy.sh for details.
EOF
      exit 0
      ;;
    *) die "Unknown argument: $arg (use --help)" ;;
  esac
done

require_supported_os

case "$ROLE" in
  core)
    source "$ROOT_DIR/lib/docker.sh"
    source "$ROOT_DIR/lib/core_bootstrap.sh"
    if [ "$LINK_MISP_ONLY" -eq 1 ]; then
      link_misp_to_graylog
    else
      install_docker
      bootstrap_core "$ROOT_DIR"
    fi
    ;;
  agent)
    [ -n "$GRAYLOG_HOST" ] || die "--graylog=<ip> is required in agent mode."
    source "$ROOT_DIR/lib/agent_vector.sh"
    install_vector "$ROOT_DIR" "$GRAYLOG_HOST"

    if [ -z "$AGENTS" ] && [ "$NONINTERACTIVE" -eq 0 ]; then
      AGENTS="$(prompt_agent_selection)"
    fi

    IFS=',' read -ra SELECTED <<< "$AGENTS"
    for a in "${SELECTED[@]}"; do
      case "$a" in
        rustinel)
          source "$ROOT_DIR/lib/agent_rustinel.sh"
          install_rustinel "$ROOT_DIR"
          ;;
        falco)
          source "$ROOT_DIR/lib/agent_falco.sh"
          install_falco "$ROOT_DIR"
          ;;
        sysmon)
          source "$ROOT_DIR/lib/agent_sysmon.sh"
          install_sysmon "$ROOT_DIR"
          ;;
        atr)
          source "$ROOT_DIR/lib/agent_atr.sh"
          install_atr "$ROOT_DIR"
          ;;
        ollama-atr-proxy)
          source "$ROOT_DIR/lib/agent_ollama_atr_proxy.sh"
          install_ollama_atr_proxy "$ROOT_DIR"
          ;;
        vector|"") ;; # already installed / no-op
        *) log "Skipping unknown agent '$a'" ;;
      esac
    done

    log "Reloading Vector to pick up any new alert sources..."
    systemctl restart vector

    log "Agent install complete on $(hostname). Shipping to Graylog at ${GRAYLOG_HOST}:12201/udp."
    ;;
  *)
    die "Missing or invalid --role (expected 'core' or 'agent'). Use --help."
    ;;
esac
