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

create_gelf_input() {
  # Was previously done via a content pack, which turned out to be
  # persistently fragile across Graylog versions -- a missing required
  # "constraints" field, an "already found" duplicate-upload error, and
  # finally a broken details-viewer page that also revealed the input
  # never actually got created. Content packs are the wrong tool for
  # "create one static input" -- this uses Graylog's plain Inputs API
  # directly instead. Fewer moving parts, no nested version-sensitive
  # schema, and it's the same API System > Inputs > Launch new input
  # calls under the hood in the UI.
  # shellcheck source=/dev/null
  source "$ENV_FILE"

  log "Creating Graylog GELF UDP input..."
  local auth="admin:${GRAYLOG_ROOT_PASSWORD}"

  # Idempotent: check for an existing input with our title before creating
  # a duplicate on every re-run (Graylog doesn't enforce title uniqueness,
  # so without this check a second run would try to bind 12201/udp twice).
  local existing
  existing=$(curl -sS -u "$auth" "http://localhost:9000/api/system/inputs" 2>/dev/null \
    | grep -o '"title": *"threadline GELF UDP"') || true
  if [ -n "$existing" ]; then
    log "GELF UDP input already exists, skipping."
    return
  fi

  local create_raw create_status create_body
  create_raw=$(curl -sS -w '\n%{http_code}' -u "$auth" -X POST "http://localhost:9000/api/system/inputs" \
    -H "Content-Type: application/json" -H "X-Requested-By: threadline" \
    --data '{
      "title": "threadline GELF UDP",
      "type": "org.graylog2.inputs.gelf.udp.GELFUDPInput",
      "global": true,
      "configuration": {
        "bind_address": "0.0.0.0",
        "port": 12201,
        "recv_buffer_size": 262144,
        "decompress_size_limit": 8388608
      }
    }') || true
  create_status=$(echo "$create_raw" | tail -n1)
  create_body=$(echo "$create_raw" | sed '$d')

  if [ "$create_status" -ge 200 ] && [ "$create_status" -lt 300 ]; then
    log "GELF UDP input created and running on 0.0.0.0:12201/udp."
  else
    warn "GELF UDP input creation failed (HTTP ${create_status}): ${create_body}"
    warn "Manual fallback: System > Inputs > select 'GELF UDP' > Launch new input, bind 0.0.0.0:12201/udp."
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

trust_misp_cert_in_graylog() {
  # Graylog's JVM has its own trust store, separate from curl/OpenSSL --
  # it won't trust MISP's self-signed cert by default, which surfaces as
  # "HTTP data adapter lookup failure ... None of the TrustManagers trust
  # this certificate chain" once the lookup adapter starts querying MISP.
  # This import lives in the container's writable layer, so it's wiped
  # on any container recreate (docker compose down/up, image update) --
  # that's exactly why this runs every time rather than once: the
  # idempotency check below naturally re-imports after a wipe and no-ops
  # when nothing changed.
  local misp_host
  misp_host=$(echo "$MISP_BASE_URL" | sed -E 's~^https?://~~; s~/.*~~; s~:.*~~')
  [ -z "$misp_host" ] && { warn "Could not parse a hostname out of MISP_BASE_URL, skipping cert trust step."; return; }

  log "Fetching MISP's TLS certificate..."
  local cert_file="/tmp/misp-cert.pem"
  timeout 10 bash -c "echo | openssl s_client -connect '${misp_host}:443' -servername '${misp_host}' 2>/dev/null | openssl x509" > "$cert_file" 2>/dev/null || true

  if [ ! -s "$cert_file" ]; then
    warn "Could not retrieve MISP's certificate from ${misp_host}:443 -- skipping trust store import."
    warn "The MISP lookup adapter may fail with a TLS trust error until this is done manually (see docs/graylog-pipelines.md)."
    return
  fi

  log "Locating Graylog's JVM trust store..."
  local cacerts_path
  # Prefer the trust store the running Graylog JVM actually uses (via its
  # own JAVA_HOME) over a blind `find`, which can turn up more than one
  # cacerts file in a JVM-based image and pick the wrong one.
  cacerts_path=$(docker exec soc-graylog sh -c '[ -n "$JAVA_HOME" ] && [ -f "$JAVA_HOME/lib/security/cacerts" ] && echo "$JAVA_HOME/lib/security/cacerts"' 2>/dev/null) || true
  if [ -z "$cacerts_path" ]; then
    cacerts_path=$(docker exec soc-graylog find / -name cacerts 2>/dev/null | head -1) || true
  fi

  if [ -z "$cacerts_path" ]; then
    warn "Could not locate cacerts inside the Graylog container -- skipping trust store import."
    warn "The MISP lookup adapter may fail with a TLS trust error until this is done manually (see docs/graylog-pipelines.md)."
    return
  fi

  # Idempotent: skip re-importing (and skip the restart) if this exact
  # cert is already trusted -- keytool -list also returns non-zero if the
  # alias exists but the underlying cert changed (e.g. MISP's cert got
  # regenerated), so this correctly re-triggers an import in that case too.
  if docker exec soc-graylog keytool -list -keystore "$cacerts_path" -storepass changeit -alias misp-selfsigned >/dev/null 2>&1; then
    log "MISP certificate already trusted by Graylog."
    return
  fi

  log "Importing MISP's certificate into Graylog's trust store..."
  docker cp "$cert_file" soc-graylog:/tmp/misp-cert.pem
  # -u root: the official Graylog image runs as a non-root user by default,
  # and cacerts is typically root-owned/read-only to that user -- keytool
  # needs write access to add an entry. Read-only checks above (-list)
  # don't need this since cacerts is normally world-readable.
  local import_output
  if import_output=$(docker exec -u root soc-graylog keytool -importcert -noprompt -trustcacerts \
      -keystore "$cacerts_path" -storepass changeit \
      -alias misp-selfsigned -file /tmp/misp-cert.pem 2>&1); then
    log "Certificate imported. Restarting Graylog to apply..."
    docker restart soc-graylog >/dev/null
    wait_for_http "http://localhost:9000/api" 180
  else
    warn "Failed to import MISP's certificate into Graylog's trust store: ${import_output}"
    warn "Manual fallback: see docs/graylog-pipelines.md."
  fi
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
    Everything else (Graylog trusting MISP's TLS cert, the data adapter,
    cache, lookup table, and enrichment pipeline) is created automatically
    once the key is set -- see docs/graylog-pipelines.md if you'd rather
    do it by hand instead, or if any of the automated steps below warn
    and need a manual finish.
======================================================================
EOF
    return
  fi

  has_cmd python3 || { apt-get update -y && apt-get install -y python3; }

  local auth="admin:${GRAYLOG_ROOT_PASSWORD}"
  local misp_url="$MISP_BASE_URL"
  local cache_ttl="${MISP_LOOKUP_CACHE_TTL_SECONDS:-43200}"

  trust_misp_cert_in_graylog
  create_misp_data_adapter "$auth" "$misp_url" "$MISP_API_KEY"
  create_misp_cache "$auth" "$cache_ttl"
  create_misp_lookup_table "$auth"
  create_misp_pipeline "$auth"

  sync_misp_feeds
}

# ---- MISP lookup table + enrichment pipeline automation ----
#
# Each step below is idempotent (checks for an existing entity by its
# fixed `name` before creating) and non-fatal (a failure warns with the
# real HTTP status/body and a manual fallback, then continues to the next
# step rather than aborting the whole chain). These schemas are Graylog's
# plain Lookup Table / Pipeline REST API -- not content packs, which
# proved too version-fragile earlier in this project -- but they're
# genuinely more complex than the single flat GELF input object, so
# treat any warning here as a real possibility, not just defensive
# boilerplate: verify in the UI if you see one.

misp_adapter_json() {
  local misp_url="$1" misp_api_key="$2"
  python3 -c "
import json, sys
print(json.dumps({
  'title': 'threadline MISP Adapter',
  'description': 'Auto-created by threadline',
  'name': 'misp-adapter',
  'config': {
    'type': 'httpjsonpath',
    'url': sys.argv[1] + '/attributes/restSearch/\${key}',
    'headers': {'Authorization': sys.argv[2], 'Accept': 'application/json'},
    'single_value_jsonpath': '\$.response.Attribute[0].value',
    'multi_value_jsonpath': '\$.response.Attribute[*].value',
    'http_method': 'GET',
    'body_template': '',
    'content_type': 'JSON',
    'http_error_reason_regex': '',
    'http_timeout_ms': 5000,
    'http_max_concurrent_requests': 2,
    'http_user_agent': 'threadline',
    'preferred_types': ['STRING'],
  },
}))
" "$misp_url" "$misp_api_key"
}

create_misp_data_adapter() {
  local auth="$1" misp_url="$2" misp_api_key="$3"
  local existing_status
  existing_status=$(curl -sSk -o /dev/null -w '%{http_code}' -u "$auth" \
    "http://localhost:9000/api/system/lookup/adapters/misp-adapter") || true

  local body
  body=$(misp_adapter_json "$misp_url" "$misp_api_key")

  if [ "$existing_status" = "200" ]; then
    log "MISP data adapter already exists, updating its API key..."
    curl -sSk -u "$auth" -X PUT "http://localhost:9000/api/system/lookup/adapters/misp-adapter" \
      -H "Content-Type: application/json" -H "X-Requested-By: threadline" \
      --data "$body" >/dev/null \
      && log "MISP data adapter updated." \
      || warn "Failed to update MISP data adapter -- check System > Lookup Tables > Data Adapters > misp-adapter."
    return
  fi

  log "Creating MISP data adapter..."
  local create_raw create_status create_body
  create_raw=$(curl -sSk -w '\n%{http_code}' -u "$auth" -X POST "http://localhost:9000/api/system/lookup/adapters" \
    -H "Content-Type: application/json" -H "X-Requested-By: threadline" \
    --data "$body")
  create_status=$(echo "$create_raw" | tail -n1)
  create_body=$(echo "$create_raw" | sed '$d')

  if [ "$create_status" -ge 200 ] && [ "$create_status" -lt 300 ]; then
    log "MISP data adapter created."
  else
    warn "MISP data adapter creation failed (HTTP ${create_status}): ${create_body}"
    warn "Manual fallback: System > Lookup Tables > Data Adapters > Create data adapter -- see docs/graylog-pipelines.md."
  fi
}

create_misp_cache() {
  local auth="$1" ttl_seconds="$2"
  local existing_status
  existing_status=$(curl -sSk -o /dev/null -w '%{http_code}' -u "$auth" \
    "http://localhost:9000/api/system/lookup/caches/misp-cache") || true
  if [ "$existing_status" = "200" ]; then
    log "MISP lookup cache already exists."
    return
  fi

  log "Creating MISP lookup cache (TTL ${ttl_seconds}s)..."
  local create_raw create_status create_body
  create_raw=$(curl -sSk -w '\n%{http_code}' -u "$auth" -X POST "http://localhost:9000/api/system/lookup/caches" \
    -H "Content-Type: application/json" -H "X-Requested-By: threadline" \
    --data "{
      \"title\": \"threadline MISP Cache\",
      \"description\": \"Auto-created by threadline\",
      \"name\": \"misp-cache\",
      \"config\": {
        \"type\": \"guava_cache\",
        \"max_size\": 1000,
        \"expire_after_access\": ${ttl_seconds},
        \"expire_after_access_unit\": \"SECONDS\",
        \"expire_after_write\": ${ttl_seconds},
        \"expire_after_write_unit\": \"SECONDS\"
      }
    }")
  create_status=$(echo "$create_raw" | tail -n1)
  create_body=$(echo "$create_raw" | sed '$d')

  if [ "$create_status" -ge 200 ] && [ "$create_status" -lt 300 ]; then
    log "MISP lookup cache created."
  else
    warn "MISP lookup cache creation failed (HTTP ${create_status}): ${create_body}"
    warn "Manual fallback: System > Lookup Tables > Caches > Create cache -- see docs/graylog-pipelines.md."
  fi
}

