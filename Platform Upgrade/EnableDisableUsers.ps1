<#
.SYNOPSIS
    Re-enables then disables a list of Secret Server Cloud (SSC) users supplied in a CSV, so each
    user ends in a plain (manually) disabled state. This is a stripped-down copy of
    ReEnableDisableUsersSSC.ps1 with NO Active Directory / Entra existence check - it simply reads
    each 'userid' from the CSV and processes it.

.DESCRIPTION
    Authenticates directly to a Secret Server Cloud tenant (OAuth2 password grant, the same
    pattern as Test-SSCAuthentication.ps1 / AuditSSCTenants.ps1), then reads a CSV of users and,
    for each one, ENABLES the user and then DISABLES it via the SSC user PATCH API:

        PATCH https://<tenant>.secretservercloud.com/api/v1/users/{id}
        body: { "id": <id>, "enabled": { "dirty": true, "value": true|false } }

    Enabling (value=true) clears the automatic-AD-disable flag
    (DisabledByAutomaticADUserDisabling in the DB); the immediate follow-up disable (value=false)
    puts the account back into a normal disabled state instead of the "disabled by automatic AD
    user disabling" state. Net effect: the user stays disabled, but no longer flagged as
    automatically disabled. No PII is removed by this script.

    The {id} is the Secret Server Cloud user id, taken from the CSV's 'userid' column.

    Flow:
      1. Authenticate to SSC and verify the token (users/current).
      2. Import the CSV and collect a valid 'userid' from every row.
      3. Show the final list to be re-enabled/disabled and ask for ONE confirmation
         (skipped with -BatchMode; previewed only with -WhatIf).
      4. For each id: PATCH enabled=true, then PATCH enabled=false. Every result is logged to a
         .log and a .csv.

    The CSV only needs a 'userid' column. If present, 'username'/'displayname'/'emailaddress' are
    used for display and logging, but nothing else in the CSV is required.

.PARAMETER TenantHost
    The full SSC tenant host name, e.g. "example.secretservercloud.com". A pasted URL
    ("https://example.secretservercloud.com/") is accepted and normalised. Prompted if omitted.

.PARAMETER Username
    SSC username to authenticate with. Prompted if omitted.

.PARAMETER Password
    SSC password. If omitted, prompted for securely (masked).

.PARAMETER CsvPath
    Path to the CSV of users to re-enable/disable. Prompted if omitted.

.PARAMETER IdColumn
    Name of the CSV column holding the SSC user id. Defaults to 'userid'.

.PARAMETER BatchMode
    Skip the single confirmation prompt and process all rows unattended.

.PARAMETER WhatIf
    Preview only. Lists which users WOULD be re-enabled/disabled and makes no PATCH calls.

.NOTES
    This script briefly ENABLES each user before disabling it again. During that short window the
    account is active. It does NOT remove PII, and (unlike ReEnableDisableUsersSSC.ps1) it does
    NOT verify the user still exists in AD/Entra first. Run with -WhatIf first.

    The .log and .csv output are always written to the folder the script itself lives in.
    There is no prompt or parameter for the log location.

.EXAMPLE
    .\EnableDisableUsers.ps1 -TenantHost example.secretservercloud.com -CsvPath ".\users.csv" -WhatIf

.EXAMPLE
    .\EnableDisableUsers.ps1 -TenantHost example.secretservercloud.com -Username admin -CsvPath ".\users.csv"

.EXAMPLE
    # Fully unattended
    .\EnableDisableUsers.ps1 -TenantHost example.secretservercloud.com -Username admin `
        -Password 'p@ss' -CsvPath ".\users.csv" -BatchMode
#>

[CmdletBinding()]
param(
    [string]$TenantHost,
    [string]$Username,
    [string]$Password,
    [string]$CsvPath,
    [string]$IdColumn = "userid",
    [switch]$BatchMode,
    [switch]$WhatIf
)

# =====================================================================================
# INTERACTIVE CONFIGURATION
# =====================================================================================
Write-Host "`n=== Secret Server Cloud - Re-enable then disable CSV users (no AD/Entra check) ===" -ForegroundColor Magenta
Write-Host "Authenticates to SSC and, for each CSV row, PATCHes enabled=true then enabled=false.`n" -ForegroundColor Cyan

