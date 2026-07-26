<#
    Runs at first logon inside the Windows 11 guest (elevated, autologon).
      1. reports boot milestones back to the host beacon
      2. runs the AtlasOS readiness checklist
      3. stages AME Wizard + the Atlas Playbook on the desktop
      4. leaves the machine ready for a human in noVNC
    Nothing destructive happens automatically - Atlas is *staged*, not applied.
#>
[CmdletBinding()]
param(
    [int]$BeaconPort = 8099,
    [string]$BeaconHost = '10.0.2.2',        # SLIRP alias for the QEMU host
    [ValidateSet('stage','verify','none')]
    [string]$AtlasMode = 'stage'
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root    = 'C:\Atlas'
$LogDir  = Join-Path $Root 'logs'
$Desktop = Join-Path $env:PUBLIC 'Desktop'
New-Item -ItemType Directory -Force -Path $Root,$LogDir,(Join-Path $Root 'payload') | Out-Null
Start-Transcript -Path (Join-Path $LogDir 'bootstrap.log') -Append | Out-Null

function Send-Beacon {
    param([string]$Stage, [hashtable]$Data)
    $q = "stage=$([uri]::EscapeDataString($Stage))"
    if ($Data) {
        $json = ($Data | ConvertTo-Json -Compress -Depth 6)
        $q += "&data=$([uri]::EscapeDataString($json))"
    }
    for ($i = 0; $i -lt 3; $i++) {
        try {
            Invoke-RestMethod -Uri "http://${BeaconHost}:${BeaconPort}/beacon?$q" -TimeoutSec 15 | Out-Null
            return $true
        } catch { Start-Sleep -Seconds 3 }
    }
    Write-Warning "beacon '$Stage' failed"; return $false
}

function Write-Step($m) { Write-Host "`n=== $m" -ForegroundColor Cyan }

# ---------------------------------------------------------------- boot proof
Write-Step 'Reporting desktop reachability'
$os  = Get-CimInstance Win32_OperatingSystem
$cs  = Get-CimInstance Win32_ComputerSystem
$cv  = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

Send-Beacon -Stage 'desktop' -Data @{
    caption      = $os.Caption
    version      = $os.Version
    build        = $cv.CurrentBuild
    ubr          = $cv.UBR
    displayName  = $cv.DisplayVersion       # "25H2"
    edition      = $cv.EditionID
    arch         = $env:PROCESSOR_ARCHITECTURE
    ramGB        = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    user         = "$env:USERDOMAIN\$env:USERNAME"
    bootTimeSec  = [int]((Get-Date) - $os.LastBootUpTime).TotalSeconds
}

# ------------------------------------------------------- QoL for the operator
Write-Step 'Applying lab quality-of-life settings'
# Never sleep / never blank the screen - the VM must stay reachable for 6h.
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /hibernate off 2>$null

# Show file extensions + hidden files: you are about to handle .apbx files.
$adv = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
Set-ItemProperty $adv HideFileExt 0 -Force -ErrorAction SilentlyContinue
Set-ItemProperty $adv Hidden      1 -Force -ErrorAction SilentlyContinue

# Atlas requires UCPD disabled; do it now so the reboot lands before the wizard.
Write-Step 'Disabling UCPD (Atlas requirement)'
try {
    Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\UCPD' -Name Start -Value 4 -Force -ErrorAction Stop
    Disable-ScheduledTask -TaskPath '\Microsoft\Windows\AppxDeploymentClient\' `
        -TaskName 'UCPD velocity' -ErrorAction SilentlyContinue | Out-Null
    Write-Host 'UCPD set to disabled (effective after reboot).'
} catch { Write-Warning "UCPD: $_" }

# --------------------------------------------------------------- Atlas assets
$payload = Join-Path $Root 'payload'
if ($AtlasMode -ne 'none') {
    Write-Step 'Staging AtlasOS assets'

    # Prefer the copies the host already downloaded onto the provisioning CD.
    $fromMedia = $false
    foreach ($d in (Get-PSDrive -PSProvider FileSystem).Name) {
        $src = "${d}:\atlas"
        if (Test-Path (Join-Path $src 'AME_Wizard_Beta.zip')) {
            Copy-Item "$src\*" $payload -Recurse -Force
            $fromMedia = $true
            Write-Host "Copied Atlas payload from ${d}:\atlas"
            break
        }
    }

    if (-not $fromMedia) {
        Write-Host 'Payload not on media - downloading in-guest.'
        $dl = @(
            @{ u = 'https://download.amelabs.net/AME%20Wizard%20Beta.zip'; f = 'AME_Wizard_Beta.zip' }
        )
        try {
            $rel = Invoke-RestMethod 'https://api.github.com/repos/Atlas-OS/Atlas/releases/latest' `
                     -Headers @{ 'User-Agent' = 'atlas-lab' } -TimeoutSec 60
            $apbx = $rel.assets | Where-Object { $_.name -like '*.apbx' } | Select-Object -First 1
            if ($apbx) { $dl += @{ u = $apbx.browser_download_url; f = $apbx.name } }
        } catch { Write-Warning "Could not query Atlas releases: $_" }

        foreach ($item in $dl) {
            try {
                Invoke-WebRequest $item.u -OutFile (Join-Path $payload $item.f) -UseBasicParsing -TimeoutSec 600
                Write-Host "  downloaded $($item.f)"
            } catch { Write-Warning "  failed $($item.f): $_" }
        }
    }

    # Unpack the wizard so the operator has a double-clickable exe.
    $zip = Join-Path $payload 'AME_Wizard_Beta.zip'
    if (Test-Path $zip) {
        Expand-Archive $zip -DestinationPath (Join-Path $payload 'AMEWizard') -Force
        Write-Host 'AME Wizard extracted.'
    }

    Copy-Item (Join-Path $Root 'scripts\Launch-Atlas.cmd')   $Desktop -Force -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $Root 'scripts\README-DESKTOP.txt') $Desktop -Force -ErrorAction SilentlyContinue

    $inv = Get-ChildItem $payload -Recurse -File |
           Select-Object @{n='name';e={$_.Name}}, @{n='mb';e={[math]::Round($_.Length/1MB,2)}}
    Send-Beacon -Stage 'atlas_staged' -Data @{ files = @($inv); mode = $AtlasMode }
}

# ------------------------------------------------------------------ checklist
Write-Step 'Running AtlasOS readiness checklist'
$checklist = & (Join-Path $Root 'scripts\atlas-preflight.ps1')
Send-Beacon -Stage 'checklist' -Data $checklist

if ($AtlasMode -eq 'stage') {
    Send-Beacon -Stage 'ready' -Data @{
        message = 'AME Wizard staged on the Public Desktop. Open the noVNC URL and run Launch-Atlas.cmd.'
    }
}

Write-Step 'Bootstrap complete'
Stop-Transcript | Out-Null

# Heartbeat so the host can distinguish "guest alive" from "guest hung".
Start-Job -Name AtlasHeartbeat -ScriptBlock {
    param($h, $p)
    while ($true) {
        try {
            $up = [int]((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalSeconds
            Invoke-RestMethod "http://${h}:${p}/beacon?stage=heartbeat&data=%7B%22uptime%22%3A$up%7D" -TimeoutSec 10 | Out-Null
        } catch { }
        Start-Sleep -Seconds 60
    }
} -ArgumentList $BeaconHost, $BeaconPort | Out-Null
