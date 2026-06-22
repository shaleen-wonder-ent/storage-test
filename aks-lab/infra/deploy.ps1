<#
.SYNOPSIS
    Deploys the AKS shared-storage IOPS lab (VNet, AKS + 2 zonal node pools,
    ANF volume, Azure Files NFS). PowerShell mirror of infra/deploy.sh.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Subscription,
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [string] $Location = 'westus3',
    [string] $NamePrefix = 'iopsaks',
    [string] $NodeVmSize = 'Standard_D8s_v5',
    [ValidateSet('1', '2', '3')] [string] $AlignedZone = '1',
    [ValidateSet('1', '2', '3')] [string] $CrossZone = '2',
    [ValidateSet('Standard', 'Premium', 'Ultra')] [string] $AnfServiceLevel = 'Premium',
    [int] $AnfPoolTiB = 4,
    [int] $AnfVolumeGiB = 2048,
    [int] $FileShareGiB = 100
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "==> Selecting subscription $Subscription"
az account set --subscription $Subscription

Write-Host '==> Registering required resource providers'
foreach ($p in 'Microsoft.NetApp', 'Microsoft.Storage', 'Microsoft.ContainerService', 'Microsoft.Network') {
    az provider register --namespace $p --wait | Out-Null
}

Write-Host "==> Creating resource group $ResourceGroup in $Location"
az group create --name $ResourceGroup --location $Location | Out-Null

$deployName = "storage-iops-aks-$(Get-Date -Format 'yyyyMMddHHmmss')"
Write-Host "==> Deploying Bicep ($deployName) - ~15-25 minutes (AKS + ANF)"

$deployJson = Join-Path $here '.deploy.json'
az deployment group create `
    --name $deployName `
    --resource-group $ResourceGroup `
    --template-file (Join-Path $here 'main.bicep') `
    --parameters `
        location=$Location `
        namePrefix=$NamePrefix `
        nodeVmSize=$NodeVmSize `
        alignedZone=$AlignedZone `
        crossZone=$CrossZone `
        anfServiceLevel=$AnfServiceLevel `
        anfPoolSizeTiB=$AnfPoolTiB `
        anfVolumeSizeGiB=$AnfVolumeGiB `
        fileShareQuotaGiB=$FileShareGiB `
    --output json | Out-File -FilePath $deployJson -Encoding utf8

if ($LASTEXITCODE -ne 0) {
    Write-Error 'Bicep deployment failed. See error above. Aborting.'
    Remove-Item $deployJson -ErrorAction SilentlyContinue
    exit 1
}

$out = (Get-Content $deployJson -Raw | ConvertFrom-Json).properties.outputs

$labOutput = [ordered]@{
    resourceGroup     = $ResourceGroup
    location          = $Location
    aksClusterName    = $out.aksClusterName.value
    nodeResourceGroup = $out.nodeResourceGroup.value
    alignedZone       = $out.alignedZone.value
    crossZone         = $out.crossZone.value
    nfsAccount        = $out.nfsAccount.value
    nfsShare          = $out.nfsShare.value
    nfsHost           = $out.nfsHost.value
    anfMountIp        = $out.anfMountIp.value
    anfMountPath      = $out.anfMountPath.value
}
$labOutput | ConvertTo-Json | Out-File -FilePath (Join-Path $here 'lab-output.json') -Encoding utf8
Remove-Item $deployJson -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "==> Deployment complete. Outputs written to $(Join-Path $here 'lab-output.json')"
Write-Host "    AKS cluster:  $($labOutput.aksClusterName)"
Write-Host "    ANF volume:   $($labOutput.anfMountIp):/$($labOutput.anfMountPath)  (zone $($labOutput.alignedZone))"
Write-Host "    Cross zone:   $($labOutput.crossZone)"
Write-Host ''
Write-Host 'Next: run the fio tests'
Write-Host "    bash $(Join-Path $here '..' 'scripts' 'run-aks-tests.sh') --resource-group $ResourceGroup --subscription $Subscription"
