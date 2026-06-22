#!/usr/bin/env bash
# Deploys the AKS shared-storage IOPS lab (VNet, AKS + 2 zonal node pools,
# ANF volume, Azure Files NFS). Mirrors the VM lab's infra/deploy.sh.
set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 [options]
  --subscription <id>          Azure subscription ID (required)
  --resource-group <name>      Resource group name (required)
  --location <region>          Azure region (default: westus3)
  --name-prefix <s>            Resource name prefix (default: iopsaks)
  --node-vm-size <sku>         Workload node size (default: Standard_D8s_v5)
  --aligned-zone <1|2|3>       Zone for ANF + aligned node pool (default: 1)
  --cross-zone <1|2|3>         Zone for the cross-zone node pool (default: 2)
  --anf-service-level <s>      Standard|Premium|Ultra (default: Premium)
  --anf-pool-tib <n>           Capacity pool size in TiB (default: 4)
  --anf-volume-gib <n>         ANF volume size in GiB (default: 2048)
  --file-share-gib <n>         Azure Files NFS share quota in GiB (default: 100)
EOF
}

LOCATION=westus3
NAME_PREFIX=iopsaks
NODE_VM_SIZE=Standard_D8s_v5
ALIGNED_ZONE=1
CROSS_ZONE=2
ANF_SVC=Premium
ANF_POOL_TIB=4
ANF_VOL_GIB=2048
FILE_SHARE_GIB=100

while [[ $# -gt 0 ]]; do
    case $1 in
        --subscription)        SUBSCRIPTION=$2;     shift 2;;
        --resource-group)      RG=$2;               shift 2;;
        --location)            LOCATION=$2;         shift 2;;
        --name-prefix)         NAME_PREFIX=$2;      shift 2;;
        --node-vm-size)        NODE_VM_SIZE=$2;     shift 2;;
        --aligned-zone)        ALIGNED_ZONE=$2;     shift 2;;
        --cross-zone)          CROSS_ZONE=$2;       shift 2;;
        --anf-service-level)   ANF_SVC=$2;          shift 2;;
        --anf-pool-tib)        ANF_POOL_TIB=$2;     shift 2;;
        --anf-volume-gib)      ANF_VOL_GIB=$2;      shift 2;;
        --file-share-gib)      FILE_SHARE_GIB=$2;   shift 2;;
        -h|--help)             usage; exit 0;;
        *) echo "Unknown arg: $1"; usage; exit 1;;
    esac
done

: "${SUBSCRIPTION:?--subscription is required}"
: "${RG:?--resource-group is required}"

HERE=$(cd "$(dirname "$0")" && pwd)

echo "==> Selecting subscription $SUBSCRIPTION"
az account set --subscription "$SUBSCRIPTION"

echo "==> Registering required resource providers"
for p in Microsoft.NetApp Microsoft.Storage Microsoft.ContainerService Microsoft.Network; do
    az provider register --namespace "$p" --wait >/dev/null
done

echo "==> Creating resource group $RG in $LOCATION"
az group create --name "$RG" --location "$LOCATION" >/dev/null

DEPLOY_NAME="storage-iops-aks-$(date +%Y%m%d%H%M%S)"
echo "==> Deploying Bicep ($DEPLOY_NAME) - ~15-25 minutes (AKS + ANF)"

if ! az deployment group create \
    --name "$DEPLOY_NAME" \
    --resource-group "$RG" \
    --template-file "$HERE/main.bicep" \
    --parameters \
        location="$LOCATION" \
        namePrefix="$NAME_PREFIX" \
        nodeVmSize="$NODE_VM_SIZE" \
        alignedZone="$ALIGNED_ZONE" \
        crossZone="$CROSS_ZONE" \
        anfServiceLevel="$ANF_SVC" \
        anfPoolSizeTiB="$ANF_POOL_TIB" \
        anfVolumeSizeGiB="$ANF_VOL_GIB" \
        fileShareQuotaGiB="$FILE_SHARE_GIB" \
    --output json > "$HERE/.deploy.json"; then
    echo "ERROR: Bicep deployment failed. See error above. Aborting." >&2
    rm -f "$HERE/.deploy.json"
    exit 1
fi

jq_get() { jq -r ".properties.outputs.$1.value" "$HERE/.deploy.json"; }

AKS_NAME=$(jq_get aksClusterName)
NODE_RG=$(jq_get nodeResourceGroup)
ALIGNED_ZONE_OUT=$(jq_get alignedZone)
CROSS_ZONE_OUT=$(jq_get crossZone)
NFS_ACCT=$(jq_get nfsAccount)
NFS_SHARE=$(jq_get nfsShare)
NFS_HOST=$(jq_get nfsHost)
ANF_IP=$(jq_get anfMountIp)
ANF_PATH=$(jq_get anfMountPath)

cat > "$HERE/lab-output.json" <<JSON
{
    "resourceGroup":    "$RG",
    "location":         "$LOCATION",
    "aksClusterName":   "$AKS_NAME",
    "nodeResourceGroup":"$NODE_RG",
    "alignedZone":      "$ALIGNED_ZONE_OUT",
    "crossZone":        "$CROSS_ZONE_OUT",
    "nfsAccount":       "$NFS_ACCT",
    "nfsShare":         "$NFS_SHARE",
    "nfsHost":          "$NFS_HOST",
    "anfMountIp":       "$ANF_IP",
    "anfMountPath":     "$ANF_PATH"
}
JSON

rm -f "$HERE/.deploy.json"

echo
echo "==> Deployment complete. Outputs written to $HERE/lab-output.json"
echo "    AKS cluster:  $AKS_NAME"
echo "    ANF volume:   ${ANF_IP}:/${ANF_PATH}  (zone $ALIGNED_ZONE_OUT)"
echo "    Cross zone:   $CROSS_ZONE_OUT"
echo
echo "Next: run the fio tests"
echo "    bash $HERE/../scripts/run-aks-tests.sh --resource-group $RG --subscription $SUBSCRIPTION"
