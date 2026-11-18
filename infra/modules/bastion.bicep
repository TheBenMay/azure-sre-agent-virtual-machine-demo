// bastion.bicep
// Azure Bastion (Basic SKU) + its required Standard public IP, deployed into the
// AzureBastionSubnet carved out by networking.bicep (only when deployBastion = true there).
//
// Why this exists: direct inbound RDP (3389) and HTTP (8080) access to the VM's public IP was
// observed to be silently blocked end-to-end (NSG/Windows Firewall confirmed correctly
// configured; traffic vanished at hop 1 in tracert) when connecting from a network routing
// through a corporate VPN/Global Secure Access tunnel - confirmed not specific to this VM, since
// an unrelated Azure VM's public IP was also unreachable from the same network. Azure Bastion
// connects via the Azure portal's own HTTPS session rather than a direct inbound connection to
// the VM's public IP, so it is unaffected by that class of block.
//
// Basic SKU only supports the in-portal browser-based RDP/SSH session (no native client
// tunneling, no shareable link) - sufficient for this demo.

@description('Azure region for all resources in this module.')
param location string

@description('Base name used to derive resource names (Bastion host, public IP).')
param baseName string = 'sre-demo'

@description('Resource ID of the AzureBastionSubnet (output of networking.bicep).')
param bastionSubnetId string

@description('Azure Bastion SKU. Basic is sufficient for the in-portal browser RDP session used by this demo; Standard adds native-client tunneling, shareable links, and other features not needed here.')
param bastionSku string = 'Basic'

var publicIpName = 'pip-bastion-${baseName}'
var bastionName = 'bastion-${baseName}'

resource bastionPublicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: publicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2023-11-01' = {
  name: bastionName
  location: location
  sku: {
    name: bastionSku
  }
  properties: {
    ipConfigurations: [
      {
        name: 'bastion_ip_config'
        properties: {
          subnet: {
            id: bastionSubnetId
          }
          publicIPAddress: {
            id: bastionPublicIp.id
          }
        }
      }
    ]
  }
}

@description('Resource ID of the Azure Bastion host.')
output bastionId string = bastion.id

@description('DNS name of the Azure Bastion host (e.g. bst-<guid>.bastion.azure.com).')
output bastionFqdn string = bastion.properties.dnsName
