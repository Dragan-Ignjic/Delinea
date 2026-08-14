# Platform Upgrade

Tools and scripts used to support the move from **Secret Server Cloud** to the
**Delinea Platform**.

These are working aids collected during real migrations — reports, checks, and
helpers used to understand the state of a tenant before the upgrade, and to
verify it afterwards. They are not a migration tool and do not perform the
upgrade itself.

## Typical use

- **Pre-upgrade discovery** — report on users, groups, folders, secrets,
  templates, permissions, and configuration that need attention or cleanup
  before the move.
- **Data hygiene** — surface stale, disabled, orphaned, or duplicated objects
  that are better resolved before migrating rather than after.
- **Remediation** — fix up the objects those reports flag, so they migrate
  cleanly.
- **Post-upgrade verification** — re-run the same reports and compare the
  before/after output to confirm nothing was lost or unexpectedly changed.

## Contents

| File | Type | Description |
| --- | --- | --- |
| `Report_AutomaticDisabledUsers.sql` | SQL, read-only | Lists users that Secret Server automatically disabled because they were disabled or removed in Active Directory. |
| `EnableDisableUsers.ps1` | PowerShell, **makes changes** | For each user id in a CSV, enables then immediately disables the user via the Secret Server Cloud REST API. Clears the automatic-AD-disable flag while leaving the account disabled. |

---

## Report_AutomaticDisabledUsers.sql

Read-only query against the Secret Server database. Returns users where
`DisabledByAutomaticADUserDisabling = 1`, i.e. accounts Secret Server disabled
on its own because Active Directory reported them as disabled or missing.

Use it to size the problem before the upgrade, and to produce the input list for
`EnableDisableUsers.ps1`. Export the result to CSV — the `UserId` column is the
`userid` the script expects.

## EnableDisableUsers.ps1

Takes a CSV of Secret Server Cloud user ids and, for each one, PATCHes
`enabled = true` then `enabled = false`. The enable clears the
automatic-AD-disable flag; the immediate disable puts the account back into a
plain, manually disabled state.

**This script briefly enables each account.** During that short window the user
is active and could sign in. It does not check whether the user still exists in
AD/Entra first. Run with `-WhatIf` and review the list before doing a real run.

### Input

A CSV with a `userid` column (override with `-IdColumn`). `username`,
`displayname`, and `emailaddress` are used for display and logging if present,
but are not required. Non-numeric and empty ids are skipped and logged, and
duplicate ids are collapsed.

### Usage

```powershell
# Preview only - no changes made
.\EnableDisableUsers.ps1 -TenantHost example.secretservercloud.com `
    -CsvPath ".\users.csv" -WhatIf

# Interactive: prompts for anything not supplied, then one confirmation
.\EnableDisableUsers.ps1 -TenantHost example.secretservercloud.com `
    -Username admin -CsvPath ".\users.csv"

# Fully unattended
.\EnableDisableUsers.ps1 -TenantHost example.secretservercloud.com `
    -Username admin -Password 'p@ss' -CsvPath ".\users.csv" -BatchMode
```

### Parameters

| Parameter | Description |
| --- | --- |
| `-TenantHost` | Full tenant host name, e.g. `example.secretservercloud.com`. A pasted URL is accepted and normalised. Prompted if omitted. |
| `-Username` | Secret Server Cloud user to authenticate as. Prompted if omitted. |
| `-Password` | Password. Prompted for securely (masked) if omitted. |
| `-CsvPath` | Path to the input CSV. Prompted if omitted. |
| `-IdColumn` | Name of the CSV column holding the user id. Defaults to `userid`. |
| `-BatchMode` | Skip the confirmation prompt and process every row unattended. |
| `-WhatIf` | Preview only — lists what would be changed and makes no API calls. |

### Output

Two timestamped files are written to **the folder the script lives in** — there
is no prompt or parameter for the location:

- `ReEnableDisable_<tenant>_<yyyyMMdd_HHmmss>.log` — human-readable run log.
- `ReEnableDisable_<tenant>_<yyyyMMdd_HHmmss>.csv` — one row per action, with
  status and details, for auditing.

If a disable step fails after its enable succeeded, that account is **left
enabled**. Those rows are marked in both logs — check them and disable the
account manually.

### Requirements

- The authenticating account needs permission to edit users in the target
  tenant.
- Network access from the machine running the script to the tenant URL.
- PowerShell 5.1+ or PowerShell 7+.

---

## Notes

- SQL scripts here are **read-only reports** unless the file header says
  otherwise. PowerShell scripts may change data — read the header and run with
  `-WhatIf` first where it is supported.
- Run reports **before and after** the upgrade and keep both outputs — the
  comparison is usually more useful than either result on its own.
- Output can contain user names, email addresses, and other tenant-specific
  data. Treat exports and logs accordingly and do not commit them to this
  repository.
- Everything here is provided **as is**, with no warranty or support. See the
  [repository README](../README.md) for the full disclaimer.