# --- SSC tenant host name, e.g. example.secretservercloud.com ---
# Accepts a pasted URL too: any protocol, trailing slash, or path is stripped and only the
# host name is kept. A bare label with no dot is rejected - the full host name is required.
function Resolve-TenantHost {
    param([string]$Value)
    $h = ($Value -replace '^\s*https?://', '').Trim().Trim('"', ' ')
    $h = ($h -split '[/?#]')[0].TrimEnd('.')      # drop any path/query and a trailing dot
    if ($h -notmatch '^[A-Za-z0-9][A-Za-z0-9\.\-]*\.[A-Za-z]{2,}$') { return $null }
    return $h.ToLowerInvariant()
}

if ($TenantHost) {
    $resolved = Resolve-TenantHost $TenantHost
    if (-not $resolved) {
        Write-Host "[ERROR] -TenantHost must be the full host name, e.g. example.secretservercloud.com" -ForegroundColor Red
        exit 1
    }
    $TenantHost = $resolved
}
else {
    while (-not $TenantHost) {
        $entered = Read-Host "SSC tenant host name (e.g. example.secretservercloud.com)"
        $TenantHost = Resolve-TenantHost $entered
        if (-not $TenantHost) {
            Write-Host "   Enter the full host name, e.g. example.secretservercloud.com" -ForegroundColor Yellow
        }
    }
}
$TenantUrl = "https://$TenantHost"

# --- SSC credentials ---
while (-not $Username) {
    $Username = (Read-Host "SSC username").Trim()
    if (-not $Username) { Write-Host "   Username is required." -ForegroundColor Yellow }
}

# Read the password securely (masked) unless it was supplied as a parameter.
$PasswordPlain = $Password
if (-not $PasswordPlain) {
    $Secure = $null
    while (-not $Secure -or $Secure.Length -eq 0) {
        $Secure = Read-Host "SSC password" -AsSecureString
        if (-not $Secure -or $Secure.Length -eq 0) { Write-Host "   Password is required." -ForegroundColor Yellow }
    }
    $PasswordPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    )
}

# --- CSV path ---
while (-not $CsvPath) {
    $CsvPath = (Read-Host "Path to the CSV of users to re-enable/disable").Trim('"', ' ')
    if (-not $CsvPath) { Write-Host "   CSV path is required." -ForegroundColor Yellow }
}
if (-not (Test-Path -LiteralPath $CsvPath)) {
    Write-Host "[ERROR] CSV not found: $CsvPath" -ForegroundColor Red
    exit 1
}

