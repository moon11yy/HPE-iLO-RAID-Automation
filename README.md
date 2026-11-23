# HPE iLO RAID Automation

PowerShell 7 tool for inspecting or creating **two RAID 1 volumes** on supported HPE ProLiant storage controllers exposed through the **Redfish API**. Supports an iLO host list, per-user encrypted credentials, live preflight validation, and CSV reporting.

> **Safety / scope:** This is a community example based on a working **HPE DL360 Gen12 / iLO 7 / MR408i-o Gen11** configuration, not an HPE-supported product. Other controllers and firmware versions have **not** been validated. Creating volumes can destroy existing data. Use only on equipment you are authorized to manage, with approved change control. **Dry Run is the default.**

## What it configures

| Volume | Physical bays | RAID level |
|---|---|---|
| `RAID1-A` | 1 + 2 | RAID 1 |
| `RAID1-B` | 3 + 4 | RAID 1 |

There is no OS dependency on the managed servers. The script interacts with Redfish on iLO; the **management workstation** requires Windows and PowerShell 7.

The scope is intentionally narrow: **exactly these two arrays, not a general-purpose GUI or RAID-level selector**. The controller must report `RAID1` in its Volume Capabilities, and each pair must contain compatible drives of the same capacity, protocol, and media type. Drives must be reported as healthy and `StandbyOffline` before creation. A different disk state or controller representation is not automatically treated as safe.

## Requirements

- Windows computer with **PowerShell 7+**, network access to iLO HTTPS (TCP 443), and an iLO account authorized for storage configuration.
- Servers with compatible Redfish Storage/Volumes endpoints and four eligible drives in physical bays 1–4.
- Valid, trusted HTTPS certificates **recommended**; if certificate validation cannot be used, see [Security](SECURITY.md).
- For CLIXML credentials, files must be created by the same Windows user on the same computer that loads them.

