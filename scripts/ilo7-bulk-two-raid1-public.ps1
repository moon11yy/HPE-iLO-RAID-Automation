#Requires -Version 7.0
<#
.SYNOPSIS
  Discover and configure two RAID1 volumes on supported HPE iLO Redfish storage controllers.
.DESCRIPTION
  Read-only by default. Creates RAID1-A (Bays 1+2) and RAID1-B (Bays 3+4).
  Intended for authorized NEW/EMPTY servers whose Redfish-capable controller
  exposes Volume creation and four matching free drives. Designed from an
  HPE iLO 7 / MR408i configuration; not tested on other controllers.
  Uses a supplied PSCredential, or optionally imports per-user CLIXML files
  from the current user's LOCALAPPDATA. No credentials are stored in this repo.
  Verifies existing layout and refuses partial/unexpected configurations.
  Never retries a possibly successful POST. Writes a new CSV for each run.
  HTTPS certificate validation is ON by default. -SkipCertificateCheck is
  insecure and must be independently authorized in a trusted management network.
.EXAMPLE
  .\ilo7-bulk-two-raid1.ps1 -HostFile .\ilos.txt -Credential (Get-Credential)
.EXAMPLE
  .\ilo7-bulk-two-raid1.ps1 -HostFile .\ilos.txt -Apply
.EXAMPLE
  .\ilo7-bulk-two-raid1.ps1 -HostFile .\ilos.txt -SkipCertificateCheck -Apply
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateScript({Test-Path -LiteralPath $_ -PathType Leaf})][string]$HostFile,
  [PSCredential]$Credential,
  [string]$CredentialDirectory = (Join-Path $env:LOCALAPPDATA 'HPE-iLO-Update'),
  [string]$OutputDirectory = (Join-Path $PSScriptRoot 'reports'),
  [switch]$SkipCertificateCheck,
  [switch]$ContinueOnAuthenticationFailure,
  [switch]$Apply,
  [ValidateRange(60,600)][int]$PostTimeoutSeconds = 180
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($SkipCertificateCheck) {
  Write-Warning 'INSECURE TLS: iLO server identity will NOT be authenticated. Use only with explicit organizational approval and independent server identity verification.'
}

$hosts = @(Get-Content -LiteralPath $HostFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') } | Select-Object -Unique)
if ($hosts.Count -eq 0) { throw 'HostFile contains no hosts.' }
foreach ($hostName in $hosts) {
  if ($hostName -notmatch '^[a-zA-Z0-9.-]+$' -or $hostName.StartsWith('-') -or $hostName.Contains('..')) {
    throw "Invalid iLO host name/IP in file: $hostName"
  }
}
$creds = @()
if ($PSBoundParameters.ContainsKey('Credential')) {
  $creds += ,([pscustomobject]@{ Label='SuppliedCredential'; Value=$Credential })
} else {
  foreach ($filename in @('ilo-primary-credential.xml','ilo-secondary-credential.xml')) {
    $path = Join-Path $CredentialDirectory $filename
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    try { $loaded = Import-Clixml -LiteralPath $path }
    catch { throw "Cannot decrypt/read $filename under current Windows user and machine: $($_.Exception.Message)" }
    if ($loaded -isnot [System.Management.Automation.PSCredential]) { throw "$filename must be an Export-Clixml PSCredential." }
    $creds += ,([pscustomobject]@{ Label=$filename; Value=$loaded })
  }
  if ($creds.Count -eq 0) {
    Write-Host 'No local CLIXML credential files found. Requesting credentials interactively.' -ForegroundColor Yellow
    $prompted = Get-Credential -Message 'Enter an authorized HPE iLO account'
    if ($null -eq $prompted) { throw 'Credential input cancelled.' }
    $creds += ,([pscustomobject]@{ Label='Interactive'; Value=$prompted })
  }
}

$expectedBays = @(1,2,3,4)
$results = [System.Collections.Generic.List[object]]::new()
if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
  $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
}
# Unique report per execution; no overwriting historic reports.
$reportName = 'raid1-results-{0}-{1}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmmss'),([guid]::NewGuid().ToString('N').Substring(0,6))
$outPath = Join-Path (Resolve-Path -LiteralPath $OutputDirectory).Path $reportName

