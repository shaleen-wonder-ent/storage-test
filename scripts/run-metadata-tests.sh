#!/usr/bin/env bash
# run-metadata-tests.sh - Metadata-heavy benchmark for evaluating the Azure
# Files "metadata caching for SSD (premium) SMB" feature, and for comparing
# the metadata path of SMB vs Azure Files NFS vs ANF NFS.
#
# WHY THIS EXISTS (read before running):
#   The standard run-fio-tests.sh profile (4k randrw against ONE pre-created
#   file) is pure DATA I/O. After the initial open it issues almost no
#   metadata ops, so it will NOT show any difference whether the metadata
#   cache is on or off. The metadata-caching feature only accelerates the
#   Create / Open / Close / Delete APIs:
#       https://learn.microsoft.com/azure/storage/files/smb-performance
#   This script drives exactly those APIs across many small files, which is
#   also representative of the customer's WebSphere small-file/classloading
#   ("read this cache file -> render it") access pattern.
#
# BEFORE/AFTER METHOD (the feature is SUBSCRIPTION-scoped, not per-account):
#   1. Run this BEFORE finishing activation     -> "before" numbers
#        (you have only done Register-AzProviderFeature; the cache is not
#         live until the provider is re-registered AND the Azure Files team
#         confirms enablement on the storage account).
#   2. Register-AzResourceProvider -ProviderNamespace Microsoft.Storage
#        + confirm enablement with the Azure Files team.
#   3. Run this AGAIN on the same account        -> "after" numbers
#
# Usage (run with sudo on each VM, same model as run-fio-tests.sh):
#   sudo PHASE_TAG=before bash run-metadata-tests.sh
#   sudo PHASE_TAG=after  bash run-metadata-tests.sh
#
# Tunables (env vars):
#   NFILES   - small files per job        (default 20000)
#   NUMJOBS  - parallel jobs              (default 4)
#   RUNTIME  - seconds for the read-churn phase (default 60)
#   PHASE_TAG- free-form label for output (default "run")
#
# Output:
#   /tmp/metadata-results/<host>-z<zone>-<backend>-<phase>-<test>.log  (full fio)
#   Console summary (IOPS / ops-per-sec + latency) per backend per phase.

set -euo pipefail

NFILES=${NFILES:-20000}
NUMJOBS=${NUMJOBS:-4}
RUNTIME=${RUNTIME:-60}
PHASE_TAG=${PHASE_TAG:-run}
OUT_DIR=/tmp/metadata-results

MOUNTS=(
    "azurefiles_smb=/mnt/fileshare"
    "azurefiles_nfs=/mnt/nfsshare"
    "netapp_nfs=/mnt/netapp"
)

if ! command -v fio >/dev/null 2>&1; then
    echo "Installing fio..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq fio >/dev/null
fi

mkdir -p "$OUT_DIR"

HOSTNAME_OUT=$(hostname)
ZONE=$(curl -fsS -H Metadata:true --max-time 3 \
    "http://169.254.169.254/metadata/instance/compute/zone?api-version=2021-02-01&format=text" \
    || echo unknown)

echo "=========================================================="
echo "  Metadata test on $HOSTNAME_OUT (zone $ZONE, phase=$PHASE_TAG)"
echo "  files/job=$NFILES  jobs=$NUMJOBS  read-churn=${RUNTIME}s"
echo "  $(date -u +%FT%TZ)"
echo "=========================================================="
echo

# ---- helpers -------------------------------------------------------------

# Run one fio invocation, save full output, and echo the headline lines.
_run() {
    local backend=$1 test=$2 dir=$3; shift 3
    local log="${OUT_DIR}/${HOSTNAME_OUT}-z${ZONE}-${backend}-${PHASE_TAG}-${test}.log"
    rm -rf "$dir"; mkdir -p "$dir"
    echo "    [$backend] $test ..."
    if fio --name="$test" --directory="$dir" \
           --nrfiles="$NFILES" --numjobs="$NUMJOBS" --group_reporting \
           "$@" >"$log" 2>&1; then
        grep -E 'IOPS=|iops|lat \(usec\)|lat \(msec\)|clat percentiles' "$log" \
            | sed 's/^/        /' | head -n 6
    else
        echo "        FAILED - see $log"
        tail -n 3 "$log" | sed 's/^/        /'
    fi
    rm -rf "$dir" || true
    echo
}

# CREATE: open(O_CREAT)+close per file -> exercises Create + Close.
phase_create() { _run "$1" "create" "$2/mdtest_create" \
    --ioengine=filecreate --filesize=4k; }

# STAT: stat() per file (files are created first by fio) -> lookup / getattr.
phase_stat()   { _run "$1" "stat" "$2/mdtest_stat" \
    --ioengine=filestat --filesize=4k; }

# READ CHURN: open + 4k read + close across many small files, with a bounded
# working set of open FDs so files are constantly opened/closed. Closest match
# to the WebSphere "read this small cache file and render it" pattern.
phase_readchurn() { _run "$1" "readchurn" "$2/mdtest_read" \
    --ioengine=psync --rw=randread --bs=4k --filesize=4k \
    --file_service_type=random --openfiles=64 \
    --runtime="$RUNTIME" --time_based --direct=0; }

# DELETE: unlink() per file (files are created first by fio) -> Delete.
phase_delete() { _run "$1" "delete" "$2/mdtest_delete" \
    --ioengine=filedelete --filesize=4k; }

# ---- main ----------------------------------------------------------------

for entry in "${MOUNTS[@]}"; do
    backend=${entry%=*}; path=${entry#*=}
    echo "########## $backend ($path) ##########"
    if ! mountpoint -q "$path"; then
        echo "    SKIPPED ($path is not mounted)"
        echo
        continue
    fi
    base="${path}/storage/meta"
    phase_create    "$backend" "$base"
    phase_stat      "$backend" "$base"
    phase_readchurn "$backend" "$base"
    phase_delete    "$backend" "$base"
done

echo "=========================================================="
echo "  Done on $HOSTNAME_OUT (zone $ZONE, phase $PHASE_TAG)"
echo "  Raw logs: $OUT_DIR"
echo "=========================================================="
