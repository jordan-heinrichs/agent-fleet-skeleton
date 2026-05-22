#!/bin/sh
# Generate Redis ACL file from env vars and start Redis.
#
# Access model:
#   manager — full access to fleet:* keys (orchestrator, config writes)
#   worker  — job queues + result queues only; explicitly cannot reach fleet:config
#   default — PING only (no password, no keys); keeps Docker healthcheck working
set -e

: "${REDIS_MANAGER_PASS:?REDIS_MANAGER_PASS must be set}"
: "${REDIS_WORKER_PASS:?REDIS_WORKER_PASS must be set}"

cat > /tmp/users.acl <<EOF
user manager on >${REDIS_MANAGER_PASS} ~fleet:* +@all -@dangerous
user worker on >${REDIS_WORKER_PASS} ~fleet:jobs* ~fleet:results:fire-* +BLMOVE +LREM +LPUSH +PING
user default on nopass +PING
EOF

exec redis-server --aclfile /tmp/users.acl --save "" --appendonly no "$@"
