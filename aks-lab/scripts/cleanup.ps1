<#
.SYNOPSIS
    Deletes the AKS lab resource group (and everything in it).
.EXAMPLE
    ./cleanup.ps1 -ResourceGroup rg-storage-iops-aks
#>
[CmdletBinding()]
param(
    [string] $ResourceGroup
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$labOut = Join-Path $here '..' 'infra' 'lab-output.json'

if (-not $ResourceGroup -and (Test-Path $labOut)) {
    $ResourceGroup = (Get-Content $labOut -Raw | ConvertFrom-Json).resourceGroup
}
if (-not $ResourceGroup) {
    throw 'Usage: ./cleanup.ps1 -ResourceGroup <name>  (or run after deploy so lab-output.json exists)'
}

Write-Host "==> Deleting resource group $ResourceGroup (this also deletes the AKS node resource group)"
az group delete --name $ResourceGroup --yes --no-wait
Write-Host '    Delete requested (running in background).'
