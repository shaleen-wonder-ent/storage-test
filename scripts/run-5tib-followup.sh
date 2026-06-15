#!/usr/bin/env bash
# Drives both nconnect=8 and nconnect=16 follow-up runs against the resized
# (5 TiB) ANF volume and tags the result files with the volume size so the
# 2 TiB run is not overwritten.
set -euo pipefail

ANF_IP="${ANF_IP:-10.50.2.4}"
ANF_PATH="${ANF_PATH:-vol1}"
RESULTS=/tmp/followup-results
mkdir -p "$RESULTS/2tib"

echo "=== Archiving 2 TiB result files ==="
shopt -s nullglob
moved=0
for f in "$RESULTS"/*-nconnect*-3{a,b}*.txt; do
  case "$f" in
    *2tib*|*5tib*) continue ;;
  esac
  mv "$f" "$RESULTS/2tib/$(basename "$f")"
  moved=$((moved+1))
done
echo "Archived $moved file(s) to $RESULTS/2tib"
shopt -u nullglob

for N in 8 16; do
  echo
  echo "=================================================================="
  echo "=== 5 TiB run @ nconnect=$N"
  echo "=================================================================="
  sudo NCONNECT="$N" ANF_IP="$ANF_IP" ANF_PATH="$ANF_PATH" \
       bash /tmp/run-followup-tests.sh
done

# Tag the just-produced files with a 5tib- prefix so subsequent runs do not
# clobber them either.
shopt -s nullglob
for f in "$RESULTS"/*-nconnect*-3{a,b}*.txt; do
  case "$f" in
    *2tib*|*5tib*) continue ;;
  esac
  d=$(dirname "$f"); base=$(basename "$f")
  mv "$f" "$d/5tib-$base"
done
shopt -u nullglob

echo
echo "=================================================================="
echo "=== Summary of 5 TiB result files"
echo "=================================================================="
ls -la "$RESULTS"/5tib-* 2>/dev/null || true
