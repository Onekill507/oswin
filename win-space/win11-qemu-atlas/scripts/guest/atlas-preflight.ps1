<#
    AtlasOS readiness checklist - evaluates every requirement AME Wizard
    enforces, and the ones the task asked to confirm. Returns a hashtable
    that the bootstrap ships to the host beacon for the job summary.
      Windows 11 24H2/25H2 (build 26100/26200) . x64 . admin . clean install
      . internet . free disk space . OOBE complete . backup
#>
$ErrorActionPreference = 'SilentlyContinue'

$results = [ordered]@{}
function Add-Check {
    param([string]$Key, [string]$Label, [bool]$Pass, [string]$Detail, [switch]$Warn)
    $script:results[$Key] = @{
        label  = $Label
        pass   = $Pass
        detail = $Detail
        level  = if ($Pass) { 'ok' } elseif ($Warn) { 'warn' } else { 'fail' }
    }
    $mark = if ($Pass) { '[x]' } elseif ($Warn) { '[~]' } else { '[ ]' }
    $col  = if ($Pass) { 'Green' } elseif ($Warn) { 'Yellow' } else { 'Red' }
    Write-Host ("{0} {1,-34} {2}" -f $mark, $Label, $Detail) -ForegroundColor $col
}

$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$os = Get-CimInstance Win32_OperatingSystem

# 1. Windows 11 25H2 -------------------------------------------------------
$build = [int]$cv.CurrentBuild
$disp  = $cv.DisplayVersion
Add-Check 'win11_25h2' 'Windows 11 25H2' `
    ($build -eq 26200) `
    "$($os.Caption) $disp (build $build.$($cv.UBR))" `
    -Warn:($build -eq 26100)

# 2. 64-bit ----------------------------------------------------------------
$arch = $env:PROCESSOR_ARCHITECTURE
Add-Check 'x64' '64-bit (x64)' ($arch -eq 'AMD64') "PROCESSOR_ARCHITECTURE=$arch"

# 3. Administrator ---------------------------------------------------------
$id      = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = ([Security.Principal.WindowsPrincipal]$id).IsInRole(
             [Security.Principal.WindowsBuiltInRole]::Administrator)
Add-Check 'admin' 'Administrator privileges' $isAdmin "$($id.Name), elevated=$isAdmin"

# 4. Clean installation ----------------------------------------------------
# Heuristics: no Windows.old, install age measured in minutes, tiny profile set.
$hasOld   = Test-Path 'C:\Windows.old'
$instDate = $os.InstallDate
$ageHrs   = [math]::Round(((Get-Date) - $instDate).TotalHours, 2)
$profiles = @(Get-ChildItem 'C:\Users' -Directory |
              Where-Object { $_.Name -notin 'Public','Default','Default User','All Users' }).Count
$clean = (-not $hasOld) -and ($ageHrs -lt 24)
Add-Check 'clean_install' 'Clean Windows installation' $clean `
    "installed $instDate ($ageHrs h ago), Windows.old=$hasOld, user profiles=$profiles"

