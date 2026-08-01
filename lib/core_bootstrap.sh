#!/usr/bin/env bash
# threadline :: lib/core_bootstrap.sh
# Brings up Graylog (Docker Compose) + MISP (official misp-docker project)
# on this host, then wires the two together.

ENV_FILE="/opt/threadline/.env"
MISP_DIR="/opt/threadline/docker/misp-docker"

generate_secrets_if_missing() {
  local root_dir="$1"

  if [ ! -f "$ENV_FILE" ]; then
    log "No .env found, creating one from .env.example with generated secrets..."
    cp "$root_dir/.env.example" "$ENV_FILE"
  fi

  # shellcheck source=/dev/null
  source "$ENV_FILE"

  local local_ip
  local_ip="$(hostname -I | awk '{print $1}')"

  set_env_var() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "$ENV_FILE"; then
      sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
    else
      echo "${key}=${value}" >> "$ENV_FILE"
    fi
  }

  [ -z "${GRAYLOG_ROOT_PASSWORD:-}" ] && { GRAYLOG_ROOT_PASSWORD="$(rand_str 20)"; set_env_var GRAYLOG_ROOT_PASSWORD "$GRAYLOG_ROOT_PASSWORD"; }
  set_env_var GRAYLOG_ROOT_PASSWORD_SHA2 "$(sha256_of "$GRAYLOG_ROOT_PASSWORD")"
  [ -z "${GRAYLOG_PASSWORD_SECRET:-}" ] && set_env_var GRAYLOG_PASSWORD_SECRET "$(rand_str 96)"
  set_env_var GRAYLOG_HTTP_EXTERNAL_URI "http://${local_ip}:9000/"
  [ -z "${OPENSEARCH_INITIAL_ADMIN_PASSWORD:-}" ] && set_env_var OPENSEARCH_INITIAL_ADMIN_PASSWORD "$(rand_password 20)"

  [ -z "${MISP_ADMIN_PASSWORD:-}" ]     && set_env_var MISP_ADMIN_PASSWORD "$(rand_str 24)"
  [ -z "${MISP_MYSQL_ROOT_PASSWORD:-}" ] && set_env_var MISP_MYSQL_ROOT_PASSWORD "$(rand_str 24)"
  [ -z "${MISP_MYSQL_PASSWORD:-}" ]     && set_env_var MISP_MYSQL_PASSWORD "$(rand_str 24)"
  [ -z "${MISP_REDIS_PASSWORD:-}" ]     && set_env_var MISP_REDIS_PASSWORD "$(rand_str 24)"
  [ -z "${MISP_GPG_PASSPHRASE:-}" ]     && set_env_var MISP_GPG_PASSPHRASE "$(rand_str 24)"
  set_env_var MISP_BASE_URL "https://${local_ip}"

  chmod 600 "$ENV_FILE"
  log "Secrets ready in $ENV_FILE (chmod 600 — back this file up somewhere safe)."

  # shellcheck source=/dev/null
  source "$ENV_FILE"
}

