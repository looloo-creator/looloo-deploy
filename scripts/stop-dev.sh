#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/looloo-dev-${UID}"

stop_service() {
  local name="$1" pid_file="$STATE_DIR/$1.pid"
  [[ -f "$pid_file" ]] || return 0
  local pid command_line
  pid="$(<"$pid_file")"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    command_line="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    local process_group
    process_group="$(ps -p "$pid" -o pgid= 2>/dev/null | tr -d ' ' || true)"
    if [[ "$process_group" == "$pid" && "$command_line" == *npm* ]]; then
      kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      for _ in {1..10}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
      done
      if kill -0 "$pid" 2>/dev/null; then kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true; fi
      printf 'Stopped %s.\n' "$name"
    else
      printf 'PID %s no longer matches %s; leaving it untouched.\n' "$pid" "$name" >&2
    fi
  fi
  rm -f "$pid_file" "$STATE_DIR/$name.env"
}

stop_service looloo-web
stop_service chatbot-api
stop_service looloo-api
stop_service looloo-assistant-watch
if [[ -f "$STATE_DIR/assistant-dependency-local" ]]; then
  WEB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../looloo-web" && pwd)"
  node - "$WEB_DIR/package.json" <<'NODE'
const fs = require('node:fs');
const packagePath = process.argv[2];
const manifest = JSON.parse(fs.readFileSync(packagePath, 'utf8'));
manifest.dependencies['@looloo/assistant'] = 'file:vendor/looloo-assistant-0.1.0.tgz';
fs.writeFileSync(packagePath, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
  npm --prefix "$WEB_DIR" install
  rm -f "$STATE_DIR/assistant-dependency-local"
  printf 'Restored looloo-web to its vendor assistant package.\n'
fi
printf 'Local development apps stopped. Logs remain in %s.\n' "$STATE_DIR"