get_lookup_entity_id() {
  # $1 = auth, $2 = "adapters" or "caches", $3 = name
  local auth="$1" endpoint="$2" name="$3"
  local body
  body=$(curl -sSk -u "$auth" "http://localhost:9000/api/system/lookup/${endpoint}/${name}") || true
  echo "$body" | grep -o '"id": *"[^"]*"' | head -1 | sed 's/.*"id": *"\([^"]*\)"/\1/' || true
}

create_misp_lookup_table() {
  local auth="$1"
  local existing_status
  existing_status=$(curl -sSk -o /dev/null -w '%{http_code}' -u "$auth" \
    "http://localhost:9000/api/system/lookup/tables/misp_ioc_lookup") || true
  if [ "$existing_status" = "200" ]; then
    log "MISP lookup table already exists."
    return
  fi

  local adapter_id cache_id
  adapter_id=$(get_lookup_entity_id "$auth" "adapters" "misp-adapter")
  cache_id=$(get_lookup_entity_id "$auth" "caches" "misp-cache")

  if [ -z "$adapter_id" ] || [ -z "$cache_id" ]; then
    warn "Could not determine adapter/cache ID -- skipping lookup table creation."
    warn "Manual fallback: System > Lookup Tables > Create lookup table -- see docs/graylog-pipelines.md."
    return
  fi

  log "Creating MISP lookup table..."
  local create_raw create_status create_body
  create_raw=$(curl -sSk -w '\n%{http_code}' -u "$auth" -X POST "http://localhost:9000/api/system/lookup/tables" \
    -H "Content-Type: application/json" -H "X-Requested-By: threadline" \
    --data "{
      \"title\": \"threadline MISP IOC Lookup\",
      \"description\": \"Auto-created by threadline\",
      \"name\": \"misp_ioc_lookup\",
      \"cache_id\": \"${cache_id}\",
      \"data_adapter_id\": \"${adapter_id}\",
      \"default_single_value\": \"\",
      \"default_single_value_type\": \"NULL\",
      \"default_multi_value\": \"\",
      \"default_multi_value_type\": \"NULL\"
    }")
  create_status=$(echo "$create_raw" | tail -n1)
  create_body=$(echo "$create_raw" | sed '$d')

  if [ "$create_status" -ge 200 ] && [ "$create_status" -lt 300 ]; then
    log "MISP lookup table created."
  else
    warn "MISP lookup table creation failed (HTTP ${create_status}): ${create_body}"
    warn "Manual fallback: System > Lookup Tables > Create lookup table -- see docs/graylog-pipelines.md."
  fi
}