preflight_check_avx() {
  # MongoDB 5.0+ (used by the Graylog stack) hard-requires AVX and will
  # crash-loop forever without it, cascading into "Graylog can't resolve
  # mongodb" DNS errors that look unrelated but aren't. On Proxmox VE this
  # bites almost everyone by default: Proxmox's default CPU types (kvm64,
  # or the newer x86-64-v2-AES baseline) deliberately exclude AVX for
  # migration compatibility. Fail loudly here instead of letting it
  # crash-loop silently for 20 minutes.
  if ! grep -qm1 '\bavx\b' /proc/cpuinfo; then
    die "$(cat <<'EOF'
This VM's CPU doesn't expose AVX, which MongoDB 5.0+ requires -- it will
crash-loop forever without it (you'll see "MongoDB 5.0+ requires a CPU
with AVX support" repeating in `docker compose logs`, and Graylog will
never come up because it can't get a stable connection to it).

Fix, on the Proxmox host (not inside this VM):
  1. Shut this VM down completely (not a guest reboot -- CPU type is a
     QEMU launch parameter, only applied on a fresh start).
  2. VM -> Hardware -> Processor -> Edit -> set Type to "host"
     (or any type that includes AVX, e.g. x86-64-v3 / IvyBridge or newer,
     if "host" isn't viable for your migration-compatibility needs).
  3. Start the VM and re-run this installer -- it's idempotent.
EOF
)"
  fi
}

start_graylog_stack() {
  local root_dir="$1"
  preflight_check_avx
  log "Starting Graylog stack (MongoDB + OpenSearch + Graylog)..."

  # Compose only auto-discovers a .env in the CURRENT directory, not the
  # compose file's directory -- symlink it in so `docker compose` commands
  # run manually from docker/ (e.g. `docker compose logs -f` for debugging)
  # pick up real values instead of warning "variable not set, defaulting
  # to blank string" and confusing whoever's debugging.
  ln -sf "$ENV_FILE" "$root_dir/docker/.env"

  docker compose --env-file "$ENV_FILE" -f "$root_dir/docker/graylog-compose.yml" up -d
  wait_for_http "http://localhost:9000/api" 300
  log "Graylog is up: http://$(hostname -I | awk '{print $1}'):9000  (user: admin / password: see .env GRAYLOG_ROOT_PASSWORD)"
}

start_misp_stack() {
  # shellcheck source=/dev/null
  source "$ENV_FILE"

  if [ ! -d "$MISP_DIR" ]; then
    log "Fetching official MISP/misp-docker project..."
    if has_cmd git; then
      git clone --depth 1 https://github.com/MISP/misp-docker.git "$MISP_DIR"
    else
      mkdir -p "$MISP_DIR"
      curl -fsSL https://github.com/MISP/misp-docker/archive/refs/heads/master.tar.gz | \
        tar -xz --strip-components=1 -C "$MISP_DIR"
    fi
  fi

  local misp_env="$MISP_DIR/.env"
  [ -f "$misp_env" ] || cp "$MISP_DIR/template.env" "$misp_env"

  set_misp_var() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "$misp_env"; then
      sed -i "s|^${key}=.*|${key}=${value}|" "$misp_env"
    else
      echo "${key}=${value}" >> "$misp_env"
    fi
  }

  set_misp_var BASE_URL "$MISP_BASE_URL"
  set_misp_var MYSQL_ROOT_PASSWORD "$MISP_MYSQL_ROOT_PASSWORD"
  set_misp_var MYSQL_PASSWORD "$MISP_MYSQL_PASSWORD"
  set_misp_var ADMIN_EMAIL "$MISP_ADMIN_EMAIL"
  set_misp_var ADMIN_PASSWORD "$MISP_ADMIN_PASSWORD"
  set_misp_var ADMIN_ORG "Homelab"
  set_misp_var GPG_PASSPHRASE "$MISP_GPG_PASSPHRASE"
  set_misp_var REDIS_PASSWORD "$MISP_REDIS_PASSWORD"

  log "Starting MISP stack (this pulls several GB of images on first run, be patient)..."
  (cd "$MISP_DIR" && docker compose pull && docker compose up -d)

  wait_for_http "https://localhost/users/login" 600 || warn "MISP health check timed out — check 'docker compose logs -f misp-core' in $MISP_DIR"
  log "MISP is up: https://$(hostname -I | awk '{print $1}')  (user: ${MISP_ADMIN_EMAIL} / password: see .env MISP_ADMIN_PASSWORD)"
}

