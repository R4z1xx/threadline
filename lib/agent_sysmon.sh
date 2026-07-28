#!/usr/bin/env bash
# threadline :: lib/agent_sysmon.sh
# Installs Sysmon for Linux (Microsoft/Sysinternals) and syncs the real
# microsoft/MSTIC-Sysmon config -- not a hand-rolled placeholder.
#
# MSTIC-Sysmon's linux/configs/ ships:
#   attack-based/<tactic>/<TID>_Name.xml  -- one XML snippet per ATT&CK
#                                             technique (dozens of them)
#   main.xml       -- all attack-based snippets merged into one
#                      inclusion-only ruleset (the sane default)
#   collect-all.xml -- no filtering, logs everything Sysmon can see
#                      (heavier, useful for active threat-hunting labs)
#
# Events land in journald/syslog and are picked up by Vector's always-on
# journald source (see agent_vector.sh) -- no dedicated Vector fragment
# needed.

MSTIC_SYSMON_REPO="${MSTIC_SYSMON_REPO:-https://github.com/microsoft/MSTIC-Sysmon.git}"
# Override to "collect-all.xml" for maximum verbosity instead of the curated
# ATT&CK-technique-based default:
#   export MSTIC_SYSMON_CONFIG="collect-all.xml"
MSTIC_SYSMON_CONFIG="${MSTIC_SYSMON_CONFIG:-main.xml}"

sync_mstic_config() {
  local checkout="/opt/homelab-soc-cache/mstic-sysmon"
  mkdir -p /opt/homelab-soc-cache

  log "Syncing MSTIC-Sysmon config (${MSTIC_SYSMON_CONFIG})..."
  if [ ! -d "$checkout/.git" ]; then
    git clone --filter=blob:none --sparse --depth 1 "$MSTIC_SYSMON_REPO" "$checkout"
    ( cd "$checkout" && git sparse-checkout set linux/configs )
  else
    ( cd "$checkout" && git pull --ff-only )
  fi

  local src="$checkout/linux/configs/${MSTIC_SYSMON_CONFIG}"
  [ -f "$src" ] || die "Expected config not found at $src -- check MSTIC_SYSMON_CONFIG value or upstream repo layout."
  cp "$src" /opt/threadline-sysmon-config.xml
}

install_sysmon() {
  local root_dir="$1"

  has_cmd git || { apt-get update -y && apt-get install -y git; }

  if has_cmd sysmon; then
    log "Sysmon for Linux already installed, skipping package install (config will still be refreshed)."
  else
    log "Installing Sysmon for Linux..."
    # shellcheck source=/dev/null
    source /etc/os-release
    curl -fsSL "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb" \
      -o /tmp/packages-microsoft-prod.deb
    dpkg -i /tmp/packages-microsoft-prod.deb
    rm -f /tmp/packages-microsoft-prod.deb
    apt-get update -y
    apt-get install -y sysinternalsebpf sysmonforlinux
  fi

  sync_mstic_config

  # First install needs -i (install + config); subsequent config refreshes
  # on an already-installed service use -c (update config only).
  if systemctl is-active --quiet sysmon 2>/dev/null; then
    sysmon -accepteula -c /opt/threadline-sysmon-config.xml
  else
    sysmon -accepteula -i /opt/threadline-sysmon-config.xml
  fi

  systemctl enable --now sysmon
  log "Sysmon for Linux installed with MSTIC-Sysmon's ${MSTIC_SYSMON_CONFIG}."
  log "Events land in journald and are already shipped by Vector's base journald source."
  log "Tip: run 'sudo grep -i sysmon /var/log/syslog' to confirm events are flowing before checking Graylog."
}
