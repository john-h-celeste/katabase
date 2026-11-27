#!/usr/bin/env bash

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
exec > >(tee -a /var/log/startup.log) 2>&1

REPO_URL="https://github.com/john-h-celeste/katabase.git"
APP_DIR="/opt/ha-rag"

# used for debugging
log() {
	echo "[startup] $(date -Is) $*"
}

# main function that installs docker upon startup (and auto-updates if possible)
install() {
	# see if docker was installed or not
	if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
		log "Docker already installed, skipping"
		return
	fi # side-note: this was weird lol

	log "Installing Docker"
	. /etc/os-release # returns the os id (debian, ubutunu, etc) and VERSION_CODENAME to the shell
	apt-get update -y
	apt-get install -y ca-certificates curl gnupg git
	install -m 0755 -d /etc/apt/keyrings
	curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
	chmod a+r /etc/apt/keyrings/docker.asc
	echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" /etc/apt/sources.list.d/docker.list
	apt-get update -y
	apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
	systemctl enable --now docker
}

# keeps the gcp up-to-date with the main github repo
sync_repo() {
	if [ -d "${APP_DIR}/.git" ]; then
		log "Updating repo"
		git -C "${APP_DIR}" pull --ff-only
	else
		log "Cloning repo"
		git clone "${REPO_URL}" "${APP_DIR}"
	fi
}

# sets up the lvm
setup_lvm() {
	
}

# main function that runs when the script is ran
main() {
	log "Startup begin"
	install_docker
	sync_repo
	log "Startup done"
}

main