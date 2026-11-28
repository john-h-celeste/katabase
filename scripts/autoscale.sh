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

log() { 
	echo "[autoscale] $(date -u +%FT%TZ) $*"
}

compose() { 
	docker compose -f "$COMPOSE_FILE" --profile scale "$@"
}

# gets the names of the web containers that are running (by name)
running_web() {
  docker ps --format '{{.Names}}' | grep -E '^web[0-9]+$' | sort -V
}

# gets the number of containers running
web_count() { 
	running_web | wc -l
}

is_healthy() {
  [ "$(docker inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null)" = "healthy" ]
}

avg_util() {

}

# displays the nginx upstream for the web containers
render_upstream() {
	echo "upstream ${UPSTREAM_NAME} {"
	echo "    least_conn;"
	local n
	for n in "$@"; do
		echo "    server ${n}:${UPSTREAM_PORT} max_fails=3 fail_timeout=10s;"
	done
	echo "}"
}

# writes the rendered upstream for a container to the upstream file
write_upstream() {
	mkdir -p "$UPSTREAM_DIR"
	render_upstream "$@" > "$UPSTREAM_FILE.tmp" && mv "$UPSTREAM_FILE.tmp" "$UPSTREAM_FILE"
}

# reload the nginx configuration
reload_nginx() {
	if compose exec -T nginx nginx -t >/dev/null 2>&1; then
    	compose exec -T nginx nginx -s reload >/dev/null 2>&1 && log "nginx reloaded"
  	else
    	log "ERROR: nginx config test failed, not reloading"
    	return 1
  	fi
}

# only show healthy and running containers
sync_upstream() {
	local list=() n

  	while read -r n; do
    	[ -n "$n" ] && is_healthy "$n" && list+=("$n")
  	done < <(running_web)

  	if [ "${#list[@]}" -eq 0 ]; then
    	log "no healthy web containers (upstream unchanged)"
    	return 1
  	fi

  	write_upstream "${list[@]}"
  	reload_nginx
  	log "upstream now: ${list[*]}"
}

init() {
	log "begin autoscale script"
	local core=() i
  	for i in $(seq 1 "$MIN_WEB"); do core+=("web$i"); done
  	write_upstream "${core[@]}"
  	log "initialized upstream with core: ${core[*]}"
}

# open more containers
scale_up() {
	local count n
  	count=$(web_count)

  	[ "$count" -ge "$MAX_WEB" ] && { log "already at max containers ($MAX_WEB)"; return 0; }

  	for n in $(seq $((MIN_WEB + 1)) "$MAX_WEB"); do
    	if ! running_web | grep -qx "web$n"; then
      		log "(scaling up): starting web$n"
      		compose up -d "web$n" >/dev/null 2>&1 || { log "could not start web$n"; return 1; }
      		local waited=0
      		until is_healthy "web$n"; do
        		sleep 3; waited=$((waited + 3))
        		[ "$waited" -ge "$HEALTHY_TIMEOUT" ] && { log "web$n not healthy after ${HEALTHY_TIMEOUT}s"; return 1; }
      		done
      		sync_upstream
      		return 0
    	fi
  done
}

# close the extra containers
scale_down() {
	local count n
  	count=$(web_count)
  	[ "$count" -le "$MIN_WEB" ] && { log "already at min ($MIN_WEB)"; return 0; }
  	n=$(running_web | tail -n 1)
  	log "(scaling down): removing $n"

  	# take it out of rotation, but give requests time to finish first
  	local list=() w
  	while read -r w; do
    	[ "$w" != "$n" ] && is_healthy "$w" && list+=("$w")
  	done < <(running_web)

  	write_upstream "${list[@]}"
  	reload_nginx
  	sleep 20
  	compose stop -t 30 "$n" >/dev/null 2>&1
  	log "stopped $n; running: $(running_web | tr '\n' ' ')"
}

status() {
	echo "running web containers: $(running_web | tr '\n' ' ')"
	echo "avg CPU (% of limit):   $(avg_util)"
  	echo "--- $UPSTREAM_FILE ---"
  	cat "$UPSTREAM_FILE" 2>/dev/null || echo "(not written yet)"
}

# run the actual script
run() {
	log "starting: min=$MIN_WEB max=$MAX_WEB up>${UP_PCT}% x${UP_CHECKS} down<${DOWN_PCT}% x${DOWN_CHECKS} every ${INTERVAL}s"
  	sync_upstream || true # some containers could've (maybe) survived a reboot
  	local hi=0 lo=0 util

  	while true; do
    	util=$(avg_util)
    	log "avg CPU ${util}% of limit, web=$(web_count)"

    	if [ "$util" -ge "$UP_PCT" ]; then
      		hi=$((hi + 1)); lo=0
    	elif [ "$util" -le "$DOWN_PCT" ]; then
      		lo=$((lo + 1)); hi=0
    	else
      		hi=0; lo=0
    	
		
    	if [ "$hi" -ge "$UP_CHECKS" ]; then scale_up; hi=0; fi
    	if [ "$lo" -ge "$DOWN_CHECKS" ]; then scale_down; lo=0; fi

    	sleep "$INTERVAL"
  	done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	case "${1:-}" in
    	run)    run ;;
    	init)   init ;;
    	status) status ;;
    	up)     scale_up ;;
    	down)   scale_down ;;
    	*) echo "Usage: $0 run|init|status|up|down"; exit 1 ;;
  	esac
fi
