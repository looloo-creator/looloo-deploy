#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/looloo-minikube-${UID}"
API_IMAGE="looloo-api:minikube"
WEB_IMAGE="looloo-web:minikube"
NAMESPACE="looloo"
RELEASE="looloo"
CHART_DIR="$ROOT_DIR/looloo-deploy/helm/looloo"
VALUES_FILE="$CHART_DIR/values-dev.yaml"

for command in docker helm kubectl minikube node npm ss curl; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$command" >&2
    exit 1
  fi
done

if [[ ! -f "$ROOT_DIR/looloo-api/.env" ]]; then
  printf 'Missing looloo-api/.env. Create it before starting the app.\n' >&2
  exit 1
fi

if ! grep -Eq '^DB_HOST[[:space:]]*=[[:space:]]*host\.minikube\.internal[[:space:]]*$' "$ROOT_DIR/looloo-api/.env" || \
   ! grep -Eq '^MONGO_URL=mongodb://host\.minikube\.internal:' "$ROOT_DIR/looloo-api/.env"; then
  printf 'Set DB_HOST and MONGO_URL in looloo-api/.env to host.minikube.internal for Minikube access.\n' >&2
  exit 1
fi

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

printf 'Starting Minikube...\n'
minikube start

printf 'Building local application images...\n'
docker build -f "$ROOT_DIR/looloo-api/Dockerfile.production" -t "$API_IMAGE" "$ROOT_DIR/looloo-api"
docker build -f "$ROOT_DIR/looloo-web/Dockerfile.production" -t "$WEB_IMAGE" "$ROOT_DIR/looloo-web"

printf 'Loading application images into Minikube...\n'
minikube image load "$API_IMAGE"
minikube image load "$WEB_IMAGE"

host_ip="$(minikube ssh -- 'getent hosts host.minikube.internal' | awk 'NR == 1 {print $1}' | tr -d '\r')"
if [[ ! "$host_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'Could not resolve host.minikube.internal from Minikube.\n' >&2
  exit 1
fi

relay_pid_file="$STATE_DIR/db-relay.pid"
if [[ -f "$relay_pid_file" ]] && kill -0 "$(<"$relay_pid_file")" 2>/dev/null; then
  printf 'Host database relay is already running (PID %s).\n' "$(<"$relay_pid_file")"
else
  rm -f "$relay_pid_file"
  relay_log="$STATE_DIR/db-relay.log"
  nohup node - "$host_ip" >"$relay_log" 2>&1 <<'NODE' &
const net = require('node:net');
const bindAddress = process.argv[2];
for (const port of [5432, 27017]) {
  const server = net.createServer((client) => {
    const upstream = net.connect({ host: '127.0.0.1', port });
    client.pipe(upstream);
    upstream.pipe(client);
    client.on('error', () => upstream.destroy());
    upstream.on('error', () => client.destroy());
  });
  server.on('error', (error) => {
    console.error(`Relay ${port} failed: ${error.message}`);
    process.exit(1);
  });
  server.listen(port, bindAddress, () => console.log(`Listening on ${bindAddress}:${port}`));
}
NODE
  echo "$!" > "$relay_pid_file"
  for _ in {1..30}; do
    if grep -q "Listening on $host_ip:5432" "$relay_log" && grep -q "Listening on $host_ip:27017" "$relay_log"; then
      break
    fi
    if ! kill -0 "$(<"$relay_pid_file")" 2>/dev/null; then
      cat "$relay_log" >&2
      printf 'Could not start the host database relay.\n' >&2
      exit 1
    fi
    sleep 1
  done
  if ! grep -q "Listening on $host_ip:5432" "$relay_log" || ! grep -q "Listening on $host_ip:27017" "$relay_log"; then
    cat "$relay_log" >&2
    printf 'Timed out starting the host database relay.\n' >&2
    exit 1
  fi
fi

printf 'Preparing namespace and API Secret...\n'
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
npm --prefix "$ROOT_DIR/looloo-api" run k8s:secrets

printf 'Deploying Looloo with Helm...\n'
helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --values "$VALUES_FILE" \
  --take-ownership

printf 'Waiting for web and Kong...\n'
kubectl -n "$NAMESPACE" rollout status deployment/looloo-kong-gateway --timeout=180s
kubectl -n "$NAMESPACE" rollout status deployment/looloo-web --timeout=180s
printf 'Restarting API after database relay is ready...\n'
kubectl -n "$NAMESPACE" rollout restart deployment/looloo-api
kubectl -n "$NAMESPACE" rollout status deployment/looloo-api --timeout=180s

web_port=18080
while ss -H -ltn "sport = :$web_port" | grep -q .; do
  web_port=$((web_port + 1))
  if (( web_port > 18100 )); then
    printf 'No free localhost port found between 18080 and 18100.\n' >&2
    exit 1
  fi
done

port_forward_log="$STATE_DIR/web-port-forward.log"
nohup kubectl -n "$NAMESPACE" port-forward --address 127.0.0.1 \
  "service/looloo-web" "$web_port:80" >"$port_forward_log" 2>&1 </dev/null &
echo "$!" > "$STATE_DIR/web-port-forward.pid"

for _ in {1..30}; do
  if curl --silent --fail "http://127.0.0.1:$web_port/" >/dev/null; then
    printf '\nLooloo is available at http://localhost:%s\n' "$web_port"
    printf 'API route: http://localhost:%s/api/\n' "$web_port"
    printf 'Run ./looloo-deploy/scripts/stop.sh to stop this Looloo release and its helper processes.\n'
    exit 0
  fi
  if ! kill -0 "$(<"$STATE_DIR/web-port-forward.pid")" 2>/dev/null; then
    cat "$port_forward_log" >&2
    printf 'Could not start the web port-forward.\n' >&2
    exit 1
  fi
  sleep 1
done

cat "$port_forward_log" >&2
printf 'Timed out waiting for the web app at localhost:%s.\n' "$web_port" >&2
exit 1