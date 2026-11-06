#!/bin/sh
# End-to-end smoke for the moonless gateway against a running stack:
# deploy a fixture function, list it, trigger it over HTTP, read its logs.
#
# Usage: scripts/e2e_gateway.sh
# Env:   MOONLESS_SERVER — gateway base URL (default http://127.0.0.1:8080)
set -eu

GATEWAY="${MOONLESS_SERVER:-http://127.0.0.1:8080}"

WORK="$(mktemp -d)"
FIXTURE="$WORK/hello-fn"
mkdir -p "$FIXTURE"

cat > "$FIXTURE/moon.mod" <<'EOF'
name = "e2e/hello-fn"
version = "0.1.0"
EOF

cat > "$FIXTURE/moonless.toml" <<'EOF'
name = "hello-fn"

[triggers]
http = { enabled = true }
EOF

cat > "$FIXTURE/moon.pkg" <<'EOF'
import {
  "moonbitlang/core/env",
}

pkgtype(kind: "executable")
EOF

cat > "$FIXTURE/main.mbt" <<'EOF'
fn main {
  println("hello from hello-fn")
  match @env.get_env_var("MOONLESS_EVENT") {
    Some(event) => println("saw event: \{event}")
    None => println("no event")
  }
}
EOF

tar --format=ustar -czf "$WORK/package.tar.gz" -C "$FIXTURE" .
B64="$(base64 < "$WORK/package.tar.gz" | tr -d '\n')"
printf '{"name":"hello-fn","archive":"%s"}' "$B64" > "$WORK/deploy.json"

echo "==> deploying hello-fn to $GATEWAY"
DEPLOY_RESULT="$(curl -sf --max-time 300 -X POST \
  -H "Content-Type: application/json" \
  --data @"$WORK/deploy.json" "$GATEWAY/api/deploy")"
echo "$DEPLOY_RESULT" | grep '"ok":true' > /dev/null \
  || { echo "deploy failed: $DEPLOY_RESULT"; exit 1; }
echo "    build ok: $(echo "$DEPLOY_RESULT" | sed 's/.*"buildId":"\([^"]*\)".*/\1/')"

echo "==> listing functions"
FUNCTIONS="$(curl -sf "$GATEWAY/api/functions")"
echo "$FUNCTIONS" | grep 'hello-fn' > /dev/null \
  || { echo "hello-fn missing from registry: $FUNCTIONS"; exit 1; }

echo "==> triggering over HTTP"
TRIGGER_OUT="$(curl -sf "$GATEWAY/fn/hello-fn")"
echo "$TRIGGER_OUT" | grep 'hello from hello-fn' > /dev/null \
  || { echo "unexpected trigger output: $TRIGGER_OUT"; exit 1; }
echo "$TRIGGER_OUT" | grep 'saw event' > /dev/null \
  || { echo "function did not see MOONLESS_EVENT: $TRIGGER_OUT"; exit 1; }

echo "==> reading logs"
LOGS="$(curl -sf "$GATEWAY/api/functions/hello-fn/logs?tail=5")"
echo "$LOGS" | grep 'event=' > /dev/null \
  || { echo "no run records in logs: $LOGS"; exit 1; }

echo "e2e OK: deploy -> list -> trigger -> logs"
