#!/usr/bin/env bash
# This (should?) autoscale for the webapp; web1-3 are always on, web4-6 are added when the
# load is high and are dropped when the load drops (the scalability requirement)
# usage: autoscale.sh run | init | status | up | down

set -uo pipefail

APP_DIR="${APP_DIR:-/opt/ha-rag}"
COMPOSE_FILE="${COMPOSE_FILE:-$APP_DIR/docker/docker-compose.yml}"
UPSTREAM_DIR="${UPSTREAM_DIR:-/etc/ha-rag/nginx}"
UPSTREAM_FILE="$UPSTREAM_DIR/web-upstream.conf"
UPSTREAM_NAME="${UPSTREAM_NAME:-web_pool}"
UPSTREAM_PORT="${UPSTREAM_PORT:-8000}"

MIN_WEB="${MIN_WEB:-3}" # 3 on at the minimum
MAX_WEB="${MAX_WEB:-6}" # 6 on ar the maximum
CPU_LIMIT="${CPU_LIMIT:-0.5}" # cpus limit per web container in compose
UP_PCT="${UP_PCT:-70}" # scale up when avg CPU (% of limit) is above this
DOWN_PCT="${DOWN_PCT:-25}" # scale down when avg CPU (% of limit) is below this
UP_CHECKS="${UP_CHECKS:-2}" # consecutive high readings before scaling up
DOWN_CHECKS="${DOWN_CHECKS:-8}" # consecutive low readings before scaling down
INTERVAL="${INTERVAL:-15}" # seconds between readings
HEALTHY_TIMEOUT="${HEALTHY_TIMEOUT:-90}"


