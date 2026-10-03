#!/bin/sh
# Full P0 flow against a fresh compose stack:
# deploy examples/hello with the CLI, trigger it over HTTP, read its logs.
#
# Usage: scripts/smoke_p0.sh
# Env:   MOONLESS_SERVER — gateway base URL (default http://127.0.0.1:8080)
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATEWAY="${MOONLESS_SERVER:-http://127.0.0.1:8080}"
export PATH="$HOME/.moon/bin:$PATH"

echo "==> building the moonless CLI"
(umask 022 && true)
moon build --target native cmd/moonless
CLI="$ROOT/_build/native/debug/build/cmd/moonless/moonless.exe"

echo "==> starting a fresh compose stack"
docker compose -f "$ROOT/docker-compose.yml" down -v > /dev/null 2>&1 || true
docker compose -f "$ROOT/docker-compose.yml" up -d --build gateway builder runner

printf '==> waiting for the gateway'
i=0
while [ $i -lt 90 ]; do
  if curl -sf "$GATEWAY/healthz" > /dev/null 2>&1; then
    printf ' up\n'
    break
  fi
  i=$((i + 1))
  sleep 1
done
if [ $i -ge 90 ]; then
  printf 'gateway did not come up\n' >&2
  exit 1
fi

echo "==> deploying examples/hello via the CLI"
(cd "$ROOT/examples/hello" && "$CLI" deploy --server "$GATEWAY")

echo "==> triggering over HTTP"
OUT="$(curl -sf "$GATEWAY/fn/hello")"
echo "$OUT" | grep 'hello! triggered by' > /dev/null \
  || { echo "unexpected trigger output: $OUT"; exit 1; }

echo "==> listing functions"
"$CLI" list --server "$GATEWAY" | grep '^hello ' > /dev/null \
  || { echo "hello missing from 'moonless list' output"; exit 1; }

echo "==> reading logs via the CLI"
LOGS="$("$CLI" logs hello --tail 3 --server "$GATEWAY")"
echo "$LOGS" | grep 'event=' > /dev/null \
  || { echo "no run records in logs: $LOGS"; exit 1; }

echo "P0 smoke OK: deploy -> trigger -> list -> logs"
