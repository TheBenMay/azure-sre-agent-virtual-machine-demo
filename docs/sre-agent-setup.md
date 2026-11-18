# Azure SRE Agent — Demo Setup Runbook

This runbook walks a presenter/admin through standing up **Azure SRE Agent** against the
`rg-sre-agent-demo` resource group for the customer demo (Windows Server 2022 VM
`vm-sre-demo-01`, Log Analytics Workspace, and Azure Monitor alert rules for error-count,
CPU, and memory).

> **Naming note:** `rg-sre-agent-demo`, `vm-sre-demo-01`, etc. used throughout this doc are
> the *default* parameter values from `infra/main.bicep`/`main.parameters.json` (see
> `infra/README.md`). If you deployed with different overrides, substitute your own
> resource/VM names everywhere below — and when generating the custom agent's
> instructions in step (h), `scripts/New-AgentInstructions.ps1` will pick up your actual
> deployed names/IDs automatically instead of these defaults.

Reference documentation:

- https://learn.microsoft.com/en-us/azure/sre-agent/create-and-set-up
- https://learn.microsoft.com/en-us/azure/sre-agent/permissions
- https://learn.microsoft.com/en-us/azure/sre-agent/azure-monitor-alerts
- https://learn.microsoft.com/en-us/azure/sre-agent/incident-platforms
- https://learn.microsoft.com/en-us/azure/sre-agent/incident-response-plans

---

## (a) Prerequisites — roles needed to run this setup

Before starting, confirm the person running setup has:

