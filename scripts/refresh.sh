#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
export LOOLOO_REFRESH=1
exec "$ROOT_DIR/looloo-deploy/scripts/start-app.sh"
