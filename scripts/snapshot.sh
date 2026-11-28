#!/usr/bin/env bash
# usage: sudo bash scripts/snapshot.sh create | verify | remove | status
set -euo pipefail

VG="data_vg"
LV="db"
SNAP="db_snap"
SNAP_SIZE="${SNAP_SIZE:-2G}"
MOUNT_POINT="/mnt/snap"
DB_CONTAINER="${DB_CONTAINER:-rag-db}"

snap_exists() { 
	lvs "/dev/${VG}/${SNAP}" >/dev/null 2>&1
}

create() {
	if snap_exists; then
    	echo "[snapshot] ${SNAP} already exists; remove it first (snapshot.sh remove)"
    	exit 1
  	fi
  	echo "[snapshot] flushing Postgres to disk (CHECKPOINT)"

  	# reads the user from the container's own environment
  	docker exec "$DB_CONTAINER" sh -c 'psql -U "$POSTGRES_USER" -d "${POSTGRES_DB:-$POSTGRES_USER}" -c "CHECKPOINT;"' || echo "[snapshot] WARNING: checkpoint failed, snapshot will be crash-consistent"
  	echo "[snapshot] creating ${SNAP} (${SNAP_SIZE}) from ${VG}/${LV}"
  	lvcreate --size "$SNAP_SIZE" --snapshot --name "$SNAP" "/dev/${VG}/${LV}"
  	lvs "/dev/${VG}/${SNAP}"
}

verify() {
  	snap_exists || { echo "[snapshot] no ${SNAP} to verify"; exit 1; }
  	mkdir -p "$MOUNT_POINT"
  	mountpoint -q "$MOUNT_POINT" || mount -o ro "/dev/${VG}/${SNAP}" "$MOUNT_POINT"
  	echo "[snapshot] contents of ${MOUNT_POINT}:"
  	ls "$MOUNT_POINT"
  	umount "$MOUNT_POINT"
}

remove() {
  	mountpoint -q "$MOUNT_POINT" && umount "$MOUNT_POINT"
  	if snap_exists; then
    	lvremove -y "/dev/${VG}/${SNAP}"
  	else
    	echo "[snapshot] nothing to remove"
  	fi
}

status() { 
	"$VG" vgs "$VG"
}

case "${1:-}" in
	create) create ;;
  	verify) verify ;;
  	remove) remove ;;
  	status) status ;;
  	*) echo "usage: sudo bash $0 create | verify | remove | status"; exit 1 ;;
esac