if ($Apply) {
  Write-Warning "BULK WRITE requested for $($hosts.Count) iLO hosts. Creates two RAID1 arrays per eligible EMPTY server. Disk data can be lost."
  if ($SkipCertificateCheck) { Write-Warning 'Write operations with invalid TLS certificates: double-check every target host out of band before approving.' }
  $confirmation = Read-Host "Type APPLY-RAID1-TO-$($hosts.Count)-HOSTS to confirm whole bulk"
  if ($confirmation -cne "APPLY-RAID1-TO-$($hosts.Count)-HOSTS") { throw 'Bulk confirmation not provided; nothing changed.' }
}

function Save-Report {
  if ($results.Count -eq 0) { return }
  $temp = "$outPath.tmp"
  $results.ToArray() | Export-Csv -LiteralPath $temp -Encoding utf8
  # Overwrite-capable .NET move prevents the Move-Item destination-exists problem.
  [System.IO.File]::Move(
    [System.IO.Path]::GetFullPath($temp),
    [System.IO.Path]::GetFullPath($outPath),
    $true
  )
}
function Uri-Check([string]$uri) {
  if (-not $uri.StartsWith('/redfish/v1/')) { throw "Unexpected Redfish URI: $uri" }
  if ($uri.Contains('?') -or $uri.Contains('#') -or $uri.Contains('\\')) { throw 'Unexpected URI characters.' }
  return $uri
}
function Call-Api {
  param([string]$Method,[string]$Uri,[object]$Body=$null,[int]$TimeoutSec=45)
  $uri = Uri-Check $Uri
  $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), "$script:base$uri")
  $request.Version=[version]'1.1'
  $request.VersionPolicy=[System.Net.Http.HttpVersionPolicy]::RequestVersionExact
  if ($script:token) { [void]$request.Headers.TryAddWithoutValidation('X-Auth-Token',$script:token) }
  if ($null -ne $Body) {
    $json=ConvertTo-Json -InputObject $Body -Depth 10 -Compress
    $request.Content=[System.Net.Http.StringContent]::new($json,[System.Text.Encoding]::UTF8,'application/json')
  }
  $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSec))
  $response=$null
  try {
    $response=$script:client.SendAsync($request,[System.Net.Http.HttpCompletionOption]::ResponseHeadersRead,$cts.Token).GetAwaiter().GetResult()
    $code=[int]$response.StatusCode
    $content=$response.Content.ReadAsStringAsync($cts.Token).GetAwaiter().GetResult()
    $data=$null
    if (-not [string]::IsNullOrWhiteSpace($content)) {
      try { $data=ConvertFrom-Json -InputObject $content -Depth 50 } catch { $data=$null }
    }
    if ($code -lt 200 -or $code -ge 300) {
      $messageIds = @()
      if ($null -ne $data -and $null -ne $data.error -and $null -ne $data.error.'@Message.ExtendedInfo') {
        $messageIds=@($data.error.'@Message.ExtendedInfo' | ForEach-Object { $_.MessageId })
      }
      throw "HTTP $code $Method $Uri $(($messageIds -join ','))"
    }
    return [pscustomobject]@{ Code=$code; Data=$data; Location=if($response.Headers.Location){$response.Headers.Location.PathAndQuery}else{$null}; Token=if($response.Headers.Contains('X-Auth-Token')){($response.Headers.GetValues('X-Auth-Token')|Select-Object -First 1)}else{$null} }
  } finally {
    if ($response) { $response.Dispose() }
    $request.Dispose(); $cts.Dispose()
  }
}
function Read-Api([string]$uri) { return (Call-Api -Method GET -Uri $uri).Data }
function Get-Volumes([string]$volUri) {
  $collection = Read-Api $volUri
  if ($null -eq $collection -or $null -eq $collection.Members) { throw 'Volume collection Members unavailable.' }
  $items=@()
  foreach ($m in @($collection.Members)) {
    $u=[string]$m.'@odata.id'; if (-not $u) { throw 'Volume entry missing @odata.id.' }
    $items += ,(Read-Api $u)
  }
  return $items
}
function Volume-Ids($volume) {
  if (-not $volume.Links -or -not $volume.Links.Drives) { return @() }
  return @($volume.Links.Drives | ForEach-Object { [string]$_.'@odata.id' } | Sort-Object)
}
function Check-DesiredVolume($volume,[string[]]$uris,[string]$label) {
  if ($null -eq $volume -or [string]$volume.RAIDType -ne 'RAID1') { return $false }
  if ([string]$volume.DisplayName -ne $label) { return $false }
  if ([string]$volume.Status.State -ne 'Enabled' -or [string]$volume.Status.Health -ne 'OK') { return $false }
  $actual = @(Volume-Ids $volume | Sort-Object)
  $wanted = @($uris | Sort-Object)
  return ($actual.Count -eq 2 -and ($actual -join '|') -ceq ($wanted -join '|'))
}
function Check-Complete($volumes,$bays) {
  if (@($volumes).Count -ne 2) { return $false }
  $a=@($volumes | Where-Object { Check-DesiredVolume $_ @($bays[1].Uri,$bays[2].Uri) 'RAID1-A' })
  $b=@($volumes | Where-Object { Check-DesiredVolume $_ @($bays[3].Uri,$bays[4].Uri) 'RAID1-B' })
  return ($a.Count -eq 1 -and $b.Count -eq 1)
}
function Get-LiveTarget {
  $sys = Read-Api '/redfish/v1/Systems/1'
  if ($null -eq $sys) { throw 'System resource unreadable.' }
  $storageCollection=Read-Api '/redfish/v1/Systems/1/Storage'
  if (-not $storageCollection.Members) { throw 'No storage controllers.' }
  $matches=@()
  foreach ($sref in @($storageCollection.Members)) {
    $storageUri=[string]$sref.'@odata.id'
    $storage=Read-Api $storageUri
    if (-not $storage.Drives -or -not $storage.Volumes.'@odata.id') { continue }
    $bayMap=@{}
    foreach ($dref in @($storage.Drives)) {
      $driveUri=[string]$dref.'@odata.id'
      if (-not $driveUri) { continue }
      $drive=Read-Api $driveUri
      if (-not $drive.PhysicalLocation -or -not $drive.PhysicalLocation.PartLocation) { continue }
      $location=$drive.PhysicalLocation.PartLocation
      $bay=[int]$location.LocationOrdinalValue
      if ($bay -notin $expectedBays) { continue }
      if ($bayMap.ContainsKey($bay)) { throw "Duplicate drive bay $bay found. Refusing." }
      $bayMap[$bay]=[pscustomobject]@{ Bay=$bay; Uri=$driveUri; State=[string]$drive.Status.State; Health=[string]$drive.Status.Health;
        Protocol=[string]$drive.Protocol; Media=[string]$drive.MediaType; Capacity=[int64]$drive.CapacityBytes; Label=[string]$location.ServiceLabel }
    }
    if ($bayMap.Count -eq 4) {
      $caps=Read-Api "$([string]$storage.Volumes.'@odata.id')/Capabilities"
      if ('RAID1' -notin @($caps.'RAIDType@Redfish.AllowableValues')) { continue }
      $matches += ,([pscustomobject]@{ StorageUri=$storageUri; VolumeUri=[string]$storage.Volumes.'@odata.id'; Bays=$bayMap; Capabilities=$caps })
    }
  }
  if ($matches.Count -ne 1) { throw "Expected exactly one RAID1-capable storage controller with Bays 1-4; found $($matches.Count)." }
  $target=$matches[0]
  if ($target.Capabilities.'Links@Redfish.RequiredOnCreate' -ne $true -or $target.Capabilities.Links.'Drives@Redfish.RequiredOnCreate' -ne $true) {
    throw 'Controller Volume creation capabilities do not match expected Redfish schema.'
  }
  foreach ($n in $expectedBays) {
    $d=$target.Bays[$n]
    if ($d.Label -notmatch "Bay=$n(?:$|\D)") { throw "Physical location mismatch at Bay $n." }
    if ($d.Protocol -notin @('SAS','SATA','NVMe') -or $d.Media -notin @('SSD','HDD') -or $d.Capacity -le 0) {
      throw "Bay $n: unrecognized media/protocol/capacity; review controller compatibility."
    }
    if ($d.Health -ne 'OK') { throw "Bay $n health is $($d.Health)." }
  }
  # RAID1 is composed of matching drives within each pair; fail closed otherwise.
  foreach ($pair in @(@(1,2),@(3,4))) {
    $d1=$target.Bays[$pair[0]]; $d2=$target.Bays[$pair[1]]
    if ($d1.Protocol -ne $d2.Protocol -or $d1.Media -ne $d2.Media -or $d1.Capacity -ne $d2.Capacity) {
      throw "Bay $($pair -join '+') drives differ in protocol, media type, or capacity."
    }
  }
  return $target
}
function Check-Free($target,[int[]]$bays) {
  foreach ($n in $bays) {
    $d=Read-Api $target.Bays[$n].Uri
    if ([string]$d.Status.Health -ne 'OK' -or [string]$d.Status.State -ne 'StandbyOffline') { throw "Bay $n not free: $($d.Status.State)/$($d.Status.Health)." }
    if ([int]$d.PhysicalLocation.PartLocation.LocationOrdinalValue -ne $n) { throw "Bay $n physical mapping changed." }
  }
}
function Verify-ExpectedCount($target,[int]$count) {
  $volumes=@(Get-Volumes $target.VolumeUri)
  if ($volumes.Count -ne $count) { throw "Expected $count volumes, found $($volumes.Count)." }
  if ($count -eq 1) {
    if (-not (Check-DesiredVolume $volumes[0] @($target.Bays[1].Uri,$target.Bays[2].Uri) 'RAID1-A')) { throw 'RAID1-A not verified.' }
  } elseif ($count -eq 2) {
    if (-not (Check-Complete $volumes $target.Bays)) { throw 'Both RAID1 volume mappings not verified.' }
  }
  return $true
}
function Wait-Verified($target,[int]$count) {
  $last=''
  for ($i=0;$i -lt 20;$i++) {
    try { if (Verify-ExpectedCount $target $count) { return $true } }
    catch { $last=$_.Exception.Message }
    Start-Sleep -Seconds 5
  }
  throw "Unable to verify new RAID volume: $last"
}
function Send-OneCreation($target,[string]$name,[int[]]$bays,[int]$expectedBefore) {
  $before=@(Get-Volumes $target.VolumeUri)
  if ($before.Count -ne $expectedBefore) { throw "Pre-POST volume count changed: $($before.Count)." }
  if ($expectedBefore -eq 1) { $null=Verify-ExpectedCount $target 1 }
  Check-Free $target $bays
  $payload=@{ RAIDType='RAID1'; DisplayName=$name; Links=@{ Drives=@($bays|ForEach-Object { @{ '@odata.id'=$target.Bays[$_].Uri } }) } }
  Write-Host "  Sending ONE POST for $name on Bays $($bays -join '+')" -ForegroundColor Yellow
  # If the server closes / times out, NEVER automatically repeat this POST.
  try { $null=Call-Api -Method POST -Uri $target.VolumeUri -Body $payload -TimeoutSec $PostTimeoutSeconds }
  catch { throw "POST_UNCERTAIN for $name : $($_.Exception.Message). No further writes will be sent to this server." }
  try { $null=Wait-Verified $target ($expectedBefore+1) }
  catch { throw "VERIFY_UNCERTAIN for $name : $($_.Exception.Message). No further writes will be sent to this server." }
}
function Open-Session($credential) {
  $body=@{ UserName=$credential.UserName; Password=$credential.GetNetworkCredential().Password }
  try { $r=Call-Api -Method POST -Uri '/redfish/v1/SessionService/Sessions' -Body $body }
  finally { $body=$null }
  if ($r.Code -ne 201 -or -not $r.Token -or -not $r.Location) { throw 'Session response missing token or location.' }
  $script:token=$r.Token; $script:sessionUri=$r.Location
}

