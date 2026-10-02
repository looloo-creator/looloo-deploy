#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/looloo-minikube-${UID}"
NAMESPACE="monitoring"
RELEASE="looloo-monitor"
pid_file="$STATE_DIR/monitor-port-forward.pid"

if [[ -f "$pid_file" ]]; then
  pid="$(<"$pid_file")"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    command_line="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    if [[ "$command_line" == *"kubectl -n monitoring port-forward"* && "$command_line" == *"service/looloo-monitor-grafana"* ]]; then
      kill -TERM "$pid" 2>/dev/null || true
      for _ in {1..10}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
      done
      if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
      fi
      printf 'Stopped Grafana port-forward (PID %s).\n' "$pid"
    else
      printf 'PID %s no longer matches the tracked Grafana port-forward; leaving it untouched.\n' "$pid"
    fi
  fi
  rm -f "$pid_file"
fi

if command -v helm >/dev/null 2>&1 && command -v minikube >/dev/null 2>&1 && \
   [[ "$(minikube status --format='{{.Host}}' 2>/dev/null || true)" == "Running" ]] && \
   helm -n "$NAMESPACE" status "$RELEASE" >/dev/null 2>&1; then
  helm -n "$NAMESPACE" uninstall "$RELEASE"
else
  printf 'Monitoring Helm release is not installed; nothing to uninstall.\n'
fi

printf 'Stopped the monitoring release. The Looloo app and Minikube remain running.\n'