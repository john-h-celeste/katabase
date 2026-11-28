#!/usr/bin/env bash

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if [ -z "${STARTUP_LOGGING:-}" ]; then
	exec > >(tee -a /var/log/startup.log) 2>&1
fi

APP_DIR="/opt/ha-rag"

# gets the repo of the specified branch
meta() {
	curl -sf -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1" || echo "$2"
}

REPO_URL="$(meta repo-url 'https://github.com/john-h-celeste/katabase.git')"
REPO_BRANCH="$(meta repo-branch main)"

# used for debugging
log() {
	echo "[startup] $(date -Is) $*"
}

# main function that installs docker upon startup (and auto-updates if possible)
install_docker() {
	# see if docker was installed or not
	if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
		log "Docker already installed, skipping"
		return
	fi # side-note: this was weird lol

	log "Installing Docker"
	. /etc/os-release # returns the os id (debian, ubutunu, etc) and VERSION_CODENAME to the shell
	apt-get -o DPkg::Lock::Timeout=120 update -y
	apt-get -o DPkg::Lock::Timeout=120 install -y ca-certificates curl gnupg git
	install -m 0755 -d /etc/apt/keyrings
	curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
	chmod a+r /etc/apt/keyrings/docker.asc
	echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
	apt-get -o DPkg::Lock::Timeout=120 update -y
	apt-get -o DPkg::Lock::Timeout=120 install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
	systemctl enable --now docker
}

# keeps the gcp up-to-date with the main github repo
sync_repo() {
	local url branch
	url=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/repo-url)
	branch=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/repo-branch)
	apt-get -o DPkg::Lock::Timeout=120 install -y git
	if [ -d /opt/ha-rag/.git ]; then
    	git -C /opt/ha-rag fetch origin "$branch" && git -C /opt/ha-rag checkout -B "$branch" "origin/$branch" && git -C /opt/ha-rag reset --hard "origin/$branch"
  	else
    	git clone -b "$branch" "$url" /opt/ha-rag
  	fi
}

# sets up the 
# (used google gemini to assist with this part since it was confusing -ymani)
setup_lvm() {
	apt-get -o DPkg::Lock::Timeout=120 install -y lvm2
	DISK=/dev/disk/by-id/google-data-disk

	# create physical volume and volume group (only if missing)
	vgs data_vg >/dev/null 2>&1 || { pvcreate "$DISK"; vgcreate data_vg "$DISK"; }

	# leave free space in the VG for the snapshot
	lvs data_vg/db     >/dev/null 2>&1 || lvcreate -L 10G -n db     data_vg
	lvs data_vg/models >/dev/null 2>&1 || lvcreate -L 20G -n models data_vg

	# formats only if there's no filesystem yet
	for lv in db models; do
		blkid "/dev/data_vg/$lv" >/dev/null 2>&1 || mkfs.ext4 "/dev/data_vg/$lv"
	done

	# persistent mounts via /etc/fstab
	mkdir -p /data/db /models
	grep -q '/dev/data_vg/db' /etc/fstab || echo '/dev/data_vg/db /data/db ext4 defaults,nofail 0 2' >> /etc/fstab
	grep -q '/dev/data_vg/models' /etc/fstab || echo '/dev/data_vg/models /models ext4 defaults,nofail 0 2' >> /etc/fstab
	mountpoint -q /data/db || mount /data/db
	mountpoint -q /models  || mount /models
}

write_env() {
	ENV_FILE="${APP_DIR}/docker/.env"
	PW="$(gcloud secrets versions access latest --secret=postgres-password)"
	( umask 077; printf 'POSTGRES_PASSWORD=%s\n' "$PW" > "$ENV_FILE" )

	log "Wrote .env"
}

# LOADING THE MODELS
# ==================================================================================
# stages the models into the /models volume so that they are available for use
stage_models() {
  	local OLLAMA_IMAGE="ollama/ollama:0.40.17"
  	local MODELS=("llama3.2:3b" "nomic-embed-text")

  	docker rm -f ollama-stage >/dev/null 2>&1 || true
  	docker run -d --name ollama-stage -e OLLAMA_MODELS=/models -v /models:/models "$OLLAMA_IMAGE"

  	for _ in $(seq 1 30); do
		docker exec ollama-stage ollama list >/dev/null 2>&1 && break
		sleep 2
	done

	for m in "${MODELS[@]}"; do
    	if docker exec ollama-stage ollama list | grep -q "^${m}"; then
      		log "Model ${m} already staged"
    	else
      		log "Pulling ${m}"
      		docker exec ollama-stage ollama pull "$m"
		fi
	done

	docker rm -f ollama-stage
}

start_stack() {
  	cd "${APP_DIR}/docker"
  	docker compose up -d --build

  	log "Waiting for database"
  	for _ in $(seq 1 60); do
		[ "$(docker inspect -f '{{.State.Health.Status}}' rag-db 2>/dev/null)" = "healthy" ] && return
		sleep 5
	done
	log "ERROR: database did not become healthy"; exit 1
}

run_ingest() {
	cd "${APP_DIR}/docker"
	docker compose --profile tools run --rm --build ingest
}

# ==================================================================================

# main function that runs when the script is ran
main() {
	log "Startup begin"
	sync_repo
	install_docker
	setup_lvm
	write_env
	# log "after env"
	stage_models
	# log "hellooooooo"
	start_stack
	run_ingest
	log "Startup done"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main; fi