1. **To create the agent resource itself** (in `rg-sre-agent-demo` or the subscription):
   **Owner**, or **Contributor + User Access Administrator**, on the subscription or
   resource group where the agent will be created. This lets the onboarding wizard deploy
   the agent and assign the creator the **SRE Agent Administrator** role on it.
   (Source: [create-and-set-up — Prerequisites](https://learn.microsoft.com/en-us/azure/sre-agent/create-and-set-up))
2. **To grant the agent access to `rg-sre-agent-demo`** (step (e) below): an active
   **Owner** or **User Access Administrator** role assignment on that resource group,
   directly or via inheritance. If using PIM, activate the eligible role before you start.
   (Source: same page, Prerequisites table)
3. **To grant the subscription-scope `Monitoring Contributor` role** (needed for the agent
   to acknowledge/close Azure Monitor alerts — see step (d)): **Owner** or
   **User Access Administrator** at the **subscription** scope. This is a materially
   higher-privilege ask than (2) — call it out explicitly to whoever is running setup, and
   get it approved/assigned by someone with subscription-level access if the presenter
   doesn't already have it.
4. Network access to `https://sre.azure.com` and `*.azuresre.ai` from the browser used for
   setup.
5. A work/school (Microsoft Entra ID) account. **Personal Microsoft accounts (MSA) cannot
   authorize the on-behalf-of (OBO) elevation prompt** used in step (g)/(h) below, even if
   granted the SRE Agent Administrator role — use a tenant account for anyone expected to
   approve remediation during the demo.
   (Source: [permissions — On-behalf-of (OBO)](https://learn.microsoft.com/en-us/azure/sre-agent/permissions))

---

## (b) Create the agent via the onboarding wizard

1. Browse to **https://sre.azure.com** and sign in with your Entra ID (work/school) account.
2. Select **Create agent**. The wizard has three stages: **Basics → Review → Deploy**.
3. On **Basics**, fill in:
   - **Subscription** — the subscription that contains `rg-sre-agent-demo`.
   - **Resource group** — select the **existing** `rg-sre-agent-demo` resource group (do
     not create a new one; it must already contain the VM/workspace from the infra
     workstream).
   - **Agent name** — e.g. `sre-agent-demo` (pick something unique in the subscription).
   - **Region** — match the region the `rg-sre-agent-demo` resources were deployed to
     (check `infra/` output/parameters once published; do not assume co-location is
     required, but keeping it in-region simplifies latency/compliance discussion).
   - **Model provider** — pick any available provider for your subscription/region (e.g.
     Azure OpenAI or Anthropic — the list varies by tenant). Note: in EU Data Boundary
     regions the wizard labels providers as EUDB-covered or excluded; pick based on your
     compliance requirements for the demo.
   - **Application Insights** — choose **Create new** unless the infra workstream has
     already published an Application Insights resource you should reuse.
4. Select **Next**, confirm the **Review** summary (subscription, resource group, agent
   name, region all correct), then select **Create**.
5. Wait for deployment (typically 2–5 minutes). This provisions:
   - A **user-assigned managed identity (UAMI)** plus a **system-assigned identity (SAMI)**
     on the agent. The UAMI is used for all connector authentication and Azure RBAC
     assignments going forward — **no separate app registration or service principal is
     needed**.
   - A role assignment giving **you** (the creator) **SRE Agent Administrator** on the new
     agent — this is the role required later to approve OBO elevation prompts.
   - The Azure SRE Agent resource itself.
   - A new Application Insights + Log Analytics workspace, only if you chose "Create new"
     in step 3.
6. Select **Set up your agent** to open the setup page (**Quickstart** tab: Code, Logs,
   Azure resources, Incidents).

(Source: [create-and-set-up](https://learn.microsoft.com/en-us/azure/sre-agent/create-and-set-up))

> **Confirmed:** As of this writing there is **no Bicep/ARM template or `az` CLI command**
> documented to create the SRE Agent resource itself — it is a manual, portal-driven step
> via the wizard above. Do not attempt to script this step.

---

## (c) Connect the Log Analytics workspace as a "Logs" telemetry source

1. On the **Quickstart** tab, find the **Logs** card and select the **+** button.
2. In **Configure logging provider**, select **Log Analytics Workspace**.
3. Select **Next** and point it at the Log Analytics workspace deployed into
   `rg-sre-agent-demo` by the infra workstream (`logAnalyticsWorkspaceName` in
   `infra/modules/monitoring.bicep`).
4. Select **Next** to review, then **Add connector**.
5. **Checkpoint:** The **Logs** card shows a green checkmark and lists the connected
   workspace.
6. Ask the agent to verify access, e.g.: `Check for any errors in the last 24 hours`.

Connecting a Log Analytics/Application Insights source causes the portal to automatically
assign **Log Analytics Reader** and **Monitoring Reader** to the agent's UAMI — this is the
same pair of roles granted by the resource-group connector in step (e), so there's no
conflict if both are configured.

(Source: [create-and-set-up — Connect your logs](https://learn.microsoft.com/en-us/azure/sre-agent/create-and-set-up))

---

## (d) Connect Azure Monitor as the incident platform

1. In the agent portal, go to **Builder → Incident platform**.
2. Select **Azure Monitor** and save. This uses the agent's own managed identity — **no
   credentials to configure**.
3. The scanner checks for new alerts every **1 minute**, with an initial lookback of 1 day
   (max scan window 29 days). Repeated firings of the same alert rule merge into a single
   investigation thread (merge lookback 7 days) instead of creating duplicate work.
4. Alerts begin flowing within a few minutes of connecting, for any subscription in scope.

> ⚠️ **Only one incident platform can be active at a time.** If this tenant's agent is
> later pointed at PagerDuty or ServiceNow for a different demo, reconnecting Azure Monitor
> here will disconnect it, and vice versa — confirm before the demo that Azure Monitor is
> still the active incident platform.
> (Source: [incident-platforms](https://learn.microsoft.com/en-us/azure/sre-agent/incident-platforms))

5. **Important:** connecting an incident platform auto-creates a default **"quickstart"**
   response plan. Go to **Builder → Incident response plans → Table view** and either
   delete the quickstart plan or confirm its autonomy level, so it doesn't race with the
   dedicated response plan you configure in step (g). (Source:
   [incident-response-plans](https://learn.microsoft.com/en-us/azure/sre-agent/incident-response-plans))

Troubleshooting if alerts don't appear: confirm the UAMI has **Monitoring Contributor** on
the subscription (step (e)/(f) below), confirm alert rules exist for resources in
`rg-sre-agent-demo`, and confirm the rules have actually fired in Azure Monitor.
(Source: [azure-monitor-alerts](https://learn.microsoft.com/en-us/azure/sre-agent/azure-monitor-alerts))

---

## (e) Grant the agent **Reader** access to `rg-sre-agent-demo`

We are using **Reader** permission level by design (recommend-only / human-approves-first):
the agent gets read/diagnose access only, and must request **temporary elevation via
on-behalf-of (OBO)** before taking any write action (e.g. running a script on the VM).

### Preferred path — portal "Azure resources" connector (auto-assigns roles)

1. On the **Quickstart** tab, find the **Azure resources** card and select **Add resources**.
2. Choose resource type **Resource group**, select **Next**.
3. Filter by subscription, search for `rg-sre-agent-demo`, select it.
4. Select **Next** to review agent permissions.
5. Choose permission level **Reader** (not Privileged). Review the role list — the portal
   assigns at minimum:
   - **Reader** (view resources/properties)
   - **Log Analytics Reader** (query logs/workspaces)
   - **Monitoring Reader** (access metrics/monitoring data)
   - plus any additional **reader-only** roles required by resource types detected in the
     group (e.g. a VM-specific reader role) — Privileged would add contributor-equivalent
     roles instead; we are intentionally not selecting Privileged.
6. Select **Add resource group**. Role assignment can take several minutes to propagate.
7. **Checkpoint:** The **Azure Resources** card lists `rg-sre-agent-demo`.

This step requires **Owner** or **User Access Administrator** on `rg-sre-agent-demo` (see
prerequisite (2)), because you are delegating RBAC to the agent's managed identity.

(Source: [create-and-set-up — Add Azure resource access](https://learn.microsoft.com/en-us/azure/sre-agent/create-and-set-up),
[permissions — Permission levels](https://learn.microsoft.com/en-us/azure/sre-agent/permissions))

### CLI fallback — `scripts/grant-sre-agent-access.ps1`

If the portal connector is unavailable or you need to re-apply/verify the role
assignments out of band, use the companion script:

```powershell
# Find the agent's UAMI object ID first:
#   Agent portal: Settings > Azure settings > Go to Identity
#   or Azure portal: the agent's Container App resource > Identity > Object (principal) ID
./scripts/grant-sre-agent-access.ps1 `
  -UamiObjectId "<object-id-of-the-agent-uami>" `
  -ResourceGroupName "rg-sre-agent-demo" `
  -SubscriptionId "<subscription-id>"
```

This script idempotently assigns **Reader**, **Log Analytics Reader**, and
**Monitoring Reader** at the `rg-sre-agent-demo` scope — the same base roles the portal
wizard assigns automatically for Reader level. It intentionally does **not** run the
subscription-scope `Monitoring Contributor` assignment (see step (f)); that line is present
but commented out, since it needs separate, more-privileged execution.

(Source: [permissions — Grant access to resources](https://learn.microsoft.com/en-us/azure/sre-agent/permissions))

### Note on VM remediation access (the `VM Alert Responder` custom agent)

The `VM Alert Responder` custom agent (step (h) below) needs one additional, narrowly
scoped grant beyond the Reader-level access above: the ability to invoke Azure Run Command
on `vm-sre-demo-01` to execute approved remediation scripts. This is **not** part of the
Reader connector and is **not** the built-in `Virtual Machine Contributor` role — use
[`scripts/grant-vm-runcommand-role.ps1`](../scripts/grant-vm-runcommand-role.ps1) instead,
which creates/assigns a custom role containing only the Run Command create/read/delete
actions, scoped to that single VM resource. See the "Prerequisites" section of
[`docs/vm-alert-responder-instructions.md`](vm-alert-responder-instructions.md) for why:
keeping this grant minimal and VM-scoped preserves the same "Reader is the real control"
design principle used for the rest of the agent's access (see step (h) below), even though
this one capability is a write action.

---

## (f) Subscription-scope `Monitoring Contributor` (alert lifecycle)

Regardless of Reader vs. Privileged, the agent also needs **Monitoring Contributor at the
subscription scope** so it can acknowledge and close Azure Monitor alerts as part of the
incident workflow. **This requires Owner or User Access Administrator at the subscription
level** — a materially higher privilege than the resource-group grant in step (e). If the
person running this demo setup only has RG-level access, get someone with subscription
Owner/UAA to run this assignment separately (see the commented-out line in
`scripts/grant-sre-agent-access.ps1`, or assign it from the wizard in step (b)/(e) if the
portal surfaces it during resource-group onboarding).

(Source: [permissions — Preconfigured roles](https://learn.microsoft.com/en-us/azure/sre-agent/permissions))

---

## (g) Optional: connect this GitHub repo as a code source

1. On the **Quickstart** tab, **Code** card, select **+** (tooltip: **Connect repositories**).
2. Choose **GitHub**, pick an auth method (your account, a PAT, or a bring-your-own GitHub
   App — GitHub Enterprise Cloud requires a GitHub App).
3. Select **Next**, choose this repository (`azure-sre-agent-virtual-machine`), **Save**.
4. **Checkpoint:** the **Code** card shows a green checkmark and lists the repo.

Connecting the repo lets the agent correlate the VM/alert investigation with the demo
app's source (e.g. the error/stress endpoints and the `SREDemoApp` event-log source used by
`infra/modules/monitoring.bicep`) via its "deep context" code exploration.

(Source: [create-and-set-up — Connect your code repository](https://learn.microsoft.com/en-us/azure/sre-agent/create-and-set-up))

---

## (h) Configure the Incident Response Plan: no auto-execute

> **Confirmed the hard way (2026-10-14):** an Incident Response Plan (IRP) **requires a
> custom agent to already exist** as its response handler — there is no default/built-in
> handler. If you skip straight to creating a plan with zero custom agents configured, the
> plan cannot be created at all. Do step 0 below first. Also confirmed: **there is no
> programmatic/API/CLI path for creating either a custom agent or an IRP** — both are
> portal-UI-only (verified by asking the agent's own chat directly; it has no tool for
> either). Connecting Azure Monitor as the incident platform (step (d)) is necessary but
> **not sufficient** — without a custom agent + IRP, the agent can see fired alerts if you
> ask it directly in chat, but takes **no autonomous action** and opens no investigation
> thread on its own.

### Step 0 — Create a custom agent first

1. Go to **Builder → Agent Canvas → + Create custom agent**.
2. Name it e.g. `VM Alert Responder`.
3. Generate instructions scoped to *your* deployment (your subscription/resource
   group/VM/workspace, not a hardcoded example):
   ```powershell
   ./scripts/New-AgentInstructions.ps1
   ```
   This renders `docs/vm-alert-responder-instructions.template.md` (describing the
   environment, the 3 alert rules, and an investigation playbook) into
   `docs/vm-alert-responder-instructions.generated.md` using your deployment's outputs —
   see [`docs/vm-alert-responder-instructions.md`](vm-alert-responder-instructions.md) for
   details. Copy the generated file's contents into the instructions field.
4. Save.

### Step 1 — Create the response plan

1. Go to **Builder → Incident response plans → New incident response plan** (or use the
   **+** on the custom-agent node in **Agent Canvas**).
2. Set the **incident filter** to match this demo's alerts. There is **no picker to select
   specific alert rules** — filtering is criteria-based only. The simplest single filter
   that matches all 3 of this demo's rules (`alert-sre-demo-error-count`,
   `alert-sre-demo-cpu-high`, `alert-sre-demo-memory-high`) is:
   **Title contains: `alert-sre-demo`**.
3. Set **Agent autonomy level** to **Review** (not the default **Autonomous**). This makes
   the demo's "approve before acting" behavior explicit and intentional rather than
   incidental.
4. Set **Response custom agent** to the `VM Alert Responder` agent created in Step 0.
5. If you considered Autonomous for drama's sake: note that even in Autonomous mode, if the
   managed identity only has **Reader** (our case), the agent still cannot act — it will
   request OBO/Administrator authorization before taking any write action, because the UAMI
   lacks write permissions. **Reader level is therefore the real control here**; Review
   mode is a second, belt-and-suspenders layer so the demo narrative is unambiguous in the
   UI as well.
6. Delete or disable the auto-created "quickstart" response plan from step (d) if you
   haven't already, so it doesn't duplicate-route or race with this plan.
7. Save the plan.

(Source: [incident-response-plans](https://learn.microsoft.com/en-us/azure/sre-agent/incident-response-plans),
[permissions — On-behalf-of (OBO) — "Autonomous incident response" scenario](https://learn.microsoft.com/en-us/azure/sre-agent/permissions))

---

## Validation checklist

Run through this before the live demo:

The app supports **Generate 10 Errors**, **Generate 30 Errors**, and a configurable
**Memory Test**; it no longer has a CPU stress button or endpoint. The CPU alert remains
deployed, but deliberately triggering it is not part of this app-based checklist.
The thresholds below are the defaults in [`infra/modules/alerts.bicep`](../infra/modules/alerts.bicep);
check the deployed rules for any overrides.

- [ ] Connect to `vm-sre-demo-01` through **Azure Portal → Connect → Bastion**, open
      **`http://localhost:8080`** in the VM's browser, and confirm the demo console loads.
      Confirm `http://localhost:8080/api/status` returns the memory limits and job status.
- [ ] Confirm the Logs and Azure resources connectors point to your deployment, Azure
      Monitor is the active incident platform, and the response plan routes
      `alert-sre-demo` alerts to **VM Alert Responder** with **Review** autonomy.
      Disable/delete any competing quickstart plan.
- [ ] Confirm recent `Heartbeat` and `Perf` records from the VM are reaching the connected
      Log Analytics workspace. For memory, check `ObjectName == "Memory"` and
      `CounterName == "% Committed Bytes In Use"`; a current Heartbeat alone does not
      confirm performance-counter collection is working.
- [ ] Click **Generate 30 Errors** (or POST `{"count":30}` to `/api/errors` on the VM).
      Confirm the app reports successful writes and the workspace's `Event` table shows
      `Source == "SREDemoApp"` and `EventLevelName == "Error"`. Confirm
      **`alert-sre-demo-error-count`** fires: the default threshold is **at least 10
      matching events in 5 minutes**, evaluated every 5 minutes. Allow for ingestion and
      evaluation delay.
- [ ] In **Memory Test**, set **Amount (MB)** and **Hold duration (seconds)**, then click
      **Test Memory** (or POST `{"sizeMB":4096,"durationSec":900}` to
      `/api/stress/memory` on the VM, adjusting the amount for its capacity).
      Confirm **Memory job: running** and the allocated amount in the app's activity log.
      Stay within the reported limits: **90% of system RAM** and **3600 seconds**.
- [ ] Confirm **`alert-sre-demo-memory-high`** fires in **Monitor → Alerts** for
      `rg-sre-agent-demo`. It requires an average **`% Committed Bytes In Use` of at
      least 70% over 5 minutes**, evaluated every 5 minutes. Rehearse a 600–900 second
      hold and choose an amount that sustains the deployed threshold without making the
      VM unresponsive. Neither the app's default 1024 MB nor the 4096 MB example guarantees
      a breach: this counter depends on existing committed memory and the page file,
      not just physical RAM. Check the `Perf` values and, after the job ends, adjust the
      amount/duration within the limits if needed.
- [ ] Confirm the SRE Agent **acknowledges** the alert and opens an **investigation
      thread** within ~1–2 minutes of each alert firing (scanner interval is 1 minute).
      Repeated firings of the same rule may merge into an existing investigation.
- [ ] Confirm the investigation thread correlates logs/metrics/code and produces a
      **recommendation** (not just raw data).
- [ ] Confirm that when the agent (or a presenter prompting it) attempts any
      remediation — e.g. restarting a service or running a script via Run Command on
      `vm-sre-demo-01` — it **stops and prompts for OBO/elevation approval** rather than
      acting immediately, and that only a user with **SRE Agent Administrator** can
      approve that prompt.
- [ ] After the hold duration expires, confirm **Memory job: idle** (or
      `memory.active == false` in `/api/status`), memory telemetry falls below the
      threshold, and the alerts resolve after their recovery evaluations. Stop generating
      errors and leave the VM responsive for the live demo.

---

## Notes for other workstreams

- **Resource group name assumption:** this doc and `scripts/grant-sre-agent-access.ps1`
  assume `rg-sre-agent-demo`. If `infra/` lands with a different name, update both.
- **VM name assumption:** `vm-sre-demo-01`, per the task brief — `infra/modules/vm.bicep`
  takes `vmName` as a parameter with no hardcoded default, so confirm the parameter file
  sets it to `vm-sre-demo-01` once published.
- **Role names to match if infra or scripts reference RBAC elsewhere:** `Reader`,
  `Log Analytics Reader`, `Monitoring Reader` (resource-group scope), `Monitoring
  Contributor` (subscription scope) — all verified exact strings via `az role definition
  list`.
- **Alert rule names/thresholds:** defined in `infra/modules/alerts.bicep`:
  `alert-sre-demo-error-count` (at least 10 errors in 5 minutes),
  `alert-sre-demo-memory-high` (average committed memory at least 70% over 5 minutes),
  and `alert-sre-demo-cpu-high` (average CPU at least 50% over 5 minutes).
  The app exercises the error-count and memory alerts only; the CPU rule remains available
  for other CPU-load scenarios.
