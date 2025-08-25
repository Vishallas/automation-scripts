#!/bin/bash
set -euo pipefail


usage () {
	cat <<'EOF'
Usage : volume-manager.sh --device <device>  --mount-point <mount-point> --fs-type <filesystem>

Required: 

	--device          Device which have to be mounted to ( eg. /dev/nvme1n1 )
	--mount-point     Directory to which the volume has to be attached ( eg. /data )
	--fs-type         Filesystem Type for the mount point  ( eg. xfs )

Optional:
	
	-h | --help       Help
EOF


# --- CONFIGURATION ---
DEVICE=""          
MOUNT_POINT=""
FS_TYPE=""                   # Use xfs for Docker workloads

while [[ $# -gt 0 ]]; do
	case "$1" in 
		--device)  DEVICE="$2"; shift 2 ;;
		--mount-point) MOUNT_POINT="$2"; shift 2 ;;
		--fs-type) FS_TYPE="$2"; shift 2 ;;
		-h|--help) usage ;;
		*) echo "Unknow arg: $1"; usage; exit 1 ;;
	easc
done


# --- CHECK DEVICE EXISTS ---
if [ ! -b "$DEVICE" ]; then
  echo "[ERROR] Block device $DEVICE not found. Run 'lsblk' to verify."
  exit 1
fi

# --- INSTALL REQUIRED TOOLS ---
if ! command -v mkfs.$FS_TYPE >/dev/null 2>&1; then
  echo "[INFO] Installing $FS_TYPE tools..."
  if [ -f /etc/debian_version ]; then
    sudo apt-get update -y && sudo apt-get install -y xfsprogs
  elif [ -f /etc/redhat-release ]; then
    sudo yum install -y xfsprogs
  fi
fi

# --- FORMAT IF NEEDED ---
if blkid "$DEVICE" >/dev/null 2>&1; then
  echo "[WARN] $DEVICE already has a filesystem. Skipping mkfs."
else
  echo "[INFO] Creating $FS_TYPE filesystem on $DEVICE..."
  sudo mkfs.$FS_TYPE -f "$DEVICE"
fi

# --- CREATE MOUNT DIRECTORY ---
sudo mkdir -p "$MOUNT_POINT"

# --- GET UUID OF DEVICE ---
UUID=$(sudo blkid -s UUID -o value "$DEVICE")

# --- BACKUP FSTAB ---
sudo cp /etc/fstab /etc/fstab.bak.$(date +%F_%H%M%S)

# --- ADD TO FSTAB IF NOT EXISTS ---
if grep -q "$UUID" /etc/fstab; then
  echo "[INFO] UUID already present in /etc/fstab"
else
  echo "[INFO] Adding fstab entry..."
  echo "UUID=$UUID  $MOUNT_POINT  $FS_TYPE  defaults,nofail  0  2" | sudo tee -a /etc/fstab
fi

# --- MOUNT AND VERIFY ---
sudo mount -a

if df -hT | grep -q "$MOUNT_POINT"; then
  echo "[SUCCESS] $DEVICE mounted on $MOUNT_POINT and persisted in /etc/fstab"
else
  echo "[ERROR] Mount verification failed."
  exit 1
fi
