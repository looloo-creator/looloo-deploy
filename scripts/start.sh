#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

"$ROOT_DIR/looloo-deploy/scripts/start-app.sh"
exec "$ROOT_DIR/looloo-deploy/scripts/start-monitor.sh"
