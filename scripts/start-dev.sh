#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/looloo-dev-${UID}"
API_DIR="$ROOT_DIR/looloo-api"
CHATBOT_DIR="$ROOT_DIR/chatbot-api"
WEB_DIR="$ROOT_DIR/looloo-web"

for command in node npm setsid ss ps; do
  command -v "$command" >/dev/null 2>&1 || { printf 'Required command not found: %s\n' "$command" >&2; exit 1; }
done
for file in "$API_DIR/.env" "$CHATBOT_DIR/.env"; do
  [[ -f "$file" ]] || { printf 'Missing %s\n' "$file" >&2; exit 1; }
done
for directory in "$API_DIR/node_modules" "$CHATBOT_DIR/node_modules" "$WEB_DIR/node_modules" "$ROOT_DIR/looloo-assistant/node_modules"; do
  [[ -d "$directory" ]] || { printf 'Dependencies are not installed in %s\n' "$directory" >&2; exit 1; }
done

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

api_port="${LOOLOO_API_PORT:-3000}"
if [[ ! "$api_port" =~ ^[0-9]+$ ]]; then
  printf 'LOOLOO_API_PORT must be a numeric port.\n' >&2
  exit 1
fi
if [[ "$api_port" == 3001 ]]; then
  printf 'LOOLOO_API_PORT cannot be 3001; that port is used by chatbot-api.\n' >&2
  exit 1
fi
if [[ -n "${LOOLOO_API_PORT:-}" ]]; then
  if ss -H -ltn "sport = :$api_port" | grep -q .; then
    printf 'Configured LOOLOO_API_PORT %s is already in use.\n' "$api_port" >&2
    exit 1
  fi
else
  while [[ "$api_port" == 3001 ]] || ss -H -ltn "sport = :$api_port" | grep -q .; do
    api_port=$((api_port + 1))
    if (( api_port > 3100 )); then
      printf 'No free API port found between 3000 and 3100. Set LOOLOO_API_PORT explicitly.\n' >&2
      exit 1
    fi
  done
fi

printf 'Building the assistant package and selecting its local dist path for development...\n'
npm --prefix "$ROOT_DIR/looloo-assistant" run build
node - "$WEB_DIR/package.json" <<'NODE'
const fs = require('node:fs');
const packagePath = process.argv[2];
const manifest = JSON.parse(fs.readFileSync(packagePath, 'utf8'));
manifest.dependencies['@looloo/assistant'] = 'file:../looloo-assistant/dist/looloo-assistant';
fs.writeFileSync(packagePath, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
npm --prefix "$WEB_DIR" install
touch "$STATE_DIR/assistant-dependency-local"

start_service() {
  local name="$1" directory="$2" port="$3" env_file="$4"
  shift 4
  local pid_file="$STATE_DIR/$name.pid" log_file="$STATE_DIR/$name.log"
  if [[ -f "$pid_file" ]] && kill -0 "$(<"$pid_file")" 2>/dev/null; then
    printf '%s is already running (PID %s). Log: %s\n' "$name" "$(<"$pid_file")" "$log_file"
    return
  fi
  rm -f "$pid_file"
  if ss -H -ltn "sport = :$port" | grep -q .; then
    printf 'Port %s is already in use; cannot start %s.\n' "$port" "$name" >&2
    exit 1
  fi

  local env_path="$STATE_DIR/$name.env"
  local -a runtime_env=()
  case "$name" in
    looloo-api) runtime_env+=("PORT=$port") ;;
    looloo-web) runtime_env+=("LOOLOO_API_PORT=$api_port") ;;
  esac
  node - "$env_file" "$env_path" "$API_DIR/node_modules/dotenv" <<'NODE'
const fs = require('node:fs');
const dotenv = require(process.argv[4]);
const source = process.argv[2];
const target = process.argv[3];
const values = dotenv.parse(fs.readFileSync(source));
for (const key of ['DB_HOST', 'PG_HOST']) {
  if (values[key] === 'host.minikube.internal') values[key] = '127.0.0.1';
}
fs.writeFileSync(target, Object.entries(values).map(([k, v]) => `${k}=${String(v).replace(/\n/g, '\\n')}`).join('\n') + '\n', { mode: 0o600 });
NODE

  nohup setsid env "${runtime_env[@]}" DOTENV_CONFIG_PATH="$env_path" NODE_OPTIONS="--require=$API_DIR/node_modules/dotenv/config" \
    npm --prefix "$directory" run "$@" >"$log_file" 2>&1 </dev/null &
  local pid=$!
  printf '%s\n' "$pid" > "$pid_file"
  sleep 2
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$pid_file"
    printf '%s failed to start. See %s\n' "$name" "$log_file" >&2
    tail -n 30 "$log_file" >&2 || true
    exit 1
  fi
  printf 'Started %s (PID %s), port %s. Log: %s\n' "$name" "$pid" "$port" "$log_file"
}

start_assistant_watch() {
  local name=looloo-assistant-watch pid_file="$STATE_DIR/looloo-assistant-watch.pid"
  local log_file="$STATE_DIR/looloo-assistant-watch.log"
  if [[ -f "$pid_file" ]] && kill -0 "$(<"$pid_file")" 2>/dev/null; then
    printf '%s is already running (PID %s). Log: %s\n' "$name" "$(<"$pid_file")" "$log_file"
    return
  fi
  rm -f "$pid_file"
  nohup setsid npm --prefix "$WEB_DIR" run watch:assistant >"$log_file" 2>&1 </dev/null &
  local pid=$!
  printf '%s\n' "$pid" > "$pid_file"
  sleep 2
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$pid_file"
    printf '%s failed to start. See %s\n' "$name" "$log_file" >&2
    tail -n 30 "$log_file" >&2 || true
    exit 1
  fi
  printf 'Started %s (PID %s). Log: %s\n' "$name" "$pid" "$log_file"
}

start_assistant_watch
start_service looloo-api "$API_DIR" "$api_port" "$API_DIR/.env" dev
start_service chatbot-api "$CHATBOT_DIR" 3001 "$CHATBOT_DIR/.env" start:dev
start_service looloo-web "$WEB_DIR" 4200 /dev/null start -- --host 127.0.0.1 --port 4200

printf '\nDevelopment apps are running with file watching enabled:\n  Web:         http://localhost:4200\n  Looloo API:  http://localhost:%s\n  Chatbot API: http://localhost:3001\n' "$api_port"
printf 'Local PostgreSQL and Ollama services must also be available as configured in the env files.\n'
printf 'Stop them with scripts/stop-dev.sh. Logs and process state: %s\n' "$STATE_DIR"
