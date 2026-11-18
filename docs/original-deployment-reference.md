# Original deployment reference (example only)

> ⚠️ **This page documents one specific past deployment of this repo — it is not a
> template or required configuration.** If you're deploying your own copy (see the
> ["Deploying your own copy"](../README.md#deploying-your-own-copy) section in the root
> README), your subscription ID, resource names, public IP, and workspace ID will all
> differ. Identifiers and public endpoints below are placeholders. Use
> `az deployment sub show --name <deployment-name> --query properties.outputs` to
> find *your* deployment's actual values.

- Subscription: `<subscription-name>` (`<subscription-id>`), tenant
  account `<tenant-admin-account>`
- Region: **`eastus2`**
- Resource group: `rg-sre-agent-demo`
- VM: `vm-sre-demo-01` (`Standard_D2_v3`, Windows Server 2022 Datacenter), public IP
  `<vm-public-ip>` / `<vm-fqdn>`
- Log Analytics Workspace: `law-sre-agent-demo` (customer ID `<workspace-customer-id>`)
- Demo app: `http://localhost:8080`, opened from inside the VM via Azure Bastion
