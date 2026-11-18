# "VM Alert Responder" custom agent — instructions

The text block pasted into the custom agent's **instructions** field must reference
*your own* deployment's subscription ID, resource group, VM name, and Log Analytics
workspace — not whichever environment happened to be live when this repo was written.
So instead of a fixed, paste-ready block, this doc now has two parts:

- [`docs/vm-alert-responder-instructions.template.md`](vm-alert-responder-instructions.template.md)
  — the source of truth, with `{{PLACEHOLDER}}` tokens for everything that's
  deployment-specific.
- [`scripts/New-AgentInstructions.ps1`](../scripts/New-AgentInstructions.ps1) — fills in
  those tokens from your `infra/main.bicep` deployment's outputs (and falls back to this
  repo's Bicep defaults, or explicit script parameters, for anything it can't look up) and
  writes the result to `docs/vm-alert-responder-instructions.generated.md`.

## Usage

After `infra/main.bicep` has been deployed (see [`infra/README.md`](../infra/README.md)),
from the repo root:

```powershell
./scripts/New-AgentInstructions.ps1
```

This reads the `main` subscription deployment via `az deployment sub show` by default —
pass `-DeploymentName <name>` if you used a different `--name` at deploy time, or pass
`-SubscriptionId`/`-ResourceGroupName`/`-VmName`/etc. explicitly if you don't have the
deployment record handy (see the script's comment-based help: `Get-Help
./scripts/New-AgentInstructions.ps1 -Full`).

Then copy the contents of the generated
`docs/vm-alert-responder-instructions.generated.md` into the **instructions** field when
creating the custom agent at **Builder → Agent Canvas → + Create custom agent** (name it
`VM Alert Responder`), as part of [`docs/sre-agent-setup.md`](sre-agent-setup.md) step
(h), Step 0.

The generated file is a per-deployment build artifact (git-ignored) — regenerate it any
time your deployment's resource names, alert thresholds, or workspace change, rather than
hand-editing the output.