create_misp_pipeline() {
  local auth="$1"

  local rule_exists
  rule_exists=$(curl -sSk -u "$auth" "http://localhost:9000/api/system/pipelines/rule" 2>/dev/null \
    | grep -o '"title": *"enrich src_ip with MISP"') || true

  if [ -z "$rule_exists" ]; then
    log "Creating MISP enrichment pipeline rule..."
    local rule_source rule_json create_raw create_status create_body
    rule_source=$(cat <<'RULE'
rule "enrich src_ip with MISP"
when
  has_field("src_ip")
then
  let result = lookup("misp_ioc_lookup", to_string($message.src_ip));
  set_field("misp_match", result["value"]);
  set_field("misp_event_id", result["event_id"]);
  set_field("misp_tags", result["tags"]);
end
RULE
)
    rule_json=$(python3 -c "
import json, sys
print(json.dumps({'title': 'enrich src_ip with MISP', 'description': 'Auto-created by threadline', 'source': sys.argv[1]}))
" "$rule_source")

    create_raw=$(curl -sSk -w '\n%{http_code}' -u "$auth" -X POST "http://localhost:9000/api/system/pipelines/rule" \
      -H "Content-Type: application/json" -H "X-Requested-By: threadline" \
      --data "$rule_json")
    create_status=$(echo "$create_raw" | tail -n1)
    create_body=$(echo "$create_raw" | sed '$d')

    if [ "$create_status" -ge 200 ] && [ "$create_status" -lt 300 ]; then
      log "Pipeline rule created."
    else
      warn "Pipeline rule creation failed (HTTP ${create_status}): ${create_body}"
      warn "Manual fallback: docs/graylog-pipelines.md has the copy-paste rule DSL."
      return
    fi
  else
    log "Pipeline rule already exists."
  fi

  local pipelines_json pipeline_id
  pipelines_json=$(curl -sSk -u "$auth" "http://localhost:9000/api/system/pipelines/pipeline") || true
  pipeline_id=$(echo "$pipelines_json" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
for p in data:
    if p.get('title') == 'threadline MISP enrichment':
        print(p.get('id', ''))
        break
" 2>/dev/null) || true

  if [ -z "$pipeline_id" ]; then
    log "Creating MISP enrichment pipeline..."
    local pipeline_source pipeline_json create_raw create_status create_body
    pipeline_source='pipeline "threadline MISP enrichment"
stage 0 match either
  rule "enrich src_ip with MISP";
end'
    pipeline_json=$(python3 -c "
import json, sys
print(json.dumps({'title': 'threadline MISP enrichment', 'description': 'Auto-created by threadline', 'source': sys.argv[1]}))
" "$pipeline_source")

    create_raw=$(curl -sSk -w '\n%{http_code}' -u "$auth" -X POST "http://localhost:9000/api/system/pipelines/pipeline" \
      -H "Content-Type: application/json" -H "X-Requested-By: threadline" \
      --data "$pipeline_json")
    create_status=$(echo "$create_raw" | tail -n1)
    create_body=$(echo "$create_raw" | sed '$d')

    if [ "$create_status" -ge 200 ] && [ "$create_status" -lt 300 ]; then
      pipeline_id=$(echo "$create_body" | grep -o '"id": *"[^"]*"' | head -1 | sed 's/.*"id": *"\([^"]*\)"/\1/') || true
      log "Pipeline created."
    else
      warn "Pipeline creation failed (HTTP ${create_status}): ${create_body}"
      warn "Manual fallback: docs/graylog-pipelines.md has the setup steps."
      return
    fi
  else
    log "Pipeline already exists."
  fi

  if [ -z "$pipeline_id" ]; then
    warn "Could not determine pipeline ID -- skipping stream connection. Connect it manually: System > Pipelines > (find pipeline) > Edit connections."
    return
  fi

  log "Connecting pipeline to the default stream..."
  # "000000000000000000000001" is Graylog's fixed, well-known ID for the
  # built-in "All messages" default stream -- stable across versions.
  curl -sSk -u "$auth" -X POST "http://localhost:9000/api/system/pipelines/connections/to_stream" \
    -H "Content-Type: application/json" -H "X-Requested-By: threadline" \
    --data "{\"stream_id\": \"000000000000000000000001\", \"pipeline_ids\": [\"${pipeline_id}\"]}" >/dev/null \
    && log "Pipeline connected to default stream." \
    || warn "Could not connect pipeline to stream -- do it manually: System > Pipelines > (find pipeline) > Edit connections."
}

bootstrap_core() {
  local root_dir="$1"
  generate_secrets_if_missing "$root_dir"
  start_graylog_stack "$root_dir"
  start_misp_stack
  create_gelf_input "$root_dir"
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