foreach ($hostName in $hosts) {
  $script:base="https://$hostName"; $script:token=$null; $script:sessionUri=$null
  $clientHandler=[System.Net.Http.HttpClientHandler]::new()
  $clientHandler.UseCookies=$false; $clientHandler.AllowAutoRedirect=$false
  if ($SkipCertificateCheck) {
    $clientHandler.ServerCertificateCustomValidationCallback=[System.Net.Http.HttpClientHandler]::DangerousAcceptAnyServerCertificateValidator
  }
  $script:client=[System.Net.Http.HttpClient]::new($clientHandler)
  $script:client.Timeout=[TimeSpan]::FromMinutes(12)
  $script:client.DefaultRequestHeaders.Accept.ParseAdd('application/json')
  $stage='Authentication'; $credentialUsed='None'; $status='Failed'; $detail=''; $a='NotStarted'; $b='NotStarted'
  Write-Host "[$hostName] Starting RAID1 preflight..." -ForegroundColor Cyan
  try {
    $loginErrors=@()
    foreach ($entry in $creds) {
      try { Open-Session $entry.Value; $credentialUsed=$entry.Label; break }
      catch {
        $loginError = $_.Exception.Message
        $loginErrors += "$($entry.Label): $loginError"
        # Do not try alternative credentials on TLS/transport errors or unexpected 403.
        if ($loginError -notmatch '^HTTP 401 ') { throw "Authentication/connection error: $loginError" }
      }
    }
    if (-not $script:token) { throw "AUTH_REJECTED: All supplied login credentials were rejected (HTTP 401). $($loginErrors -join '; ')" }
    $stage='Preflight'
    $target=Get-LiveTarget
    $current=@(Get-Volumes $target.VolumeUri)
    if ($current.Count -eq 2 -and (Check-Complete $current $target.Bays)) {
      $status='AlreadyConfigured'; $a='Verified'; $b='Verified'; $detail='Both expected RAID1 volumes already exist and map to Bays 1+2 / 3+4.'
    } elseif ($current.Count -gt 0) {
      $status='NeedsReview'; $detail="Found $($current.Count) volume(s), layout incomplete or unexpected. No changes allowed."; $stage='ExistingVolumes'
    } else {
      Check-Free $target @(1,2,3,4)
      if (-not $Apply) {
        $status='Ready'; $detail='Dry run OK. Bays 1+2 / 3+4 mapped; no volumes; four compatible drives healthy and free.'
      } else {
        $stage='CreateA'; Send-OneCreation $target 'RAID1-A' @(1,2) 0; $a='Verified'
        $stage='CreateB'; Send-OneCreation $target 'RAID1-B' @(3,4) 1; $b='Verified'
        $status='Created'; $detail='Both RAID1 volumes created and verified against drive links.'
      }
    }
  } catch {
    $detail="$stage : $($_.Exception.Message)"
    if ($detail -match 'POST_UNCERTAIN|VERIFY_UNCERTAIN') { $status='UnknownOutcome' }
    elseif ($a -eq 'Verified') { $status='PartialNeedsReview' }
    else { $status='Failed' }
  } finally {
    if ($script:token -and $script:sessionUri -and $script:sessionUri.StartsWith('/redfish/v1/')) {
      try { $null=Call-Api -Method DELETE -Uri $script:sessionUri -TimeoutSec 15 } catch { }
    }
    $script:token=$null; $script:sessionUri=$null
    $script:client.Dispose(); $clientHandler.Dispose()
  }
  $row=[pscustomobject]@{ iLO=$hostName; Status=$status; RAID1_A=$a; RAID1_B=$b; Credential=$credentialUsed; Stage=$stage; Detail=$detail; Timestamp=(Get-Date).ToString('s') }
  [void]$results.Add($row)
  Save-Report
  Write-Host "[$hostName] $status : $detail" -ForegroundColor $(if($status -in @('Created','AlreadyConfigured','Ready')){'Green'}else{'Yellow'})
  if ($status -eq 'Failed' -and $detail -match 'AUTH_REJECTED' -and -not $ContinueOnAuthenticationFailure) {
    Write-Warning 'Stopping bulk on authentication rejection to reduce the chance of account lockout. Use -ContinueOnAuthenticationFailure only if approved.'
    break
  }
}
Write-Host "`nBULK RESULTS" -ForegroundColor Cyan
$results.ToArray() | Format-Table iLO,Status,RAID1_A,RAID1_B,Credential,Stage -AutoSize
Write-Host "Report saved: $outPath"
if (@($results.ToArray() | Where-Object {$_.Status -in @('Failed','UnknownOutcome','PartialNeedsReview','NeedsReview')}).Count -gt 0) {
  Write-Warning 'Some hosts require manual review. DO NOT blindly retry creation on failed/unknown/partial hosts.'
}
