#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/looloo-minikube-${UID}"
NAMESPACE="looloo"

stop_pid_file() {
  local pid_file="$1"
  local expected_command="$2"

  if [[ ! -f "$pid_file" ]]; then
    return 0
  fi

  local pid
  pid="$(<"$pid_file")"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    local command_line
    command_line="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    if [[ "$command_line" == *"$expected_command"* ]]; then
      kill -TERM "$pid" 2>/dev/null || true
      for _ in {1..10}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
      done
      if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
      fi
      printf 'Stopped %s (PID %s).\n' "$expected_command" "$pid"
    else
      printf 'PID %s no longer matches %s; leaving it untouched.\n' "$pid" "$expected_command"
    fi
  fi
  rm -f "$pid_file"
}

if command -v kubectl >/dev/null 2>&1 && command -v minikube >/dev/null 2>&1 && \
   [[ "$(minikube status --format='{{.Host}}' 2>/dev/null || true)" == "Running" ]]; then
  printf 'Scaling down Looloo Deployments...\n'
  kubectl -n "$NAMESPACE" scale deployment/looloo-api deployment/looloo-chatbot-api deployment/looloo-kong-gateway deployment/looloo-web \
    --replicas=0 --timeout=60s 2>/dev/null || true
else
  printf 'Minikube is not running; skipping Kubernetes scale-down.\n'
fi

stop_pid_file "$STATE_DIR/web-port-forward.pid" 'kubectl -n looloo port-forward'
stop_pid_file "$STATE_DIR/db-relay.pid" 'node -'

printf 'Stopped the Looloo workloads and helper processes. Minikube remains running.\n'
