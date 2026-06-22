#!/usr/bin/env bash
# cleanup.sh - Deletes the AKS lab resource group (and everything in it).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
LAB_OUT="$ROOT/infra/lab-output.json"

RG=${1:-}
if [[ -z "$RG" && -f "$LAB_OUT" ]]; then
    RG=$(jq -r '.resourceGroup' "$LAB_OUT")
fi
: "${RG:?Usage: $0 <resource-group>  (or run after deploy so lab-output.json exists)}"

echo "==> Deleting resource group $RG (this also deletes the AKS node resource group)"
az group delete --name "$RG" --yes --no-wait
echo "    Delete requested (running in background)."
