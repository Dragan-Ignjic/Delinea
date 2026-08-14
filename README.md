# Delinea

A collection of custom integrations, scripts, and helper tooling built around
**Delinea Secret Server** (and related Delinea platform components).

---

## ⚠️ Disclaimer — Provided "AS IS"

Everything in this repository is provided **as is**, without warranty of any
kind, express or implied, including but not limited to warranties of
merchantability, fitness for a particular purpose, and non-infringement.

- This is **not** an officially supported Delinea product.
- **No support, maintenance, or SLA** is offered or implied. Delinea Support
  will not troubleshoot the contents of this repository.
- The authors and Delinea accept **no responsibility or liability** for any
  damage, data loss, downtime, security exposure, or other consequences
  arising from the use of this code.
- Use at **your own risk**. You are responsible for reviewing, testing, and
  validating anything here before running it against a real environment.

**Always test in a non-production environment first, and take a full backup
(database, configuration, encryption keys) before running anything against a
production system.**

---

## What's in here

Typical contents (varies over time):

- **Custom integrations** — connecting Secret Server to third-party systems via
  REST API, webhooks, SCIM, SIEM/syslog, ticketing systems, and similar.
- **Upgrade & migration helpers** — scripts and notes to assist with Secret
  Server version upgrades, on-prem → Delinea Platform moves, configuration
  comparisons, and pre/post-upgrade validation.
- **API samples** — PowerShell / REST examples for authentication, secret
  retrieval, folder and permission management, reporting, and bulk operations.
- **Utilities** — health checks, log parsing, bulk import/export, discovery and
  reporting helpers.

Each subfolder should contain its own `README.md` (or header comments)
describing purpose, prerequisites, and usage. Where it does not, treat the code
as a reference example rather than a finished tool.

---

## Requirements

Requirements differ per script, but commonly:

- A reachable Secret Server instance (on-prem or cloud) with **Web Services /
  REST API enabled**.
- An account with the **minimum permissions** required for the task — avoid
  using a full administrator account where a scoped one will do.
- PowerShell 5.1+ or PowerShell 7+ on Windows, unless a script states otherwise.
- Network access from where you run the script to the Secret Server URL.

---

## Usage notes

1. Read the script before you run it. Every script here can change
   configuration or data.
2. Run against a **test/dev instance** first.
3. Check for rate limits and load impact before running bulk operations against
   production.
4. Verify the Secret Server version compatibility — APIs and behaviour change
   between releases.

---

## Security

- **Never commit secrets.** No passwords, API keys, tokens, connection strings,
  certificates, or customer data belong in this repository.
- Use environment variables, a credential store, or interactive prompts instead
  of hard-coded credentials.
- Sanitize any logs, exports, or sample data before committing.
- If you find a credential or sensitive data committed here, report it and have
  it rotated immediately.

---


## License

Unless a subfolder states otherwise, the contents of this repository are
provided as-is for reference and reuse, with no warranty (see Disclaimer above).
