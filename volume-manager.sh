#!/usr/bin/env bash
# volume-manager.sh
# Manage EBS volumes on EC2 (attach or extend)

set -euo pipefail

usage() {
  echo "Usage:"
  echo "  $0 --mode attach --device <device> --mount-point <path> --fs-type <ext4|xfs>"
  echo "  $0 --mode extend --device <device>"
  exit 1
}

MODE=""
DEVICE=""
MOUNT_POINT=""
FS_TYPE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --device) DEVICE="$2"; shift 2 ;;
    --mount-point) MOUNT_POINT="$2"; shift 2 ;;
    --fs-type) FS_TYPE="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

if [[ -z "$MODE" || -z "$DEVICE" ]]; then
  usage
fi

extend_volume() {
  echo "[INFO] Extending volume on $DEVICE"

  # Auto-detect fs-type
  FS_TYPE=$(lsblk -no FSTYPE "$DEVICE" | head -n1)
  if [[ -z "$FS_TYPE" ]]; then
    FS_TYPE=$(blkid -o value -s TYPE "$DEVICE" || true)
  fi
  if [[ -z "$FS_TYPE" ]]; then
    echo "[ERROR] Could not detect filesystem type on $DEVICE"
    exit 1
  fi
  echo "[INFO] Filesystem type: $FS_TYPE"

  # Auto-detect mount point
  MOUNT_POINT=$(findmnt -n -o TARGET --source "$DEVICE" || true)
  if [[ -z "$MOUNT_POINT" ]]; then
    echo "[ERROR] Could not detect mount point for $DEVICE"
    exit 1
  fi
  echo "[INFO] Mount point: $MOUNT_POINT"

  # Grow FS
  case "$FS_TYPE" in
    xfs) xfs_growfs "$MOUNT_POINT" ;;
    ext4) resize2fs "$DEVICE" ;;
    *) echo "[ERROR] Unsupported filesystem: $FS_TYPE"; exit 1 ;;
  esac

  echo "[SUCCESS] Extended $DEVICE ($FS_TYPE) mounted at $MOUNT_POINT"
}

attach_volume() {
  if [[ -z "$MOUNT_POINT" || -z "$FS_TYPE" ]]; then
    echo "[ERROR] attach mode requires --mount-point and --fs-type"
    usage
  fi

  echo "[INFO] Formatting $DEVICE as $FS_TYPE"
  case "$FS_TYPE" in
    xfs) mkfs.xfs -f "$DEVICE" ;;
    ext4) mkfs.ext4 -F "$DEVICE" ;;
    *) echo "[ERROR] Unsupported filesystem: $FS_TYPE"; exit 1 ;;
  esac

  mkdir -p "$MOUNT_POINT"

  echo "[INFO] Mounting $DEVICE at $MOUNT_POINT"
  mount "$DEVICE" "$MOUNT_POINT"

  echo "[INFO] Adding fstab entry"
  UUID=$(blkid -s UUID -o value "$DEVICE")
  echo "UUID=$UUID $MOUNT_POINT $FS_TYPE defaults,nofail 0 2" >> /etc/fstab

  echo "[SUCCESS] $DEVICE mounted at $MOUNT_POINT with fstab persistence"
}

case "$MODE" in
  attach) attach_volume ;;
  extend) extend_volume ;;
  *) echo "[ERROR] Unknown mode: $MODE"; usage ;;
esac
