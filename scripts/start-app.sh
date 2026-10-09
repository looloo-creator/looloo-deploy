#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/looloo-minikube-${UID}"
API_IMAGE="looloo-api:minikube"
CHATBOT_API_IMAGE="chatbot-api:minikube"
WEB_IMAGE="looloo-web:minikube"
ASSISTANT_DIR="$ROOT_DIR/looloo-assistant"
WEB_DIR="$ROOT_DIR/looloo-web"
NAMESPACE="looloo"
RELEASE="looloo"
CHART_DIR="$ROOT_DIR/looloo-deploy/helm/looloo"
VALUES_FILE="$CHART_DIR/values-dev.yaml"

for command in docker helm kubectl minikube node npm ss curl ps; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$command" >&2
    exit 1
  fi
done

if [[ ! -f "$ROOT_DIR/looloo-api/.env" ]]; then
  printf 'Missing looloo-api/.env. Create it before starting the app.\n' >&2
  exit 1
fi
if [[ ! -f "$ROOT_DIR/chatbot-api/.env" ]]; then
  printf 'Missing chatbot-api/.env. Create it from chatbot-api/.env.example before starting the app.\n' >&2
  exit 1
fi

printf 'Building and packaging the assistant library...\n'
npm --prefix "$ASSISTANT_DIR" run build
npm pack "$ASSISTANT_DIR/dist/looloo-assistant" --pack-destination "$WEB_DIR/vendor"
node - "$WEB_DIR/package.json" <<'NODE'
const fs = require('node:fs');
const packagePath = process.argv[2];
const manifest = JSON.parse(fs.readFileSync(packagePath, 'utf8'));
manifest.dependencies['@looloo/assistant'] = 'file:vendor/looloo-assistant-0.1.0.tgz';
fs.writeFileSync(packagePath, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
npm --prefix "$WEB_DIR" install

if ! grep -Eq '^DB_HOST[[:space:]]*=[[:space:]]*host\.minikube\.internal[[:space:]]*$' "$ROOT_DIR/looloo-api/.env"; then
  printf 'Set DB_HOST in looloo-api/.env to host.minikube.internal for Minikube PostgreSQL access.\n' >&2
  exit 1
fi

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

printf 'Starting Minikube...\n'
if [[ "${LOOLOO_REFRESH:-0}" == "1" ]]; then
  if [[ "$(minikube status --format='{{.Host}}' 2>/dev/null || true)" != "Running" ]]; then
    printf 'Minikube is not running. Start the app with start-app.sh first.\n' >&2
    exit 1
  fi
  printf 'Minikube is already running; refreshing the deployed apps.\n'
else
  minikube start
fi

printf 'Building local application images...\n'
docker build -f "$ROOT_DIR/looloo-api/Dockerfile.production" -t "$API_IMAGE" "$ROOT_DIR/looloo-api"
docker build -f "$ROOT_DIR/chatbot-api/Dockerfile" -t "$CHATBOT_API_IMAGE" "$ROOT_DIR/chatbot-api"
docker build -f "$ROOT_DIR/looloo-web/Dockerfile.production" -t "$WEB_IMAGE" "$ROOT_DIR/looloo-web"

printf 'Loading application images into Minikube...\n'
minikube image load "$API_IMAGE"
minikube image load "$CHATBOT_API_IMAGE"
minikube image load "$WEB_IMAGE"

host_ip="$(minikube ssh -- 'getent hosts host.minikube.internal' | awk 'NR == 1 {print $1}' | tr -d '\r')"
if [[ ! "$host_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'Could not resolve host.minikube.internal from Minikube.\n' >&2
  exit 1
fi

relay_pid_file="$STATE_DIR/db-relay.pid"
if [[ -f "$relay_pid_file" ]] && kill -0 "$(<"$relay_pid_file")" 2>/dev/null; then
  kill "$(<"$relay_pid_file")" 2>/dev/null || true
fi
rm -f "$relay_pid_file"
relay_log="$STATE_DIR/db-relay.log"
nohup node - "$host_ip" >"$relay_log" 2>&1 <<'NODE' &
const net = require('node:net');
const bindAddress = process.argv[2];
for (const port of [5432, 11434]) {
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
  if grep -q "Listening on $host_ip:5432" "$relay_log" && grep -q "Listening on $host_ip:11434" "$relay_log"; then
    break
  fi
  if ! kill -0 "$(<"$relay_pid_file")" 2>/dev/null; then
    cat "$relay_log" >&2
    printf 'Could not start the host database relay.\n' >&2
    exit 1
  fi
  sleep 1
done
if ! grep -q "Listening on $host_ip:5432" "$relay_log" || ! grep -q "Listening on $host_ip:11434" "$relay_log"; then
  cat "$relay_log" >&2
  printf 'Timed out starting the host database relay.\n' >&2
  exit 1
fi

printf 'Preparing namespace and API Secret...\n'
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
npm --prefix "$ROOT_DIR/looloo-api" run k8s:secrets
node - "$ROOT_DIR/looloo-api/.env" "$ROOT_DIR/chatbot-api/.env" "$host_ip" <<'NODE'
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const dotenv = require(path.join(path.dirname(process.argv[2]), 'node_modules/dotenv'));
const [apiEnvPath, chatbotEnvPath, hostIp] = process.argv.slice(2);
const apiEnv = dotenv.parse(fs.readFileSync(apiEnvPath));
const chatbotEnv = dotenv.parse(fs.readFileSync(chatbotEnvPath));
if (!apiEnv.JWT_SECRET_KEY || apiEnv.JWT_SECRET_KEY !== chatbotEnv.JWT_SECRET_KEY) {
  console.error('chatbot-api/.env JWT_SECRET_KEY must match looloo-api/.env JWT_SECRET_KEY.');
  process.exit(1);
}
const rewritten = Object.entries(chatbotEnv).map(([key, value]) => {
  if (key === 'JWT_SECRET_KEY') return `${key}=${value}`;
  return `${key}=${value.replace(/localhost|127\.0\.0\.1/g, hostIp)}`;
});
const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'looloo-chatbot-secret-'));
const envPath = path.join(tempDir, '.env');
try {
  fs.writeFileSync(envPath, `${rewritten.join('\n')}\n`, { mode: 0o600 });
  const manifest = spawnSync('kubectl', ['--namespace', 'looloo', 'create', 'secret', 'generic', 'chatbot-api-env', `--from-env-file=${envPath}`, '--dry-run=client', '--output=yaml'], { encoding: 'utf8' });
  if (manifest.status !== 0) throw new Error(manifest.stderr || 'Could not generate chatbot API Secret.');
  const applied = spawnSync('kubectl', ['apply', '--filename=-'], { input: manifest.stdout, encoding: 'utf8' });
  if (applied.status !== 0) throw new Error(applied.stderr || 'Could not apply chatbot API Secret.');
  process.stdout.write(applied.stdout);
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
} finally {
  fs.rmSync(tempDir, { recursive: true, force: true });
}
NODE

printf 'Deploying Looloo with Helm...\n'
helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --values "$VALUES_FILE" \
  --set-string "chatbotApi.ollamaBaseUrl=http://${host_ip}:11434" \
  --take-ownership

printf 'Restarting application deployments to load refreshed images and secrets...\n'
kubectl -n "$NAMESPACE" rollout restart \
  deployment/looloo-api \
  deployment/looloo-chatbot-api \
  deployment/looloo-kong-gateway \
  deployment/looloo-web
for deployment in looloo-api looloo-chatbot-api looloo-kong-gateway looloo-web; do
  kubectl -n "$NAMESPACE" rollout status "deployment/$deployment" --timeout=180s
done

web_port=""
port_file="$STATE_DIR/web-port"
port_forward_pid_file="$STATE_DIR/web-port-forward.pid"
if [[ -f "$port_forward_pid_file" ]] && kill -0 "$(<"$port_forward_pid_file")" 2>/dev/null; then
  port_forward_pid="$(<"$port_forward_pid_file")"
  command_line="$(ps -p "$port_forward_pid" -o args= 2>/dev/null || true)"
  if [[ "$command_line" == *"kubectl -n $NAMESPACE port-forward --address 127.0.0.1"* ]]; then
    if [[ -f "$port_file" ]]; then
      web_port="$(<"$port_file")"
    elif [[ "$command_line" =~ ([0-9]+):80 ]]; then
      web_port="${BASH_REMATCH[1]}"
    fi
    kill -TERM "$port_forward_pid" 2>/dev/null || true
    for _ in {1..10}; do
      kill -0 "$port_forward_pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$port_forward_pid" 2>/dev/null; then
      kill -KILL "$port_forward_pid" 2>/dev/null || true
    fi
  fi
fi
rm -f "$port_forward_pid_file"
if [[ ! "$web_port" =~ ^[0-9]+$ ]]; then
  web_port=18080
fi
while ss -H -ltn "sport = :$web_port" | grep -q .; do
  web_port=$((web_port + 1))
  if (( web_port > 18100 )); then
    printf 'No free localhost port found between 18080 and 18100.\n' >&2
    exit 1
  fi
done

port_forward_log="$STATE_DIR/web-port-forward.log"
echo "$web_port" > "$port_file"
nohup kubectl -n "$NAMESPACE" port-forward --address 127.0.0.1 \
  "service/looloo-web" "$web_port:80" >"$port_forward_log" 2>&1 </dev/null &
echo "$!" > "$port_forward_pid_file"

for _ in {1..30}; do
  if curl --silent --fail "http://127.0.0.1:$web_port/" >/dev/null; then
    printf '\nLooloo is available at http://localhost:%s\n' "$web_port"
    printf 'API route: http://localhost:%s/api/\n' "$web_port"
    printf 'Assistant API route: http://localhost:%s/chatbot-api/\n' "$web_port"
    printf 'Run ./looloo-deploy/scripts/stop-app.sh to stop the Looloo app and its helper processes.\n'
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