# --- Log location: always the folder this script lives in (never prompted) ---
# $PSScriptRoot is empty when the script body is run as a selection rather than as a file,
# so fall back to the current location in that case.
$LogDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$LogDir = $LogDir.TrimEnd('\')

if (-not (Test-Path -LiteralPath $LogDir)) {
    Write-Host "[ERROR] Script folder '$LogDir' is not accessible - cannot write logs." -ForegroundColor Red
    exit 1
}

# A short tenant label for filenames: the first DNS label of the host name.
$TenantLabel = ($TenantHost -split '\.')[0]
$stamp      = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogPath    = "$LogDir\ReEnableDisable_$($TenantLabel)_$stamp.log"
$CsvLogPath = "$LogDir\ReEnableDisable_$($TenantLabel)_$stamp.csv"
"Timestamp,UserId,Username,Action,Status,Details" | Out-File -FilePath $CsvLogPath -Encoding utf8

# =====================================================================================
# HELPER FUNCTIONS
# =====================================================================================
function Write-Log {
    param (
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS", "DEBUG")][string]$Level = "INFO",
        [System.ConsoleColor]$Color = "White",
        [switch]$NoNewline
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level] $Message"
    try { $LogEntry | Out-File -FilePath $LogPath -Append -Encoding utf8 }
    catch { Write-Error "Failed to write to log file: $($_.Exception.Message)" }
    if ($NoNewline) { Write-Host $Message -ForegroundColor $Color -NoNewline }
    else { Write-Host $Message -ForegroundColor $Color }
}

function Write-CsvLog {
    param($UserId, $User, $Action, $Status, $Details)
    $Time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $cleanDetails = if ($Details) { '"' + $Details.ToString().Replace('"', '""') + '"' } else { '""' }
    "$Time,`"$UserId`",`"$User`",`"$Action`",`"$Status`",$cleanDetails" | Add-Content -Path $CsvLogPath
}

function Get-HttpErrorMessage {
    # Extracts an HTTP status code and (when present) the API's error body from a caught error.
    param($ErrorRecord)
    $status = $null
    try { $status = $ErrorRecord.Exception.Response.StatusCode.value__ } catch { }
    $msg = $ErrorRecord.Exception.Message
    try {
        $stream = $ErrorRecord.Exception.Response.GetResponseStream()
        if ($stream) {
            $reader = New-Object System.IO.StreamReader($stream)
            $body = $reader.ReadToEnd()
            if ($body) { $msg = "$msg | $body" }
        }
    } catch { }
    return [PSCustomObject]@{ Status = $status; Message = $msg }
}

function Set-SscUserEnabled {
    <#
        PATCHes a single SSC user's 'enabled' state via /api/v1/users/{id}, using the
        UpdateFieldValueOfBoolean "dirty flag" convention the API expects. Returns the parsed
        UserModel response (which includes the resulting 'enabled' boolean) or throws on failure.
    #>
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][bool]$Enabled
    )
    $body = @{
        id      = $Id
        enabled = @{ dirty = $true; value = $Enabled }
    } | ConvertTo-Json -Depth 4
    return Invoke-RestMethod -Uri "$BaseUrl/api/v1/users/$Id" -Method Patch -Headers $Headers -Body $body
}

# =====================================================================================
# AUTHENTICATION (Secret Server Cloud)
# =====================================================================================
Write-Log -Message "=== CONFIGURATION SUMMARY ===" -Color Magenta
Write-Log -Message "SSC tenant:   $TenantUrl" -Color Gray
Write-Log -Message "Username:     $Username" -Color Gray
Write-Log -Message "CSV:          $CsvPath" -Color Gray
Write-Log -Message "Id column:    $IdColumn" -Color Gray
Write-Log -Message "Dir check:    DISABLED (this script never checks AD/Entra)" -Color Gray
Write-Log -Message "Mode:         $(if ($WhatIf) { 'WHATIF (no changes)' } elseif ($BatchMode) { 'BATCH (no confirmation)' } else { 'INTERACTIVE (single confirmation)' })" -Color Gray
Write-Log -Message "Log folder:   $LogDir" -Color Gray

Write-Log -Message "`n=== SSC AUTHENTICATION ===" -Color Magenta
Write-Log -Message "Requesting OAuth2 token from $TenantUrl..." -Color Yellow

$TokenBody = @{
    username   = $Username
    password   = $PasswordPlain
    grant_type = "password"
}

$Headers = $null
try {
    $TokenResponse = Invoke-RestMethod -Uri "$TenantUrl/oauth2/token" -Method Post -Body $TokenBody
    $accessToken = $TokenResponse.access_token
}
catch {
    Write-Log -Message "[ERROR] SSC authentication failed: $($_.Exception.Message)" -Level ERROR -Color Red
    exit 1
}
finally {
    $PasswordPlain = $null
    $TokenBody = $null
}

if (-not $accessToken) {
    Write-Log -Message "[ERROR] SSC authentication failed (no token returned)." -Level ERROR -Color Red
    exit 1
}
$Headers = @{
    "Authorization" = "Bearer $accessToken"
    "Content-Type"  = "application/json"
}

# Verify the token, and capture who we're acting as (useful in the audit log).
try {
    $me = Invoke-RestMethod -Uri "$TenantUrl/api/v1/users/current" -Method Get -Headers $Headers
    Write-Log -Message "[OK] Authenticated as $($me.displayName) ($($me.userName)), id $($me.id)." -Level SUCCESS -Color Green
    Write-CsvLog "" "" "Auth" "Success" "Authenticated as $($me.userName) (id $($me.id))"
}
catch {
    Write-Log -Message "[ERROR] Token verification (users/current) failed: $($_.Exception.Message)" -Level ERROR -Color Red
    exit 1
}

# =====================================================================================
# LOAD CSV + COLLECT TARGET IDS
# =====================================================================================
Write-Log -Message "`n=== LOADING CSV ===" -Color Magenta

try {
    $rows = @(Import-Csv -LiteralPath $CsvPath)
}
catch {
    Write-Log -Message "[ERROR] Failed to read CSV: $($_.Exception.Message)" -Level ERROR -Color Red
    exit 1
}

if ($rows.Count -eq 0) {
    Write-Log -Message "CSV contained no rows. Nothing to do." -Level WARNING -Color Yellow
    exit 0
}

# Confirm the id column exists. Import-Csv can leave a BOM on the first header on some exports,
# so match the requested column name case-insensitively and tolerant of a leading BOM.
$firstRow = $rows[0]
$actualIdProp = $firstRow.PSObject.Properties.Name |
    Where-Object { ($_ -replace '^﻿', '').Trim() -ieq $IdColumn } |
    Select-Object -First 1
if (-not $actualIdProp) {
    Write-Log -Message "[ERROR] Id column '$IdColumn' not found in CSV." -Level ERROR -Color Red
    Write-Log -Message "        Available columns: $(($firstRow.PSObject.Properties.Name) -join ', ')" -Level ERROR -Color Red
    Write-Log -Message "        Re-run with -IdColumn <name> to point at the correct column." -Level ERROR -Color Red
    exit 1
}

$Targets = [System.Collections.Generic.List[object]]::new()
$skipped = 0
$rowNum  = 0
foreach ($r in $rows) {
    $rowNum++
    $idRaw = "$($r.$actualIdProp)".Trim()

    if (-not $idRaw) {
        Write-Log -Message "   Row $rowNum has an empty '$IdColumn' - skipping." -Level WARNING -Color Yellow
        Write-CsvLog "" "$($r.username)" "Parse" "Skipped" "Empty id in row $rowNum"
        $skipped++
        continue
    }

    # users/{id} expects a numeric SSC user id. Reject anything non-numeric so we never
    # PATCH a malformed path.
    $idInt = 0
    if (-not [int]::TryParse($idRaw, [ref]$idInt)) {
        Write-Log -Message "   Row $rowNum has a non-numeric id '$idRaw' - skipping." -Level WARNING -Color Yellow
        Write-CsvLog "$idRaw" "$($r.username)" "Parse" "Skipped" "Non-numeric id in row $rowNum"
        $skipped++
        continue
    }

    $Targets.Add([PSCustomObject]@{
        Id          = $idInt
        Username    = $r.username
        DisplayName = $r.displayname
        Email       = $r.emailaddress
    })
}

# De-duplicate on id in case the CSV lists the same user twice.
$Targets = @($Targets | Sort-Object -Property Id -Unique)

Write-Log -Message "[OK] $($Targets.Count) valid target(s) collected ($skipped row(s) skipped)." -Level SUCCESS -Color Green
if ($Targets.Count -eq 0) {
    Write-Log -Message "No valid ids to process. Exiting." -Level WARNING -Color Yellow
    exit 0
}

function Format-TargetDesc {
    param($T)
    @($T.Username, $T.DisplayName, $T.Email | Where-Object { $_ }) -join ' | '
}

# =====================================================================================
# CONFIRM
# =====================================================================================
Write-Log -Message "`n=== FINAL LIST: USERS TO RE-ENABLE THEN DISABLE ===" -Color Magenta
foreach ($t in $Targets) {
    Write-Log -Message "   id $($t.Id)`t$(Format-TargetDesc $t)" -Color Yellow
}

if ($WhatIf) {
    Write-Log -Message "`n[WHATIF] Preview only - no PATCH calls made for the $($Targets.Count) user(s) above." -Level WARNING -Color Cyan
    Write-Log -Message "Log file:     $LogPath" -Color Cyan
    Write-Log -Message "CSV Log file: $CsvLogPath" -Color Cyan
    exit 0
}

if (-not $BatchMode) {
    Write-Log -Message "`n[WARNING] Each user will be briefly ENABLED, then DISABLED again (ending disabled)." -Color Yellow
    $confirm = Read-Host "Type 'yes' to re-enable/disable ALL $($Targets.Count) user(s) above (anything else aborts)"
    if ($confirm -ne 'yes') {
        Write-Log -Message "Aborted by operator. No changes made." -Level WARNING -Color Yellow
        exit 0
    }
}
else {
    Write-Log -Message "`n>>> BATCH MODE: processing all $($Targets.Count) user(s) without confirmation." -Color Cyan
}

# =====================================================================================
# EXECUTE: enable then disable per id (clears the automatic-AD-disable flag, leaves disabled)
# =====================================================================================
Write-Log -Message "`n=== RE-ENABLING THEN DISABLING ===" -Color Magenta

$ok = 0; $fail = 0
$idx = 0
foreach ($t in $Targets) {
    $idx++
    Write-Log -Message "[$idx/$($Targets.Count)] id $($t.Id) ($($t.Username)):" -Color Gray

    # Step 1: ENABLE (this clears DisabledByAutomaticADUserDisabling).
    Write-Log -Message "      enable ..." -NoNewline
    try {
        $r1 = Set-SscUserEnabled -BaseUrl $TenantUrl -Headers $Headers -Id $t.Id -Enabled $true
        Write-Log -Message " OK (enabled=$($r1.enabled))" -Level SUCCESS -Color Green
        Write-CsvLog "$($t.Id)" "$($t.Username)" "Enable" "Success" "enabled=$($r1.enabled)"
    }
    catch {
        $e = Get-HttpErrorMessage $_
        Write-Log -Message " FAILED$(if ($e.Status) { " (HTTP $($e.Status))" })" -Level ERROR -Color Red
        Write-Log -Message "        $($e.Message)" -Level ERROR -Color Red
        Write-CsvLog "$($t.Id)" "$($t.Username)" "Enable" "Failed" "$(if ($e.Status) { "HTTP $($e.Status) - " })$($e.Message)"
        # Do NOT attempt the disable if enable failed - the user's state is unchanged.
        $fail++
        continue
    }

    # Step 2: DISABLE (leaves the user in a plain disabled state).
    Write-Log -Message "      disable..." -NoNewline
    try {
        $r2 = Set-SscUserEnabled -BaseUrl $TenantUrl -Headers $Headers -Id $t.Id -Enabled $false
        if ($r2.enabled -eq $false) {
            Write-Log -Message " OK (enabled=$($r2.enabled))" -Level SUCCESS -Color Green
            Write-CsvLog "$($t.Id)" "$($t.Username)" "Disable" "Success" "enabled=$($r2.enabled) (now plainly disabled)"
            $ok++
        }
        else {
            # PATCH returned 200 but the user is somehow still enabled - flag it loudly.
            Write-Log -Message " WARNING: user still reports enabled=$($r2.enabled)!" -Level WARNING -Color Yellow
            Write-CsvLog "$($t.Id)" "$($t.Username)" "Disable" "Warning" "PATCH succeeded but enabled=$($r2.enabled)"
            $fail++
        }
    }
    catch {
        $e = Get-HttpErrorMessage $_
        # This is the dangerous case: we enabled the user but could not disable them again.
        Write-Log -Message " FAILED$(if ($e.Status) { " (HTTP $($e.Status))" })" -Level ERROR -Color Red
        Write-Log -Message "        $($e.Message)" -Level ERROR -Color Red
        Write-Log -Message "        !! USER MAY REMAIN ENABLED - disable id $($t.Id) manually. !!" -Level ERROR -Color Red
        Write-CsvLog "$($t.Id)" "$($t.Username)" "Disable" "Failed" "$(if ($e.Status) { "HTTP $($e.Status) - " })$($e.Message) -- USER MAY REMAIN ENABLED"
        $fail++
    }
}

# =====================================================================================
# SUMMARY
# =====================================================================================
Write-Log -Message "`n=== SUMMARY ===" -Color Magenta
Write-Log -Message "Targets processed:            $($Targets.Count)"
Write-Log -Message "Re-enabled+disabled OK:       $ok" -Color Green
Write-Log -Message "Failed / needs attention:     $fail" -Color $(if ($fail) { 'Red' } else { 'Gray' })
Write-Log -Message "Rows skipped (parse):         $skipped" -Color Gray
if ($fail -gt 0) {
    Write-Log -Message "`n[WARNING] $fail user(s) failed. Review the CSV log - any 'Disable/Failed' rows may have LEFT A USER ENABLED." -Level WARNING -Color Yellow
}
Write-Log -Message "`nLog file:     $LogPath" -Color Cyan
Write-Log -Message "CSV Log file: $CsvLogPath" -Color Cyan
