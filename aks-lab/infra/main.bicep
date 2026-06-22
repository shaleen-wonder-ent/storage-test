// Azure Shared-Storage IOPS Test Lab - AKS variant
// Deploys: VNet, an AKS cluster with two zone-pinned user node pools
// (aligned = ANF zone, cross-zone = a different zone), an Azure NetApp Files
// account/pool/volume pinned to the aligned zone, and an Azure Files NFS
// share for comparison.
//
// The point of this lab (vs the VM lab) is to reproduce the cross-zone ANF
// behaviour on the platform the customer actually runs (AKS pods, CSI/NFS
// mount path, zone scheduling) and to validate the zone-affinity fix
// end-to-end. See aks-lab/README.md.

@description('Location for all resources. Default westus3 (an ANF-zonal region).')
param location string = 'westus3'

@description('Short prefix used in resource names. Lowercase letters/digits only.')
@minLength(3)
@maxLength(8)
param namePrefix string = 'iopsaks'

@description('Node VM size for the workload (aligned/cross-zone) pools. Matches the VM lab.')
param nodeVmSize string = 'Standard_D8s_v5'

@description('Node VM size for the small system pool.')
param systemVmSize string = 'Standard_D4s_v5'

@description('Availability zone for the ANF volume and the "aligned" node pool.')
@allowed([ '1', '2', '3' ])
param alignedZone string = '1'

@description('Availability zone for the "cross-zone" node pool. Must differ from alignedZone.')
@allowed([ '1', '2', '3' ])
param crossZone string = '2'

@description('Azure NetApp Files service level.')
@allowed([ 'Standard', 'Premium', 'Ultra' ])
param anfServiceLevel string = 'Premium'

@description('ANF capacity pool size in TiB (minimum 1, must be >= volume size).')
@minValue(1)
@maxValue(500)
param anfPoolSizeTiB int = 4

@description('ANF volume size in GiB. 2048 = 2 TiB.')
@minValue(100)
param anfVolumeSizeGiB int = 2048

@description('Azure Files NFS share quota in GiB.')
@minValue(100)
param fileShareQuotaGiB int = 100

// ---------- naming ----------
var suffix = toLower(uniqueString(resourceGroup().id))
var vnetName = '${namePrefix}-vnet'
var aksSubnetName = 'aks-subnet'
var anfSubnetName = 'anf-subnet'
var aksName = '${namePrefix}-aks'
var nfsAccountName = toLower('${namePrefix}nfs${suffix}')
var anfAccountName = '${namePrefix}-anf'
var anfPoolName = 'pool1'
var anfVolumeName = 'vol1'
var shareName = 'storage'

var poolSizeBytes = anfPoolSizeTiB * 1024 * 1024 * 1024 * 1024
var volumeSizeBytes = anfVolumeSizeGiB * 1024 * 1024 * 1024

// ---------- network ----------
// AKS gets its own subnet; ANF needs a delegated subnet in the same VNet so
// the pods can reach the volume's mount target over the in-VNet (and
// cross-zone) network path. CNI overlay keeps node-subnet IP usage low.
resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: { addressPrefixes: [ '10.50.0.0/16' ] }
    subnets: [
      {
        name: aksSubnetName
        properties: {
          addressPrefix: '10.50.1.0/24'
          serviceEndpoints: [
            { service: 'Microsoft.Storage' }
          ]
        }
      }
      {
        name: anfSubnetName
        properties: {
          addressPrefix: '10.50.2.0/24'
          serviceEndpoints: [
            { service: 'Microsoft.Storage' }
          ]
          delegations: [
            {
              name: 'anf-delegation'
              properties: { serviceName: 'Microsoft.NetApp/volumes' }
            }
          ]
        }
      }
    ]
  }
}

resource aksSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' existing = {
  parent: vnet
  name: aksSubnetName
}

resource anfSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' existing = {
  parent: vnet
  name: anfSubnetName
}

// ---------- AKS cluster ----------
// System pool is kept tiny and pinned to the aligned zone. The two workload
// pools are created as child resources below so they can carry node labels
// the fio Jobs select on.
resource aks 'Microsoft.ContainerService/managedClusters@2024-05-01' = {
  name: aksName
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    dnsPrefix: '${namePrefix}-dns'
    agentPoolProfiles: [
      {
        name: 'systempool'
        mode: 'System'
        count: 1
        vmSize: systemVmSize
        osType: 'Linux'
        osSKU: 'Ubuntu'
        type: 'VirtualMachineScaleSets'
        vnetSubnetID: aksSubnet.id
        availabilityZones: [ alignedZone ]
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkPolicy: 'none'
      loadBalancerSku: 'standard'
      podCidr: '10.244.0.0/16'
      serviceCidr: '10.51.0.0/16'
      dnsServiceIP: '10.51.0.10'
    }
  }
}

