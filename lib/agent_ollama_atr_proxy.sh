#!/usr/bin/env bash
# threadline :: lib/agent_ollama_atr_proxy.sh
# Installs the Ollama ATR logging/enforcement proxy (docker/ollama-atr-proxy/)
# on this host. Point n8n's Ollama/HTTP node at OLLAMA_ATR_PROXY_PORT instead
# of Ollama's native port -- everything else is transparent pass-through.
#
# Only meaningful on hosts actually running Ollama. Opt-in, same pattern as
# lib/agent_atr.sh.

PROXY_DIR="/opt/threadline-ollama-atr-proxy"
OLLAMA_UPSTREAM="${OLLAMA_UPSTREAM:-http://127.0.0.1:11434}"
OLLAMA_ATR_PROXY_PORT="${OLLAMA_ATR_PROXY_PORT:-11500}"
OLLAMA_ATR_MODE="${OLLAMA_ATR_MODE:-alert}"   # "alert" or "enforce"
OLLAMA_ATR_FINDINGS_LOG="/opt/threadline-ollama-atr-findings.ndjson"

install_ollama_atr_proxy() {
  local root_dir="$1"

  install_nodejs_if_missing   # shared helper, see lib/common.sh

  log "Installing Ollama ATR proxy to ${PROXY_DIR}..."
  mkdir -p "$PROXY_DIR"
  cp -f "$root_dir/docker/ollama-atr-proxy/package.json" "$PROXY_DIR/"
  cp -f "$root_dir/docker/ollama-atr-proxy/package-lock.json" "$PROXY_DIR/"
  cp -f "$root_dir/docker/ollama-atr-proxy/server.js" "$PROXY_DIR/"

  ( cd "$PROXY_DIR" && npm ci --omit=dev --no-audit --no-fund )

  touch "$OLLAMA_ATR_FINDINGS_LOG"

  cat > /etc/systemd/system/threadline-ollama-atr-proxy.service <<EOF
[Unit]
Description=ThreadLine Ollama ATR proxy
After=network.target

[Service]
Type=simple
WorkingDirectory=${PROXY_DIR}
Environment=OLLAMA_UPSTREAM=${OLLAMA_UPSTREAM}
Environment=PROXY_PORT=${OLLAMA_ATR_PROXY_PORT}
Environment=ATR_MODE=${OLLAMA_ATR_MODE}
Environment=ATR_FINDINGS_LOG=${OLLAMA_ATR_FINDINGS_LOG}
ExecStart=/usr/bin/node ${PROXY_DIR}/server.js
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now threadline-ollama-atr-proxy

  cat > /etc/vector/conf.d/13-ollama-atr.toml <<EOF
[sources.ollama_atr_raw]
type = "file"
include = ["${OLLAMA_ATR_FINDINGS_LOG}"]
line_delimiter = "\n"

[transforms.shipped_ollama_atr]
type = "remap"
inputs = ["ollama_atr_raw"]
source = '''
. = parse_json!(.message)
'''
EOF

  systemctl restart vector 2>/dev/null || true

  log "Ollama ATR proxy installed: listening on :${OLLAMA_ATR_PROXY_PORT}, forwarding to ${OLLAMA_UPSTREAM}, mode=${OLLAMA_ATR_MODE}."
  log "Point n8n's Ollama/HTTP node at http://<this-host>:${OLLAMA_ATR_PROXY_PORT} instead of the Ollama port directly."
  [ "$OLLAMA_ATR_MODE" = "alert" ] && log "Running in alert mode (log-only). Set OLLAMA_ATR_MODE=enforce before install to block high/critical matches instead."
}