import_graylog_content_pack() {
  local root_dir="$1"
  # shellcheck source=/dev/null
  source "$ENV_FILE"

  local pack_file="$root_dir/content-packs/graylog-threadline.json"
  [ -f "$pack_file" ] || { warn "Content pack not found at $pack_file, skipping."; return; }

  log "Importing Graylog content pack (GELF input, pipelines, dashboards)..."
  local auth="admin:${GRAYLOG_ROOT_PASSWORD}"

  local upload_response
  upload_response=$(curl -fsS -u "$auth" -X POST "http://localhost:9000/api/system/content_packs" \
    -H "Content-Type: application/json" -H "X-Requested-By: threadline" \
    --data-binary "@${pack_file}") || { warn "Content pack upload failed — you can import it manually via System > Content Packs in the UI."; return; }

  local pack_id pack_rev
  pack_id=$(echo "$upload_response"  | grep -o '"id":"[^"]*"'  | head -1 | cut -d'"' -f4)
  pack_rev=$(echo "$upload_response" | grep -o '"rev":[0-9]*' | head -1 | cut -d':' -f2)

  if [ -n "$pack_id" ] && [ -n "$pack_rev" ]; then
    curl -fsS -u "$auth" -X POST \
      "http://localhost:9000/api/system/content_packs/${pack_id}/${pack_rev}/installations" \
      -H "Content-Type: application/json" -H "X-Requested-By: threadline" \
      --data '{"parameters": {}, "comment": "installed by threadline bootstrap"}' \
      && log "Content pack installed." \
      || warn "Content pack uploaded but install call failed — finish it from System > Content Packs in the UI."
  else
    warn "Could not parse content pack ID from upload response — check http://<host>:9000/api/api-browser and finish the import manually if needed."
  fi
}

sync_misp_feeds() {
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  [ -z "${MISP_API_KEY:-}" ] && return   # nothing to do yet, message already shown by caller

  has_cmd jq || { apt-get update -y && apt-get install -y jq; }

  local misp_url="$MISP_BASE_URL"
  local auth="$MISP_API_KEY"

  log "Loading MISP's default feed metadata catalog (~50 OSINT feed definitions, added disabled)..."
  ( cd "$MISP_DIR" && docker compose exec -T misp-core /var/www/MISP/app/Console/cake Server loadDefaultFeeds ) \
    || warn "loadDefaultFeeds failed or already loaded -- continuing."

  log "Enabling curated default feeds: ${MISP_ENABLE_FEEDS}"
  local feeds_json
  feeds_json=$(curl -fsSk -H "Authorization: $auth" -H "Accept: application/json" "${misp_url}/feeds/index") \
    || { warn "Could not reach ${misp_url}/feeds/index -- skipping feed enable step."; return; }

  IFS=',' read -ra WANTED <<< "$MISP_ENABLE_FEEDS"
  for pattern in "${WANTED[@]}"; do
    local ids
    ids=$(echo "$feeds_json" | jq -r --arg p "$(echo "$pattern" | tr '[:upper:]' '[:lower:]')" \
      '.[] | .Feed | select((.name // "" | ascii_downcase) | contains($p)) | .id')
    for fid in $ids; do
      curl -fsSk -X POST -H "Authorization: $auth" -H "Accept: application/json" \
        "${misp_url}/feeds/enable/${fid}" >/dev/null \
        && log "  enabled feed id ${fid} (matched '${pattern}')"
    done
  done

  # Custom feeds not in MISP's own catalog (e.g. Rösti, or any private feed).
  # Format in .env, one entry per ';'-separated block: name|url|header_name:header_value
  # header part is optional -- omit it for feeds that don't need auth.
  if [ -n "${MISP_CUSTOM_FEEDS:-}" ]; then
    log "Adding custom feeds from MISP_CUSTOM_FEEDS..."
    IFS=';' read -ra CUSTOM <<< "$MISP_CUSTOM_FEEDS"
    for entry in "${CUSTOM[@]}"; do
      [ -z "$entry" ] && continue
      IFS='|' read -r fname furl fheader <<< "$entry"
      local headers_escaped="{}"
      if [ -n "$fheader" ]; then
        local hkey="${fheader%%:*}" hval="${fheader#*:}"
        headers_escaped=$(printf '{\\"%s\\":\\"%s\\"}' "$hkey" "$hval")
      fi
      curl -fsSk -X POST -H "Authorization: $auth" -H "Accept: application/json" -H "Content-Type: application/json" \
        "${misp_url}/feeds/add" \
        --data "{\"Feed\":{\"name\":\"${fname}\",\"provider\":\"custom\",\"url\":\"${furl}\",\"source_format\":\"misp\",\"enabled\":true,\"distribution\":\"0\",\"headers\":\"${headers_escaped}\"}}" \
        >/dev/null && log "  added custom feed '${fname}'" \
        || warn "  failed to add custom feed '${fname}' -- check the URL/format and add it manually via Sync Actions > Feeds if needed."
    done
  fi

  log "Triggering initial fetch (runs as a background MISP job, can take a while on first run)..."
  curl -fsSk -X POST -H "Authorization: $auth" -H "Accept: application/json" "${misp_url}/feeds/fetchFromAllFeeds" >/dev/null \
    || warn "Fetch trigger failed -- click 'Fetch and store all feed data' in the MISP UI instead."
}

