#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/looloo-minikube-${UID}"
CHART_DIR="$ROOT_DIR/looloo-deploy/helm/looloo-monitor"
NAMESPACE="monitoring"
RELEASE="looloo-monitor"
PROMETHEUS_STATEFULSET="prometheus-looloo-monitor-kube-promet-prometheus"

for command in helm kubectl minikube ss curl; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$command" >&2
    exit 1
  fi
done

if [[ "$(minikube status --format='{{.Host}}' 2>/dev/null || true)" != "Running" ]]; then
  printf 'Minikube is not running. Start the app with ./looloo-deploy/scripts/start-app.sh first.\n' >&2
  exit 1
fi

if ! kubectl -n looloo get service looloo-api >/dev/null 2>&1 || \
   ! kubectl -n looloo get service looloo-kong-gateway >/dev/null 2>&1; then
  printf 'The Looloo app release must be installed first.\n' >&2
  exit 1
fi

dependency_status="$(helm dependency list "$CHART_DIR" 2>/dev/null | awk '$1 == "kube-prometheus-stack" {print $4; exit}' || true)"
if [[ "$dependency_status" != "ok" ]]; then
  printf 'Building monitoring chart dependencies...\n'
  helm dependency build "$CHART_DIR"
else
  printf 'Monitoring chart dependencies are already available.\n'
fi

printf 'Installing or upgrading the monitoring release...\n'
helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --wait=false

printf 'Waiting for monitoring components...\n'
kubectl -n "$NAMESPACE" rollout status deployment/looloo-monitor-kube-promet-operator --timeout=600s
kubectl -n "$NAMESPACE" rollout status deployment/looloo-monitor-grafana --timeout=600s
kubectl -n "$NAMESPACE" rollout status deployment/looloo-monitor-kube-state-metrics --timeout=600s
kubectl -n "$NAMESPACE" rollout status daemonset/looloo-monitor-prometheus-node-exporter --timeout=600s

prometheus_created=0
for _ in {1..60}; do
  if kubectl -n "$NAMESPACE" get statefulset "$PROMETHEUS_STATEFULSET" >/dev/null 2>&1; then
    prometheus_created=1
    break
  fi
  sleep 2
done
if [[ "$prometheus_created" -ne 1 ]]; then
  printf 'Timed out waiting for the Prometheus StatefulSet to be created.\n' >&2
  exit 1
fi
kubectl -n "$NAMESPACE" rollout status "statefulset/$PROMETHEUS_STATEFULSET" --timeout=600s

grafana_port=13001
while ss -H -ltn "sport = :$grafana_port" | grep -q .; do
  grafana_port=$((grafana_port + 1))
  if (( grafana_port > 13020 )); then
    printf 'No free localhost port found between 13001 and 13020.\n' >&2
    exit 1
  fi
done

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
port_forward_pid_file="$STATE_DIR/monitor-port-forward.pid"
port_forward_log="$STATE_DIR/monitor-port-forward.log"

printf '\nGrafana: http://localhost:%s\n' "$grafana_port"
printf 'Username: admin\n'
printf 'Retrieve the generated password with:\n'
printf "kubectl -n monitoring get secret looloo-monitor-grafana -o jsonpath='{.data.admin-password}' | base64 --decode; echo\n"
printf 'Run ./looloo-deploy/scripts/stop-monitor.sh to stop monitoring and its port-forward.\n\n'

nohup kubectl -n "$NAMESPACE" port-forward --address 127.0.0.1 \
  service/looloo-monitor-grafana "$grafana_port:80" >"$port_forward_log" 2>&1 </dev/null &
echo "$!" > "$port_forward_pid_file"

for _ in {1..30}; do
  if curl --silent --fail "http://127.0.0.1:$grafana_port/api/health" >/dev/null; then
    printf 'Grafana is ready at http://localhost:%s\n' "$grafana_port"
    exit 0
  fi
  if ! kill -0 "$(<"$port_forward_pid_file")" 2>/dev/null; then
    cat "$port_forward_log" >&2
    printf 'Could not start the Grafana port-forward.\n' >&2
    exit 1
  fi
  sleep 1
done

cat "$port_forward_log" >&2
printf 'Timed out waiting for Grafana on localhost:%s.\n' "$grafana_port" >&2
exit 1