// Aligned workload pool: same zone as the ANF volume (best case).
resource alignPool 'Microsoft.ContainerService/managedClusters/agentPools@2024-05-01' = {
  parent: aks
  name: 'alignpool'
  properties: {
    mode: 'User'
    count: 1
    vmSize: nodeVmSize
    osType: 'Linux'
    osSKU: 'Ubuntu'
    type: 'VirtualMachineScaleSets'
    vnetSubnetID: aksSubnet.id
    availabilityZones: [ alignedZone ]
    nodeLabels: {
      'lab-role': 'aligned'
      'lab-zone': alignedZone
    }
  }
}

// Cross-zone workload pool: a different zone than the ANF volume (worst case).
resource crossPool 'Microsoft.ContainerService/managedClusters/agentPools@2024-05-01' = {
  parent: aks
  name: 'crosspool'
  properties: {
    mode: 'User'
    count: 1
    vmSize: nodeVmSize
    osType: 'Linux'
    osSKU: 'Ubuntu'
    type: 'VirtualMachineScaleSets'
    vnetSubnetID: aksSubnet.id
    availabilityZones: [ crossZone ]
    nodeLabels: {
      'lab-role': 'crosszone'
      'lab-zone': crossZone
    }
  }
  // Serialize pool creation to avoid concurrent cluster-write conflicts.
  dependsOn: [ alignPool ]
}

// ---------- Azure Files: NFS (comparison backend) ----------
resource nfsAccount 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: nfsAccountName
  location: location
  kind: 'FileStorage'
  sku: { name: 'Premium_LRS' }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: false
    allowSharedKeyAccess: true
    largeFileSharesState: 'Enabled'
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      virtualNetworkRules: [
        { id: aksSubnet.id, action: 'Allow' }
      ]
    }
  }
}

resource nfsShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2024-01-01' = {
  name: '${nfsAccount.name}/default/${shareName}'
  properties: {
    shareQuota: fileShareQuotaGiB
    enabledProtocols: 'NFS'
    rootSquash: 'NoRootSquash'
    accessTier: 'Premium'
  }
}

// ---------- Azure NetApp Files ----------
resource anfAccount 'Microsoft.NetApp/netAppAccounts@2024-03-01' = {
  name: anfAccountName
  location: location
  properties: {}
}

resource anfPool 'Microsoft.NetApp/netAppAccounts/capacityPools@2024-03-01' = {
  parent: anfAccount
  name: anfPoolName
  location: location
  properties: {
    serviceLevel: anfServiceLevel
    size: poolSizeBytes
    qosType: 'Auto'
  }
}

resource anfVolume 'Microsoft.NetApp/netAppAccounts/capacityPools/volumes@2024-03-01' = {
  parent: anfPool
  name: anfVolumeName
  location: location
  zones: [ alignedZone ]
  properties: {
    creationToken: anfVolumeName
    serviceLevel: anfServiceLevel
    usageThreshold: volumeSizeBytes
    subnetId: anfSubnet.id
    protocolTypes: [ 'NFSv4.1' ]
    networkFeatures: 'Standard'
    exportPolicy: {
      rules: [
        {
          ruleIndex: 1
          unixReadOnly: false
          unixReadWrite: true
          nfsv3: false
          nfsv41: true
          allowedClients: '10.50.0.0/16'
          hasRootAccess: true
          kerberos5ReadOnly: false
          kerberos5ReadWrite: false
          kerberos5iReadOnly: false
          kerberos5iReadWrite: false
          kerberos5pReadOnly: false
          kerberos5pReadWrite: false
        }
      ]
    }
  }
}

// ---------- outputs ----------
output aksClusterName string = aks.name
output nodeResourceGroup string = aks.properties.nodeResourceGroup
output alignedZone string = alignedZone
output crossZone string = crossZone

output nfsAccount string = nfsAccount.name
output nfsShare string = shareName
output nfsHost string = replace(replace(nfsAccount.properties.primaryEndpoints.file, 'https://', ''), '/', '')

output anfMountIp string = anfVolume.properties.mountTargets[0].ipAddress
output anfMountPath string = anfVolume.properties.creationToken
output anfZone string = alignedZone
