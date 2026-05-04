#!/bin/sh
set -eu

DATA_DIR=/data

# /data must be a writable persistent volume — see ADR-0009.
if ! touch "${DATA_DIR}/.write-test" 2>/dev/null; then
    echo "[entrypoint] FATAL: ${DATA_DIR} is not writable. Mount a persistent volume there." >&2
    exit 1
fi
rm -f "${DATA_DIR}/.write-test"
echo "[entrypoint] ${DATA_DIR} writable: ok"

# If the operator passes the .p8 contents via APNS_KEY_PEM (handy for Coolify
# secrets), materialize it to a tmpfs file the Rust app can read by path.
if [ -n "${APNS_KEY_PEM:-}" ] && [ -z "${APNS_KEY_PATH:-}" ]; then
    APNS_KEY_PATH=/tmp/apns.p8
    printf '%s' "$APNS_KEY_PEM" > "$APNS_KEY_PATH"
    chmod 0400 "$APNS_KEY_PATH"
    export APNS_KEY_PATH
    echo "[entrypoint] APNs key materialized from APNS_KEY_PEM"
fi

# Litestream is enabled iff LITESTREAM_REPLICA_URL is set. See ADR-0010.
if [ -n "${LITESTREAM_REPLICA_URL:-}" ]; then
    echo "[entrypoint] litestream: enabled (replica=${LITESTREAM_REPLICA_URL})"

    # Render minimal litestream config from env so we don't ship a baked yaml.
    cat > /etc/litestream.yml <<EOF
$( [ -n "${LITESTREAM_ACCESS_KEY_ID:-}" ] && echo "access-key-id: ${LITESTREAM_ACCESS_KEY_ID}" )
$( [ -n "${LITESTREAM_SECRET_ACCESS_KEY:-}" ] && echo "secret-access-key: ${LITESTREAM_SECRET_ACCESS_KEY}" )
dbs:
  - path: ${DATA_DIR}/db.sqlite
    replicas:
      - url: ${LITESTREAM_REPLICA_URL}
$( [ -n "${LITESTREAM_REPLICA_ENDPOINT:-}" ] && echo "        endpoint: ${LITESTREAM_REPLICA_ENDPOINT}" )
EOF

    # Restore from replica only if the local DB is missing.
    if [ ! -s "${DATA_DIR}/db.sqlite" ]; then
        echo "[entrypoint] no local DB — attempting restore from replica"
        litestream restore -if-replica-exists -o "${DATA_DIR}/db.sqlite" "${LITESTREAM_REPLICA_URL}" || \
            echo "[entrypoint] no replica found — starting fresh"
    fi

    exec litestream replicate -exec "tring-tring"
else
    echo "[entrypoint] litestream: disabled (set LITESTREAM_REPLICA_URL to enable)"
    exec /usr/local/bin/tring-tring
fi
