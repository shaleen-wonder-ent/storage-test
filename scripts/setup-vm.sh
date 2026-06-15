#!/usr/bin/env bash
# setup-vm.sh - Installs tools and mounts the 3 shares used by the lab.
#
# Usage (run with sudo):
#   sudo bash setup-vm.sh <SMB_ACCOUNT> <SMB_KEY> <NFS_ACCOUNT> <ANF_MOUNT_IP> <ANF_MOUNT_PATH>
#
# Result:
#   /mnt/fileshare  -> Azure Files SMB
#   /mnt/nfsshare   -> Azure Files NFS
#   /mnt/netapp     -> Azure NetApp Files NFS

set -euo pipefail

if [[ $# -lt 5 ]]; then
    echo "Usage: $0 <SMB_ACCOUNT> <SMB_KEY> <NFS_ACCOUNT> <ANF_MOUNT_IP> <ANF_MOUNT_PATH>"
    exit 1
fi

SMB_ACCOUNT=$1
SMB_KEY=$2
NFS_ACCOUNT=$3
ANF_IP=$4
ANF_PATH=$5
SHARE_NAME=storage

echo "==> Installing cifs-utils, nfs-common, fio, jq"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq cifs-utils nfs-common fio jq >/dev/null

mkdir -p /mnt/fileshare /mnt/nfsshare /mnt/netapp

# ---------- Azure Files SMB (best-effort) ----------
# Many enterprise tenants enforce `allowSharedKeyAccess=false` via Azure
# Policy, which blocks SMB shared-key auth even though the Bicep enables it.
# We attempt the mount but treat failure as non-fatal so the NFS tests can
# still run. The reference findings were captured in such a tenant; SMB is
# documented as excluded there.
if [[ -n "${SMB_KEY:-}" ]]; then
    echo "==> Attempting Azure Files SMB mount at /mnt/fileshare (may be blocked by tenant policy)"
    CREDS=/etc/smbcredentials/${SMB_ACCOUNT}.cred
    mkdir -p /etc/smbcredentials
    cat > "$CREDS" <<EOF
username=${SMB_ACCOUNT}
password=${SMB_KEY}
EOF
    chmod 600 "$CREDS"

    SMB_HOST=${SMB_ACCOUNT}.file.core.windows.net
    if mount -t cifs "//${SMB_HOST}/${SHARE_NAME}" /mnt/fileshare \
        -o "credentials=${CREDS},dir_mode=0777,file_mode=0777,serverino,nosharesock,actimeo=30,vers=3.1.1"; then
        echo "    SMB mount OK."
    else
        echo "    SMB mount FAILED — likely tenant policy (allowSharedKeyAccess=false). Skipping SMB tests."
    fi
else
    echo "==> No SMB key provided — skipping SMB mount."
fi

# ---------- Azure Files NFS ----------
# Use nconnect=8 to match ANF for apples-to-apples comparison. Without this
# the two NFS endpoints would not be directly comparable on absolute IOPS.
echo "==> Mounting Azure Files NFS at /mnt/nfsshare"
NFS_HOST=${NFS_ACCOUNT}.file.core.windows.net
mount -t nfs "${NFS_HOST}:/${NFS_ACCOUNT}/${SHARE_NAME}" /mnt/nfsshare \
    -o "vers=4,minorversion=1,sec=sys,nconnect=8"

# ---------- Azure NetApp Files NFS ----------
# nconnect=8 is the lab default. ANF supports up to nconnect=16; bump it to
# 16 if you want to test how much of the cross-zone gap is recoverable
# (see Storage-CrossZone-Findings.md §4.6 future work).
echo "==> Mounting Azure NetApp Files NFS at /mnt/netapp"
mount -t nfs "${ANF_IP}:/${ANF_PATH}" /mnt/netapp \
    -o "vers=4.1,sec=sys,nconnect=8,rsize=262144,wsize=262144,hard,timeo=600,retrans=2"

# ---------- Create the storage/ subdirs the fio commands write into ----------
mkdir -p /mnt/nfsshare/storage /mnt/netapp/storage
chmod 777 /mnt/nfsshare/storage /mnt/netapp/storage
if mountpoint -q /mnt/fileshare; then
    mkdir -p /mnt/fileshare/storage
    chmod 777 /mnt/fileshare/storage
fi

echo
echo "==> Mounts:"
df -hT | grep -E 'cifs|nfs' || true
echo
echo "==> Setup complete. You can now run: bash /tmp/run-fio-tests.sh"