link_misp_to_graylog() {
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  if [ -z "${MISP_API_KEY:-}" ]; then
    cat <<EOF

======================================================================
 One manual step left: MISP API key
======================================================================
 1. Log in to MISP: ${MISP_BASE_URL}  (${MISP_ADMIN_EMAIL} / see .env)
 2. Administration > List Auth Keys > Add authentication key
 3. Put the key in $ENV_FILE as MISP_API_KEY=...
 4. Re-run: sudo ./run.sh --role=core --link-misp
    (this wires the key into Graylog's MISP lookup table data adapter
    AND enables/fetches the feeds configured via MISP_ENABLE_FEEDS /
    MISP_CUSTOM_FEEDS in .env.example)
======================================================================
EOF
    return
  fi

  log "Wiring MISP API key into Graylog's lookup table data adapter..."
  local auth="admin:${GRAYLOG_ROOT_PASSWORD}"
  curl -fsS -u "$auth" -X PUT "http://localhost:9000/api/system/lookup/adapters/misp-adapter" \
    -H "Content-Type: application/json" -H "X-Requested-By: threadline" \
    --data "{\"config\":{\"headers\":{\"Authorization\":\"${MISP_API_KEY}\"}}}" \
    && log "MISP lookup table linked. Enrichment is now live in Graylog pipelines." \
    || warn "No 'misp-adapter' lookup table found yet — that's expected if you haven't done the one-time pipeline/lookup-table setup in README.md#post-install-graylog-setup. Do that first (it's a 5-minute, copy-pasteable UI walkthrough), then re-run --link-misp."

  sync_misp_feeds
}

bootstrap_core() {
  local root_dir="$1"
  generate_secrets_if_missing "$root_dir"
  start_graylog_stack "$root_dir"
  start_misp_stack
  import_graylog_content_pack "$root_dir"
  link_misp_to_graylog

  cat <<EOF

======================================================================
 threadline core is up
======================================================================
 Graylog : http://$(hostname -I | awk '{print $1}'):9000   (admin / see .env)
 MISP    : ${MISP_BASE_URL}   (see .env)

 One more manual step for AI/LLM telemetry (Claude Code, Cowork):
   Graylog UI -> System -> Inputs -> select "OpenTelemetry (gRPC)" -> Launch
   new input -> bind address 0.0.0.0, port 4318 (NOT 4317 -- that's the
   otel-collector container's own listening port, already running and
   reachable at $(hostname -I | awk '{print $1}'):4317 for Claude Code to
   point at). See docs/ai-agent-telemetry.md for the full walkthrough.

 Next: install agents on the VMs you want monitored:
   curl -fsSL https://raw.githubusercontent.com/R4z1xx/threadline/main/install.sh \\
     | sudo bash -s -- --role=agent --graylog=$(hostname -I | awk '{print $1}')
======================================================================
EOF
}
