#!/usr/bin/env bash
# threadline :: lib/agent_atr.sh
# Installs ATR (agent-threat-rules -- https://agentthreatrule.org), a
# Sigma-equivalent detection standard for AI agent security: prompt
# injection, tool poisoning, malicious MCP skills/configs, agent
# manipulation. Only meaningful on hosts that actually run AI agent
# tooling (Claude Code, MCP servers, LangChain-style agent frameworks,
# n8n AI nodes, etc.) -- offered as an opt-in prompt, not installed by
# default.
#
# Unlike Rustinel/Falco, ATR has no live event-stream mode for this use
# case -- it's a static scanner. We run it on a timer against configured
# paths, flatten the SARIF output to NDJSON, and let Vector tail it, same
# shape as every other agent's alert pipeline.

ATR_SCAN_INTERVAL="${ATR_SCAN_INTERVAL:-15min}"   # systemd OnCalendar/OnUnitActiveSec value
ATR_FINDINGS_LOG="/opt/threadline-atr-findings.ndjson"
ATR_SCAN_SCRIPT="/opt/threadline-atr-scan.sh"

install_nodejs_if_missing() {
  has_cmd node && has_cmd npm && return
  log "Installing Node.js (required for the ATR CLI)..."
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
  apt-get install -y nodejs
}

install_atr() {
  local root_dir="$1"

  if [ -z "${ATR_SCAN_PATHS:-}" ]; then
    warn "ATR_SCAN_PATHS is not set -- nothing to scan, skipping ATR install."
    warn "Example: export ATR_SCAN_PATHS=\"/root/.claude/skills,/opt/mcp-servers\""
    warn "Then re-run the agent installer with --agents=atr (or include it in your selection)."
    return
  fi

  install_nodejs_if_missing
  has_cmd jq || { apt-get update -y && apt-get install -y jq; }

  if ! has_cmd atr; then
    log "Installing agent-threat-rules CLI globally..."
    npm install -g agent-threat-rules
  else
    log "ATR CLI already installed, checking for updates..."
    npm update -g agent-threat-rules
  fi

  log "ATR version: $(atr --version 2>/dev/null || echo unknown)"

  cat > "$ATR_SCAN_SCRIPT" <<EOF
#!/usr/bin/env bash
# Runs on a timer -- see threadline-atr-scan.timer. Flattens SARIF output
# from each configured path into one NDJSON line per finding, appended to
# ${ATR_FINDINGS_LOG} for Vector to tail.
set -euo pipefail
IFS=',' read -ra PATHS <<< "${ATR_SCAN_PATHS}"
ts="\$(date -u +%FT%TZ)"
for p in "\${PATHS[@]}"; do
  [ -e "\$p" ] || continue
  sarif_out="\$(atr scan "\$p" --sarif 2>/dev/null || echo '{"runs":[]}')"
  echo "\$sarif_out" | jq -c --arg scanned_path "\$p" --arg ts "\$ts" \\
    '.runs[]?.results[]? | {timestamp:\$ts, scanned_path:\$scanned_path, source_tool:"atr", rule_id:.ruleId, message:.message.text, level:.level, locations:.locations}' \\
    >> "${ATR_FINDINGS_LOG}" 2>/dev/null || true
done
EOF
  chmod +x "$ATR_SCAN_SCRIPT"
  touch "$ATR_FINDINGS_LOG"

  cat > /etc/systemd/system/threadline-atr-scan.service <<EOF
[Unit]
Description=ThreadLine ATR scan (AI agent threat detection)

[Service]
Type=oneshot
ExecStart=${ATR_SCAN_SCRIPT}
EOF

  cat > /etc/systemd/system/threadline-atr-scan.timer <<EOF
[Unit]
Description=Run ThreadLine ATR scan periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=${ATR_SCAN_INTERVAL}
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now threadline-atr-scan.timer

  cat > /etc/vector/conf.d/12-atr.toml <<EOF
[sources.atr_raw]
type = "file"
include = ["${ATR_FINDINGS_LOG}"]
line_delimiter = "\n"

[transforms.shipped_atr]
type = "remap"
inputs = ["atr_raw"]
source = '''
. = parse_json!(.message)
'''
EOF

  systemctl restart vector 2>/dev/null || true
  log "ATR installed. Scanning ${ATR_SCAN_PATHS} every ${ATR_SCAN_INTERVAL}, findings ship to Graylog with source_tool=atr."
  log "Run 'sudo systemctl start threadline-atr-scan.service' to trigger a scan immediately instead of waiting for the timer."
}