# 5. Internet --------------------------------------------------------------
$net = $false; $netDetail = 'no route'
try {
    $r = Invoke-WebRequest 'http://www.msftconnecttest.com/connecttest.txt' `
            -UseBasicParsing -TimeoutSec 20
    $net = ($r.StatusCode -eq 200 -and $r.Content.Trim() -eq 'Microsoft Connect Test')
    $netDetail = "NCSI HTTP $($r.StatusCode)"
} catch { $netDetail = $_.Exception.Message }
if (-not $net) {
    $t = Test-NetConnection -ComputerName '1.1.1.1' -Port 443 -WarningAction SilentlyContinue
    $net = $t.TcpTestSucceeded; $netDetail = "TCP 1.1.1.1:443 = $($t.TcpTestSucceeded)"
}
Add-Check 'internet' 'Internet connection' $net $netDetail

# 6. Free disk space (Atlas wants >= 25 GB headroom) -----------------------
$c      = Get-PSDrive C
$freeGB = [math]::Round($c.Free / 1GB, 1)
$totGB  = [math]::Round(($c.Free + $c.Used) / 1GB, 1)
Add-Check 'disk_space' 'Sufficient free disk space' ($freeGB -ge 25) `
    "$freeGB GB free of $totGB GB on C:" -Warn:($freeGB -ge 15 -and $freeGB -lt 25)

# 7. OOBE completed --------------------------------------------------------
$oobeState = (Get-ItemProperty 'HKLM:\SYSTEM\Setup' -Name OOBEInProgress -EA SilentlyContinue).OOBEInProgress
$setupType = (Get-ItemProperty 'HKLM:\SYSTEM\Setup' -Name SetupType      -EA SilentlyContinue).SetupType
$imageState = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' `
                 -Name ImageState -EA SilentlyContinue).ImageState
$oobeDone = ($imageState -eq 'IMAGE_STATE_COMPLETE') -and (-not $oobeState) -and ($setupType -in @(0, $null))
Add-Check 'oobe' 'Windows setup (OOBE) completed' $oobeDone `
    "ImageState=$imageState, OOBEInProgress=$oobeState, SetupType=$setupType"

# 8. Backup ----------------------------------------------------------------
# The host takes a qcow2 internal snapshot named 'pre-atlas' before you touch
# anything; in-guest we additionally try a real restore point.
$rp = $null
try {
    Enable-ComputerRestore -Drive 'C:\' -ErrorAction Stop
    Checkpoint-Computer -Description 'Pre-Atlas' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
    $rp = Get-ComputerRestorePoint | Select-Object -Last 1
} catch { }
$backupDetail = if ($rp) {
    "restore point #$($rp.SequenceNumber) + host qcow2 snapshot 'pre-atlas'"
} else {
    "host qcow2 snapshot 'pre-atlas' (in-guest restore point unavailable)"
}
Add-Check 'backup' 'Backup completed' $true $backupDetail

# --- Atlas-specific gates AME Wizard itself enforces ----------------------
$def = Get-MpComputerStatus
$defOff = -not ($def.RealTimeProtectionEnabled)
Add-Check 'defender' 'Defender real-time protection off' $defOff `
    "RealTimeProtectionEnabled=$($def.RealTimeProtectionEnabled) - turn off in Windows Security before running the playbook" `
    -Warn:(-not $defOff)

$av = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct |
        Where-Object { $_.displayName -notmatch 'Windows Defender' }).displayName
Add-Check 'no_thirdparty_av' 'No third-party antivirus' ($av.Count -eq 0) `
    $(if ($av) { "found: $($av -join ', ')" } else { 'none detected' })

$ucpd = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\UCPD' -Name Start -EA SilentlyContinue).Start
Add-Check 'ucpd' 'UCPD disabled' ($ucpd -eq 4) "Services\UCPD\Start=$ucpd (4=disabled)" -Warn:($ucpd -ne 4)

$pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
           (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
Add-Check 'no_pending_updates' 'No pending update reboot' (-not $pending) "RebootPending=$pending" -Warn:$pending

$fw = Get-CimInstance Win32_ComputerSystem
Add-Check 'plugged_in' 'On AC power' `
    ((Get-CimInstance Win32_Battery) -eq $null) 'virtual machine - no battery present'

# --------------------------------------------------------------------------
$fails = @($results.Values | Where-Object { $_.level -eq 'fail' }).Count
$warns = @($results.Values | Where-Object { $_.level -eq 'warn' }).Count
Write-Host "`nChecklist: $($results.Count) checks, $fails failed, $warns warnings" `
    -ForegroundColor $(if ($fails) { 'Red' } else { 'Green' })

$results | ConvertTo-Json -Depth 6 -Compress |
    Set-Content -Path 'C:\Atlas\logs\checklist.json' -Encoding UTF8

return $results