HPE references: [Storage resource definitions](https://servermanagementportal.ext.hpe.com/docs/redfishservices/ilos/ilo7/ilo7_120/ilo7_storage_resourcedefns120) and [HPE iLOrest storage commands](https://servermanagementportal.ext.hpe.com/docs/redfishclients/ilorest-userguide/smartarraycommands).

## Quick start

### 1. List your iLO hosts

Copy `examples/ilos.example.txt` to `ilos.txt` at the repository root and replace the placeholder hostnames with the intended iLO addresses, one per line. **Do not commit `ilos.txt`.**

### 2. Supply credentials

**Option A — interactive login (simplest):**

```powershell
$cred = Get-Credential
.\scripts\ilo7-bulk-two-raid1-public.ps1 -HostFile .\ilos.txt -Credential $cred
```

**Option B — encrypted local CLIXML credentials:**

In **PowerShell 7 on Windows**, as the Windows user who will run the script:

```powershell
$folder = Join-Path $env:LOCALAPPDATA 'HPE-iLO-Update'
New-Item -ItemType Directory -Path $folder -Force | Out-Null
Get-Credential | Export-Clixml (Join-Path $folder 'ilo-primary-credential.xml')
# Optional fallback account, if approved by your organization's authentication policy:
Get-Credential | Export-Clixml (Join-Path $folder 'ilo-secondary-credential.xml')
```

When `-Credential` is not supplied, the tool looks in **`$env:LOCALAPPDATA\HPE-iLO-Update`** for those files. If neither file exists, it prompts for credentials. If the primary login is explicitly rejected with HTTP 401, it can try the secondary once. The default bulk behavior stops after a host has rejected all supplied credentials to reduce account-lockout risk.

**Never commit credential files, including CLIXML files.** Windows `Export-Clixml` uses DPAPI; the protected files can be opened only by the same user on the same computer.

### 3. Dry Run (read-only configuration check)

```powershell
.\scripts\ilo7-bulk-two-raid1-public.ps1 -HostFile .\ilos.txt
```

The script checks the live mapping and available RAID capabilities on each host and reports `Ready`, `AlreadyConfigured`, `NeedsReview`, or `Failed`. A Dry Run does not prove that a later write will succeed.

If you need to supply credentials interactively explicitly:

```powershell
$cred = Get-Credential
.\scripts\ilo7-bulk-two-raid1-public.ps1 -HostFile .\ilos.txt -Credential $cred
```

### 4. Apply only after validation and authorization

```powershell
.\scripts\ilo7-bulk-two-raid1-public.ps1 -HostFile .\ilos.txt -Apply
```

Before writing, it displays a warning and requires typing `APPLY-RAID1-TO-N-HOSTS` where `N` is the number of hosts in the input file. Test on **one disposable server** first.

**Default behavior with existing volumes:**
- Exactly two verified matching volumes → `AlreadyConfigured`, no writes.
- Any partial or unexpected existing layout → `NeedsReview`, **no writes**.
- Zero volumes and four verified free compatible drives → `Ready` on Dry Run; eligible for `-Apply`.

Volume POST requests are sequential. If a POST times out or cannot be verified, the script **never retries the POST automatically** and makes no further changes to that server.

## Reports

Reports are written to `reports/raid1-results-YYYYMMDD-HHMMSS-XXXXXX.csv`, a unique name for each execution; the file is updated after each processed host. The output includes:

`iLO`, `Status`, `RAID1_A`, `RAID1_B`, `Credential` (filename/label only), `Stage`, `Detail`, `Timestamp`.

| Status | Meaning |
|---|---|
| `Ready` | All preflight checks passed; **no changes made** |
| `Created` | Both volumes created and verified |
| `AlreadyConfigured` | Existing two-volume layout verified; skipped |
| `NeedsReview` | Unexpected or partial existing layout; skipped |
| `UnknownOutcome` | POST/verification uncertain; **do not retry blindly** |
| `PartialNeedsReview` | First volume verified; second not complete or uncertain |
| `Failed` | Login, connectivity or preflight error |

Logs may contain hostnames and error details; don't publish production reports.

## Options

```text
-HostFile <path>                 Required. TXT of iLO IPs/DNS names.
-Credential <PSCredential>        Use supplied credentials; skip CLIXML lookup.
-CredentialDirectory <path>      Override local credential directory.
-OutputDirectory <path>          Change CSV report directory.
-Apply                            Enable write operations after typed confirmation.
-PostTimeoutSeconds <60..600>    Timeout per Volume POST. Default: 180.
-ContinueOnAuthenticationFailure Continue scanning hosts after rejected credentials;
                                 use only if approved (account-lockout risk).
-SkipCertificateCheck             INSECURE: disables TLS certificate verification.
```

## Safety notes

- TLS certificates are checked by default. `-SkipCertificateCheck` disables server identity verification and should not be used as a routine production default. The script warns when it is set.
- Drive IDs (such as `/Drives/0`) are **not assumed to match physical bay numbers**. The script checks the live `PhysicalLocation.PartLocation` values and uses returned Redfish links.
- No RAID deletion, migration, rescue, reboot, or automatic recovery of partial arrays is implemented.
- The script does not verify that all media are genuinely empty; operator authorization and drive data disposition remain required.
- A successful report should still be confirmed via iLO Storage Health and change records.

## Repository contents

```text
HPE-iLO-RAID-Automation/
├── scripts/
│   └── ilo7-bulk-two-raid1-public.ps1
├── examples/
│   └── ilos.example.txt
├── tests/
│   └── Test-PowerShellSyntax.ps1
├── .gitignore
├── README.md
└── SECURITY.md
```

## Validation / support

The original workflow has been used with HPE iLO 7 and MR408i hardware. **This sanitized public edition has not been executed against live equipment**, and behavior on other models is unverified. Review the code and run a read-only preflight before enabling `-Apply`.

There is no included open-source license. Add one **only after confirming ownership and organizational permission to publish** the source code. This project is not affiliated with or endorsed by HPE.
