#!/usr/bin/env bash
# run-aks-tests.sh - Orchestrates the AKS cross-zone fio experiment.
#
# Steps:
#   1. Pull AKS credentials.
#   2. Substitute the ANF mount IP/path into the static PV manifest.
#   3. Apply ConfigMap (fio runner), PV+PVC, then the aligned & cross-zone Jobs.
#   4. Wait for each Job and stream its logs (IOPS + the actual NFS mount
#      options the pod got).
#
# Reads connection details from infra/lab-output.json (written by deploy.sh).
set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 [options]
  --subscription <id>      Azure subscription ID (optional if already set)
  --resource-group <name>  Resource group name (required unless in lab-output.json)
  --aks-name <name>        AKS cluster name (optional; read from lab-output.json)
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --subscription)   SUBSCRIPTION=$2;  shift 2;;
        --resource-group) RG=$2;            shift 2;;
        --aks-name)       AKS_NAME=$2;      shift 2;;
        -h|--help)        usage; exit 0;;
        *) echo "Unknown arg: $1"; usage; exit 1;;
    esac
done

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
LAB_OUT="$ROOT/infra/lab-output.json"
MANIFESTS="$ROOT/manifests"

[[ -f "$LAB_OUT" ]] || { echo "ERROR: $LAB_OUT not found. Run infra/deploy.sh first." >&2; exit 1; }

jq_out() { jq -r ".$1" "$LAB_OUT"; }
RG=${RG:-$(jq_out resourceGroup)}
AKS_NAME=${AKS_NAME:-$(jq_out aksClusterName)}
ANF_IP=$(jq_out anfMountIp)
ANF_PATH=$(jq_out anfMountPath)
ALIGNED_ZONE=$(jq_out alignedZone)
CROSS_ZONE=$(jq_out crossZone)

: "${RG:?resource group not resolved}"
: "${AKS_NAME:?aks name not resolved}"

if [[ -n "${SUBSCRIPTION:-}" ]]; then
    az account set --subscription "$SUBSCRIPTION"
fi

echo "==> Getting AKS credentials for $AKS_NAME (rg $RG)"
az aks get-credentials --resource-group "$RG" --name "$AKS_NAME" --overwrite-existing

echo "==> Nodes and their zones:"
kubectl get nodes -L lab-role,topology.kubernetes.io/zone

# ---- Substitute ANF mount details into the static PV manifest ----
TMP_PV=$(mktemp)
sed -e "s#__ANF_MOUNT_IP__#${ANF_IP}#g" \
    -e "s#__ANF_MOUNT_PATH__#${ANF_PATH}#g" \
    "$MANIFESTS/pv-anf-static.yaml" > "$TMP_PV"

echo "==> Applying ConfigMap, PV and PVC"
kubectl apply -f "$MANIFESTS/fio-configmap.yaml"
kubectl apply -f "$TMP_PV"
rm -f "$TMP_PV"

# Clean any prior Job runs so logs are fresh.
kubectl delete job fio-aligned fio-crosszone --ignore-not-found

run_job() {
    local job=$1 manifest=$2 label=$3
    echo
    echo "##########################################################"
    echo "  $label  (job/$job)"
    echo "##########################################################"
    kubectl apply -f "$manifest"
    echo "==> Waiting for $job to complete (timeout 10m)..."
    if ! kubectl wait --for=condition=complete "job/$job" --timeout=600s; then
        echo "WARNING: $job did not complete in time; dumping current state and logs anyway." >&2
        kubectl describe "job/$job" || true
    fi
    echo "----- logs: $job -----"
    kubectl logs "job/$job" || true
}

run_job fio-aligned    "$MANIFESTS/fio-aligned.yaml"    "ALIGNED  (node pool in ANF zone $ALIGNED_ZONE)"
run_job fio-crosszone  "$MANIFESTS/fio-crosszone.yaml"  "CROSS-ZONE  (node pool in zone $CROSS_ZONE)"

echo
echo "=========================================================="
echo "  Done. Compare the IOPS lines from the two jobs above."
echo "  Expect: psync ~3x penalty cross-zone; libaio ~no penalty."
echo "=========================================================="
