#!/usr/bin/env bash
# threadline :: lib/common.sh — sourced by run.sh and every lib/* script.
# Not meant to be executed directly.

log()  { echo -e "\033[1;34m[threadline]\033[0m $*"; }
warn() { echo -e "\033[1;33m[threadline][WARN]\033[0m $*"; }
die()  { echo -e "\033[1;31m[threadline][FATAL]\033[0m $*" >&2; exit 1; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

require_supported_os() {
  [ -f /etc/os-release ] || die "Cannot detect OS (/etc/os-release missing). Ubuntu 22.04/24.04 required."
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID}-${VERSION_ID}" in
    ubuntu-22.04|ubuntu-24.04) : ;;
    ubuntu-*)
      warn "Detected Ubuntu ${VERSION_ID}. This project is tested on 22.04/24.04 — proceeding, but expect rough edges."
      ;;
    *)
      die "Unsupported OS: ${PRETTY_NAME:-$ID $VERSION_ID}. This project targets Ubuntu 22.04/24.04."
      ;;
  esac
}

# Generates a random alphanumeric string of a given length.
rand_str() {
  local len="${1:-32}"
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len"
}

# sha256 of a string, hex-encoded (used for Graylog root_password_sha2 equivalent).
sha256_of() {
  printf '%s' "$1" | sha256sum | cut -d' ' -f1
}

# Waits until a URL returns any HTTP response (not necessarily 2xx) — used to
# detect "container is at least accepting connections" before hammering it
# with real requests.
wait_for_http() {
  local url="$1" timeout="${2:-180}" waited=0
  log "Waiting for $url to respond (timeout ${timeout}s)..."
  until curl -fsS -o /dev/null -w '%{http_code}' "$url" 2>/dev/null | grep -qE '^[0-9]+$'; do
    sleep 5
    waited=$((waited + 5))
    [ "$waited" -ge "$timeout" ] && die "Timed out waiting for $url"
  done
  log "$url is responding."
}

# Interactive picker used in agent mode when --agents isn't passed.
prompt_agent_selection() {
  local selected=()
  echo "Which additional tools should run on this host? (Vector is always installed.)" >&2

  read -rp "Install Rustinel (EDR: Sigma+YARA+IOC on process/network events)? [y/N] " a
  [[ "$a" =~ ^[Yy]$ ]] && selected+=("rustinel")

  if has_cmd docker; then
    read -rp "Install Falco (container/syscall runtime security — Docker detected)? [y/N] " a
    [[ "$a" =~ ^[Yy]$ ]] && selected+=("falco")
  else
    echo "  (Docker not detected on this host — skipping Falco prompt, it's built for container workloads.)" >&2
  fi

  read -rp "Install Sysmon for Linux (Sysmon-schema process/network/file telemetry)? [y/N] " a
  [[ "$a" =~ ^[Yy]$ ]] && selected+=("sysmon")

  local IFS=','
  echo "${selected[*]}"
}
