#!/usr/bin/env bash
# run-followup-tests.sh - Re-runs the cross-zone deep dive (Test 3a + Test 3b
# from Storage-CrossZone-Findings.md) with a configurable `nconnect` value.
#
# This is the test harness for the follow-up runs documented in
# Storage-CrossZone-Findings.md §4.6 (Limitations and future work):
#   * nconnect=16 cross-zone, to quantify how much of the ~3.3x gap is
#     recoverable by raising the NFS transport slot count.
#   * Re-baseline on aligned and any larger-volume scenarios.
#
# Usage (run with sudo):
#   sudo NCONNECT=16 ANF_IP=<mountIp> ANF_PATH=<volumeName> bash run-followup-tests.sh
#
# Or with defaults (NCONNECT=8 to reproduce the original lab):
#   sudo ANF_IP=<mountIp> ANF_PATH=<volumeName> bash run-followup-tests.sh
#
# Output:
#   /tmp/followup-results/<host>-<zone>-nconnect<N>.json   (raw fio JSON)
#   /tmp/followup-results/<host>-<zone>-nconnect<N>.txt    (parsed summary)

set -euo pipefail

NCONNECT=${NCONNECT:-8}
ANF_IP=${ANF_IP:?ANF_IP env var is required (e.g. 10.50.2.4)}
ANF_PATH=${ANF_PATH:?ANF_PATH env var is required (e.g. vol1)}
MOUNT=/mnt/netapp
OUT_DIR=/tmp/followup-results

if ! command -v jq >/dev/null 2>&1; then
    echo "Installing jq..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq >/dev/null
fi

mkdir -p "$OUT_DIR"

HOSTNAME_OUT=$(hostname)
ZONE=$(curl -fsS -H Metadata:true --max-time 3 \
    "http://169.254.169.254/metadata/instance/compute/zone?api-version=2021-02-01&format=text" \
    || echo unknown)
TAG="${HOSTNAME_OUT}-z${ZONE}-nconnect${NCONNECT}"

echo "=========================================================="
echo "  Follow-up test on $HOSTNAME_OUT (zone $ZONE, nconnect=$NCONNECT)"
echo "  $(date -u +%FT%TZ)"
echo "=========================================================="

# ---------- Remount ANF with the chosen nconnect ----------
if mountpoint -q "$MOUNT"; then
    echo "==> Unmounting existing $MOUNT"
    umount "$MOUNT"
fi
echo "==> Mounting $MOUNT with nconnect=$NCONNECT"
mount -t nfs "${ANF_IP}:/${ANF_PATH}" "$MOUNT" \
    -o "vers=4.1,sec=sys,nconnect=${NCONNECT},rsize=262144,wsize=262144,hard,timeo=600,retrans=2"
mkdir -p "${MOUNT}/storage"
chmod 777 "${MOUNT}/storage"

# Show effective mount options
mount | grep "$MOUNT" || true
echo

# ---------- Test 3a: Repeatability (iodepth=64, 4 jobs, 30 s, x3) ----------
echo
echo "##########  Test 3a - Repeatability (iodepth=64, 4 jobs, 30 s, x3)  ##########"
SUMMARY_TXT="${OUT_DIR}/${TAG}-3a.txt"
echo "iter,read_iops,read_lat_us,write_iops,write_lat_us" > "$SUMMARY_TXT"
for i in 1 2 3; do
    OUT_JSON="${OUT_DIR}/${TAG}-3a-iter${i}.json"
    FILE="${MOUNT}/storage/rrw_3a.fio"
    rm -f "$FILE"
    echo
    echo "--- iter $i ---"
    fio --randrepeat=1 --direct=1 --name=t3a \
        --filename="$FILE" --bs=4k --iodepth=64 \
        --size=4G --runtime=30 --time_based \
        --numjobs=4 --group_reporting \
        --readwrite=randrw --rwmixread=75 \
        --output-format=json --output="$OUT_JSON" \
        | tail -n 0   # suppress noisy fio progress
    READ_IOPS=$(jq -r '.jobs[0].read.iops' "$OUT_JSON")
    WRITE_IOPS=$(jq -r '.jobs[0].write.iops' "$OUT_JSON")
    READ_LAT=$(jq -r '.jobs[0].read.lat_ns.mean / 1000' "$OUT_JSON")
    WRITE_LAT=$(jq -r '.jobs[0].write.lat_ns.mean / 1000' "$OUT_JSON")
    printf "  iter=%d  read=%.0f IOPS @ %.1f us   write=%.0f IOPS @ %.1f us\n" \
        "$i" "$READ_IOPS" "$READ_LAT" "$WRITE_IOPS" "$WRITE_LAT"
    printf "%d,%.0f,%.1f,%.0f,%.1f\n" \
        "$i" "$READ_IOPS" "$READ_LAT" "$WRITE_IOPS" "$WRITE_LAT" >> "$SUMMARY_TXT"
done
echo
echo "Test 3a summary saved to $SUMMARY_TXT"
cat "$SUMMARY_TXT"

# ---------- Test 3b: Iodepth sweep (4 jobs, 30 s each, depth 1/4/16/64/256) ----------
echo
echo "##########  Test 3b - Iodepth sweep  ##########"
SWEEP_TXT="${OUT_DIR}/${TAG}-3b.txt"
echo "iodepth,read_iops,read_lat_us,write_iops,write_lat_us" > "$SWEEP_TXT"
for depth in 1 4 16 64 256; do
    OUT_JSON="${OUT_DIR}/${TAG}-3b-d${depth}.json"
    FILE="${MOUNT}/storage/rrw_3b.fio"
    rm -f "$FILE"
    echo
    echo "--- iodepth=$depth ---"
    fio --randrepeat=1 --direct=1 --name=t3b \
        --filename="$FILE" --bs=4k --iodepth="$depth" \
        --size=4G --runtime=30 --time_based \
        --numjobs=4 --group_reporting \
        --readwrite=randrw --rwmixread=75 \
        --output-format=json --output="$OUT_JSON" \
        | tail -n 0
    READ_IOPS=$(jq -r '.jobs[0].read.iops' "$OUT_JSON")
    WRITE_IOPS=$(jq -r '.jobs[0].write.iops' "$OUT_JSON")
    READ_LAT=$(jq -r '.jobs[0].read.lat_ns.mean / 1000' "$OUT_JSON")
    WRITE_LAT=$(jq -r '.jobs[0].write.lat_ns.mean / 1000' "$OUT_JSON")
    printf "  iodepth=%-4d  read=%.0f IOPS @ %.1f us   write=%.0f IOPS @ %.1f us\n" \
        "$depth" "$READ_IOPS" "$READ_LAT" "$WRITE_IOPS" "$WRITE_LAT"
    printf "%d,%.0f,%.1f,%.0f,%.1f\n" \
        "$depth" "$READ_IOPS" "$READ_LAT" "$WRITE_IOPS" "$WRITE_LAT" >> "$SWEEP_TXT"
done
echo
echo "Test 3b summary saved to $SWEEP_TXT"
cat "$SWEEP_TXT"

echo
echo "=========================================================="
echo "  Done on $HOSTNAME_OUT (zone $ZONE, nconnect=$NCONNECT)"
echo "  All raw JSON in $OUT_DIR"
echo "=========================================================="
