#!/usr/bin/env bash
# inspect-mount.sh - The highest-value AKS-only check.
#
# Spins up a short-lived pod on each workload node pool (aligned + cross-zone),
# mounts the ANF volume via the same static PVC, and dumps the ACTUAL NFS
# mount options the pod received (nconnect, rsize/wsize, vers). This answers
# the question the VM lab structurally cannot: "does the AKS mount path set
# the same options we hand-tuned on the VMs?" If nconnect is missing, AKS
# performance can differ from the VM lab even when zone-aligned.
#
# Run AFTER run-aks-tests.sh has applied the PV/PVC (or apply them first).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
MANIFESTS="$ROOT/manifests"

# Make sure the PV/PVC exist (no-op if already applied).
if ! kubectl get pvc anf-pvc >/dev/null 2>&1; then
    echo "ERROR: PVC anf-pvc not found. Run scripts/run-aks-tests.sh first (it applies the PV/PVC)." >&2
    exit 1
fi

inspect() {
    local role=$1
    local pod="inspect-${role}"
    echo
    echo "##########################################################"
    echo "  Mount options on the '${role}' node pool"
    echo "##########################################################"
    kubectl delete pod "$pod" --ignore-not-found >/dev/null 2>&1 || true
    kubectl run "$pod" \
        --image=ubuntu:24.04 \
        --restart=Never \
        --overrides="$(cat <<JSON
{
  "spec": {
    "nodeSelector": { "lab-role": "${role}" },
    "containers": [{
      "name": "inspect",
      "image": "ubuntu:24.04",
      "command": ["/bin/bash","-c",
        "apt-get update -qq && apt-get install -y -qq nfs-common >/dev/null; echo '--- nfsstat -m ---'; nfsstat -m; echo '--- mount | grep netapp ---'; mount | grep -E '/mnt/netapp' || true"],
      "volumeMounts": [{ "name": "anf", "mountPath": "/mnt/netapp" }]
    }],
    "volumes": [{ "name": "anf", "persistentVolumeClaim": { "claimName": "anf-pvc" } }]
  }
}
JSON
)" \
        --command -- /bin/bash >/dev/null

    kubectl wait --for=condition=Ready "pod/$pod" --timeout=180s || true
    # Container may exit quickly; wait for logs to be available.
    sleep 5
    kubectl logs "$pod" || true
    kubectl delete pod "$pod" --ignore-not-found >/dev/null 2>&1 || true
}

inspect aligned
inspect crosszone

echo
echo "=========================================================="
echo "  Look for 'nconnect=8' and 'rsize/wsize=262144' above."
echo "  If absent, the AKS mount path is NOT matching the VM lab"
echo "  and that alone can change aligned performance."
echo "=========================================================="
