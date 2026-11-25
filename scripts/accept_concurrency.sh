#!/bin/sh
# Acceptance test for a function's [limits] concurrency against a running
# stack: fire N parallel HTTP requests and check that runs finish in
# ceil(N/C) waves while at most C moonrun processes run at once.
#
# Usage: scripts/accept_concurrency.sh [function] [concurrency] [requests]
# Env:   MOONLESS_SERVER       gateway base URL (default http://127.0.0.1:8080)
#        MOONLESS_CHECK_PROCS  set to 0 to skip runner process sampling
#
# The process check targets the local docker compose runner and assumes a
# single runner node. With multiple nodes, concurrency is enforced per node.
set -eu

FUNCTION="${1:-bot}"
LIMIT="${2:-2}"
REQUESTS="${3:-6}"
GATEWAY="${MOONLESS_SERVER:-http://127.0.0.1:8080}"
MAX_TIME="${MOONLESS_CURL_MAX_TIME:-120}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

case "$LIMIT" in ''|*[!0-9]*) fail "concurrency must be a positive integer" ;; esac
case "$REQUESTS" in ''|*[!0-9]*) fail "requests must be a positive integer" ;; esac
[ "$LIMIT" -gt 0 ] || fail "concurrency must be a positive integer"
[ "$REQUESTS" -gt 0 ] || fail "requests must be a positive integer"
[ "$REQUESTS" -gt "$LIMIT" ] \
  || fail "requests must exceed concurrency to observe queueing"

URL="$GATEWAY/fn/$FUNCTION"
WAVES=$(( (REQUESTS + LIMIT - 1) / LIMIT ))

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
COMPOSE_FILE="$ROOT/docker-compose.yml"
compose() { docker compose -f "$COMPOSE_FILE" "$@"; }

WORK="${TMPDIR:-/tmp}/moonless-accept-concurrency-$(id -u)"
mkdir -p "$WORK"
: > "$WORK/done"
: > "$WORK/maxprocs"
trap 'echo done > "$WORK/done" 2>/dev/null || true' EXIT

echo "==> $GATEWAY/fn/$FUNCTION: $REQUESTS requests, concurrency $LIMIT"
curl -sf -m 5 "$GATEWAY/healthz" > /dev/null \
  || fail "gateway is not healthy at $GATEWAY"

WARM="$(curl -s -o /dev/null -w '%{http_code} %{time_total}' -m "$MAX_TIME" "$URL")" \
  || fail "warm-up request failed"
WARM_CODE="${WARM%% *}"
WARM_TIME="${WARM#* }"
case "$WARM_CODE" in
  2??) ;;
  *) fail "warm-up returned HTTP $WARM_CODE" ;;
esac
echo "==> warm-up: HTTP $WARM_CODE in ${WARM_TIME}s"

HOST="${GATEWAY#*://}"
HOST="${HOST%%/*}"
HOST="${HOST%%:*}"
CHECK_PROCS="${MOONLESS_CHECK_PROCS:-1}"
SAMPLER_PID=""
if [ "$CHECK_PROCS" = 1 ] && { [ "$HOST" = "127.0.0.1" ] || [ "$HOST" = "localhost" ]; } \
  && compose ps -q runner 2>/dev/null | grep -q .; then
  (
    max=0
    while [ "$(cat "$WORK/done" 2>/dev/null)" != "done" ]; do
      count="$(compose exec -T runner sh -c \
        "ps -eo args | grep '[m]oonrun' | grep -F '/functions/$FUNCTION/' | wc -l" \
        2>/dev/null || echo 0)"
      count="$(printf '%s' "$count" | tr -d ' ')"
      case "$count" in ''|*[!0-9]*) count=0 ;; esac
      if [ "$count" -gt "$max" ]; then
        max="$count"
      fi
      sleep 0.2
    done
    echo "$max" > "$WORK/maxprocs"
    [ "$max" -le "$LIMIT" ]
  ) &
  SAMPLER_PID=$!
  echo "==> sampling runner processes for $FUNCTION"
else
  echo "==> runner process check skipped"
fi

echo "==> firing $REQUESTS concurrent requests"
BATCH_STATUS=0
seq 1 "$REQUESTS" | xargs -P "$REQUESTS" -I{} sh -c \
  'curl -s -o /dev/null -w "%{http_code} %{time_total}" -m "$4" "$3" > "$2/req.$1"' \
  _ {} "$WORK" "$URL" "$MAX_TIME" || BATCH_STATUS=$?
echo done > "$WORK/done"

SAMPLER_STATUS=0
if [ -n "$SAMPLER_PID" ]; then
  wait "$SAMPLER_PID" || SAMPLER_STATUS=$?
fi

: > "$WORK/times"
FAILED=0
i=1
while [ "$i" -le "$REQUESTS" ]; do
  RESULT="$(cat "$WORK/req.$i" 2>/dev/null || true)"
  CODE="${RESULT%% *}"
  TIME="${RESULT#* }"
  case "$CODE" in
    2??) echo "$TIME" >> "$WORK/times" ;;
    *)
      echo "    request $i: HTTP ${CODE:-none}" >&2
      echo 0 >> "$WORK/times"
      FAILED=1
      ;;
  esac
  i=$((i + 1))
done
sort -n "$WORK/times" > "$WORK/times.sorted"

echo "==> durations (s): $(tr '\n' ' ' < "$WORK/times.sorted")"
[ "$FAILED" -eq 0 ] || fail "one or more requests did not return 2xx"
[ "$BATCH_STATUS" -eq 0 ] || fail "the concurrent request batch did not complete"

REF="$(head -n 1 "$WORK/times.sorted")"
awk -v t="$REF" 'BEGIN { exit !(t > 0) }' || fail "cannot derive a run duration"

if ! awk -v t="$REF" -v c="$LIMIT" -v n="$REQUESTS" '
  {
    w = int(($1 / t) + 0.5)
    if (w < 1) w = 1
    got[w]++
  }
  END {
    waves = int((n + c - 1) / c)
    ok = 1
    for (k = 1; k <= waves; k++) {
      want = c
      if (n - (k - 1) * c < c) want = n - (k - 1) * c
      printf "    wave %d: %d request(s), expected %d\n", k, got[k] + 0, want
      if (got[k] != want) ok = 0
    }
    for (k in got) {
      if (k > waves) {
        printf "    unexpected wave %d: %d request(s)\n", k, got[k]
        ok = 0
      }
    }
    exit !ok
  }
' "$WORK/times.sorted"; then
  fail "request durations do not match $WAVES waves of $LIMIT"
fi

if [ -n "$SAMPLER_PID" ]; then
  MAX_PROCS="$(cat "$WORK/maxprocs" 2>/dev/null || echo 0)"
  case "$MAX_PROCS" in ''|*[!0-9]*) MAX_PROCS=0 ;; esac
  echo "==> runner processes: max $MAX_PROCS (limit $LIMIT)"
  [ "$MAX_PROCS" -gt 0 ] \
    || echo "    warning: sampler saw no $FUNCTION processes" >&2
  if [ "$SAMPLER_STATUS" -ne 0 ] || [ "$MAX_PROCS" -gt "$LIMIT" ]; then
    fail "runner exceeded $LIMIT concurrent processes for $FUNCTION"
  fi
fi

echo "acceptance OK: $FUNCTION ran in $WAVES wave(s) with at most $LIMIT concurrent run(s)"
