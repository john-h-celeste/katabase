#!/usr/bin/env bash

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
exec > >(tee -a /var/log/startup.log) 2>&1

# used for debugging
log() {
	echo "[startup] $(date -Is) $*"
}

# main function that runs when the script is ran
main() {
	
}

main