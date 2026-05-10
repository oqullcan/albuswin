#Requires -RunAsAdministrator

#  ── ogulcan yetim - albuswin
#  ── https://www.github.com/oqullcan/albuswin
#  ── https://www.x.com/oqullcn

#  ── bootstrap ─────────────────────────────────────────

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls13, [Net.SecurityProtocolType]::Tls12

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "albus requires administrator privileges."; exit 1
}

#  ── constants ─────────────────────────────────────────

$ALBUS_DIR     = 'C:\Albus'
$ALBUS_LOG     = "$ALBUS_DIR\albus.log"
$ALBUS_VERSION = '6.2'
$TODAY         = Get-Date

$script:ActiveSID = $null
try {
    $explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($explorer) { $script:ActiveSID = (Invoke-CimMethod -InputObject $explorer -MethodName GetOwnerSid).Sid }
} catch { }

$HKCU_ROOT = if ($script:ActiveSID) { "HKEY_USERS\$script:ActiveSID" } else { "HKEY_CURRENT_USER" }
$HKCU_PS =   if ($script:ActiveSID) { "Registry::HKEY_USERS\$script:ActiveSID" } else { "HKCU:" }

# ── logging & ui ──────────────────────────────────────

if (-not (Test-Path $ALBUS_DIR)) { New-Item -ItemType Directory -Path $ALBUS_DIR -Force | Out-Null }

$script:PhaseTimer = $null

function Write-Log {
    param([string]$Message)
    $entry = "[$(Get-Date -Format 'HH:mm:ss')] $Message"
    Add-Content -Path $ALBUS_LOG -Value $entry -ErrorAction SilentlyContinue
}

function Write-Phase {
    param([string]$Name)
    $script:PhaseTimer = [Diagnostics.Stopwatch]::StartNew()
    $line = '─' * (60 - $Name.Length - 3)
    Write-Host ""
    Write-Host "  ┌─ " -NoNewline -ForegroundColor DarkGray
    Write-Host $Name.ToUpper() -NoNewline -ForegroundColor White
    Write-Host " $line" -ForegroundColor DarkGray
    Write-Log "PHASE: $Name"
}

function Write-Done {
    param([string]$Name)
    $elapsed = if ($script:PhaseTimer) { "$([math]::Round($script:PhaseTimer.Elapsed.TotalSeconds, 1))s" } else { "" }
    Write-Host "  └─ " -NoNewline -ForegroundColor DarkGray
    Write-Host "done" -NoNewline -ForegroundColor Green
    Write-Host " [$elapsed]" -ForegroundColor DarkGray
}

function Write-Step {
    param([string]$Message, [string]$Status = 'run')
    $icon, $color = switch ($Status) {
        'run'  { '·', 'DarkGray' }
        'ok'   { '✓', 'Green' }
        'skip' { '○', 'DarkGray' }
        'fail' { '✗', 'Red' }
        'warn' { '!', 'Yellow' }
        'query' { '?', 'Cyan' }
    }
    Write-Host "  │  $icon " -NoNewline -ForegroundColor $color
    Write-Host $Message.ToLower() -ForegroundColor Gray
    Write-Log "  [$Status] $Message"
}

function Read-Choice {
    param(
        [string]$Title,
        [string]$Question,
        [array]$Options
    )
    $script:PhaseTimer = [Diagnostics.Stopwatch]::StartNew()
    $line = '─' * (60 - $Title.Length - 3)
    Write-Host ""
    Write-Host "  ┌─ " -NoNewline -ForegroundColor DarkGray
    Write-Host $Title.ToUpper() -NoNewline -ForegroundColor White
    Write-Host " $line" -ForegroundColor DarkGray
    Write-Host "  │  ? " -NoNewline -ForegroundColor Cyan
    $validLabels = $Options.Label -join '/'
    Write-Host "$Question ($validLabels): " -NoNewline -ForegroundColor Gray
    return (Read-Host).Trim()
}

#  print banner
function Write-Banner {
    [Console]::Title = "albus v$ALBUS_VERSION"
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name.Split('\')[-1].ToLower()
    Write-Host ""
    Write-Host "  albus " -NoNewline -ForegroundColor White
    Write-Host "v$ALBUS_VERSION" -NoNewline -ForegroundColor DarkGray
    Write-Host "  ·  " -NoNewline -ForegroundColor DarkGray
    Write-Host $user -ForegroundColor DarkGray
    Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor DarkGray
    Write-Host ""
}

#  download file from url
function Get-File {
    param([string]$Url, [string]$Dest)
    Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -ErrorAction Stop
}

# ── registry engine ───────────────────────────────────

function Initialize-Drives {
    foreach ($d in @('HKCR', 'HKU')) {
        if (-not (Get-PSDrive -Name $d -ErrorAction SilentlyContinue)) {
            $root = if ($d -eq 'HKCR') { 'HKEY_CLASSES_ROOT' } else { 'HKEY_USERS' }
            New-PSDrive -Name $d -PSProvider Registry -Root $root | Out-Null
        }
    }
}

function Resolve-RegistryPath {
    param([string]$Path)
    $clean = $Path.TrimStart('-') -replace '^Microsoft\.PowerShell\.Core\\Registry::', '' -replace '^Registry::', ''
    $clean = $clean -replace '^HKLM:', 'HKEY_LOCAL_MACHINE' `
                    -replace '^HKCU:', $HKCU_ROOT `
                    -replace '^HKCR:', 'HKEY_CLASSES_ROOT' `
                    -replace '^HKU:',  'HKEY_USERS'
    $psPath = "Registry::$clean"
    $regPath = $clean -replace '^HKEY_LOCAL_MACHINE', 'LocalMachine' `
                      -replace '^HKEY_CURRENT_USER',  'CurrentUser' `
                      -replace '^HKEY_CLASSES_ROOT',  'ClassesRoot' `
                      -replace '^HKEY_USERS',         'Users'
    return $psPath, $regPath
}

function Set-Reg {
    param(
        [string]$Path,
        [string]$Name,
        $Value,
        [string]$Type = 'DWord'
    )
    try {
        $delete = $Path.StartsWith('-')
        $psPath, $regPath = Resolve-RegistryPath $Path

        if ($delete) {
            if (Test-Path $psPath) { Remove-Item -Path $psPath -Recurse -Force -ErrorAction SilentlyContinue }
            return
        }

        if ($Value -eq '-') {
            if (Test-Path $psPath) { Remove-ItemProperty -Path $psPath -Name $Name -Force -ErrorAction SilentlyContinue }
            return
        }

        $hive, $subKey = $regPath.Split('\', 2)
        $root = [Microsoft.Win32.Registry]::$hive

        $regType = switch ($Type) {
            'String'       { [Microsoft.Win32.RegistryValueKind]::String }
            'ExpandString' { [Microsoft.Win32.RegistryValueKind]::ExpandString }
            'Binary'       { [Microsoft.Win32.RegistryValueKind]::Binary }
            'DWord'        { [Microsoft.Win32.RegistryValueKind]::DWord }
            'MultiString'  { [Microsoft.Win32.RegistryValueKind]::MultiString }
            'QWord'        { [Microsoft.Win32.RegistryValueKind]::QWord }
            default        { [Microsoft.Win32.RegistryValueKind]::DWord }
        }

        $key = $root.CreateSubKey($subKey)
        if ($key) {
            $finalValue = $Value
            if ($regType -eq 'DWord') { $finalValue = [int32]$Value }
            elseif ($regType -eq 'QWord') { $finalValue = [int64]$Value }
            $key.SetValue($Name, $finalValue, $regType)
            $key.Close()
        }
    } catch {
        Write-Log "REG ERR: $Path\$Name — $_"
    }
}

function Set-Tweaks {
    param(
        [string]$Path,
        [hashtable]$Settings,
        [string]$Type = 'DWord'
    )
    try {
        $psPath, $regPath = Resolve-RegistryPath $Path
        $hive, $subKey = $regPath.Split('\', 2)
        $root = [Microsoft.Win32.Registry]::$hive
        $key = $root.CreateSubKey($subKey)

        if ($key) {
            foreach ($name in $Settings.Keys) {
                $val = $Settings[$name]
                $regType = switch ($Type) {
                    'String'       { [Microsoft.Win32.RegistryValueKind]::String }
                    'ExpandString' { [Microsoft.Win32.RegistryValueKind]::ExpandString }
                    'Binary'       { [Microsoft.Win32.RegistryValueKind]::Binary }
                    'DWord'        { [Microsoft.Win32.RegistryValueKind]::DWord }
                    'MultiString'  { [Microsoft.Win32.RegistryValueKind]::MultiString }
                    'QWord'        { [Microsoft.Win32.RegistryValueKind]::QWord }
                    default        { [Microsoft.Win32.RegistryValueKind]::DWord }
                }
                $key.SetValue($name, $val, $regType)
            }
            $key.Close()
        }
    } catch {
        Write-Log "TWEAK ERR: $Path — $_"
    }
}

function Set-Regs {
    param([array]$Tweaks)
    foreach ($t in $Tweaks) {
        $tName = if ($t.Name) { $t.Name } else { '' }
        $tType = if ($t.Type) { $t.Type } else { 'DWord' }
        Set-Reg -Path $t.Path -Name $tName -Value $t.Value -Type $tType
    }
}

# ── network helper ────────────────────────────────────

function Test-Network {
    return (Test-Connection -ComputerName '1.1.1.1' -Count 3 -Quiet -ErrorAction SilentlyContinue)
}

#  ════════════════════════════════════════════════════════════
#  execution begins
#  ════════════════════════════════════════════════════════════

Write-Banner
Initialize-Drives

# ════════════════════════════════════════════════════════════
#  PHASE 11 · DEBLOAT
#  UWP removal, Edge, OneDrive.
#  Runs late — all services are stopped, state is clean.
# ════════════════════════════════════════════════════════════

Write-Phase 'debloat'

Write-Step 'removing uwp bloat'
$keepList = @(
    '*CBS*'
    '*Microsoft.AV1VideoExtension*'
    '*Microsoft.AVCEncoderVideoExtension*'
    '*Microsoft.HEIFImageExtension*'
    '*Microsoft.HEVCVideoExtension*'
    '*Microsoft.MPEG2VideoExtension*'
    '*Microsoft.Paint*'
    '*Microsoft.RawImageExtension*'
    '*Microsoft.VP9VideoExtensions*'
    '*Microsoft.WebMediaExtensions*'
    '*Microsoft.WebpImageExtension*'
    '*Microsoft.Windows.ShellExperienceHost*'
    '*Microsoft.Windows.StartMenuExperienceHost*'
    '*Microsoft.WindowsNotepad*'
    '*Microsoft.WindowsStore*'
    '*NVIDIACorp.NVIDIAControlPanel*'
    '*Microsoft.ImmersiveControlPanel*'
    '*Windows.ImmersiveControlPanel*'
    '*Microsoft.WindowsCalculator*'
    '*VCLibs*'
    '*UI.Xaml*'
    '*NET.Native*'
)
function Test-ShouldKeep {
    param([string]$Name)
    foreach ($p in $keepList) {
        if ($Name -like $p) { return $true }
    }
    return $false
}

function Remove-UWPAppAggressive {
    param($PackageRecord)
    $AppxStoreRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore'
    $famName  = $PackageRecord.PackageFamilyName
    $fullName = $PackageRecord.PackageFullName

    $deprovKey = Join-Path $AppxStoreRoot "Deprovisioned\$famName"
    if (-not (Test-Path -LiteralPath $deprovKey)) {
        New-Item -Path $deprovKey -Force -ErrorAction SilentlyContinue | Out-Null
    }
    $inboxKey = Join-Path $AppxStoreRoot "InboxApplications\$fullName"
    if (Test-Path -LiteralPath $inboxKey) {
        Remove-Item -LiteralPath $inboxKey -Force -ErrorAction SilentlyContinue
    }

    if ($PackageRecord.NonRemovable -eq 1) {
        try { Set-NonRemovableAppsPolicy -Online -PackageFamilyName $famName -NonRemovable 0 -ErrorAction SilentlyContinue | Out-Null } catch {}
    }

    $installRoot = $PackageRecord.InstallLocation
    if ($installRoot) {
        Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
            $procPath = $null
            try { $procPath = $_.Path } catch {}
            if ($procPath -and $procPath.StartsWith($installRoot, [StringComparison]::OrdinalIgnoreCase)) {
                try { $_ | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
            }
        }
    }
    $publisherToken = ($famName -split '_', 2)[0]
    if ($publisherToken) {
        Get-Process -Name "*$publisherToken*" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 200

    if ($PackageRecord.PackageUserInformation) {
        foreach ($userRec in $PackageRecord.PackageUserInformation) {
            $thisSid = $null
            try { $thisSid = $userRec.UserSecurityID.SID } catch {}
            if (-not $thisSid) { continue }

            $eolKey = Join-Path $AppxStoreRoot "EndOfLife\$thisSid\$fullName"
            New-Item -Path $eolKey -Force -ErrorAction SilentlyContinue | Out-Null
            
            try { Remove-AppxPackage -Package $fullName -User $thisSid -ErrorAction SilentlyContinue | Out-Null } catch {}
        }
    }

    try { Remove-AppxPackage -Package $fullName -AllUsers -ErrorAction SilentlyContinue | Out-Null } catch {}
}

Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
    Where-Object {
        -not $_.IsFramework -and
        $_.InstallLocation -notmatch '(?i)\\SystemApps\\' -and
        -not (Test-ShouldKeep $_.Name)
    } |
    ForEach-Object {
        Remove-UWPAppAggressive -PackageRecord $_
    }

Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
    Where-Object {
        $_.InstallLocation -notmatch '(?i)\\SystemApps\\' -and
        -not (Test-ShouldKeep $_.DisplayName)
    } |
    ForEach-Object {
        try { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -NoRestart -ErrorAction SilentlyContinue | Out-Null } catch {}
    }

# windows capabilities
Write-Step 'removing windows capabilities'
$keepCapabilities = @(
    'Ethernet', 'WiFi', 'Notepad', 'NetFX3', 'VBSCRIPT', 'WMIC', 'ShellComponents',
    'Language', 'Speech', 'TextToSpeech', 'Print', 'OpenSSH', 'Browser'
)
$capRegex = '(?i)' + ($keepCapabilities -join '|')

try {
    $capsToRemove = Get-WindowsCapability -Online -ErrorAction Stop | Where-Object {
        $_.State -eq 'Installed' -and $_.Name -notmatch $capRegex
    }
    
    if ($capsToRemove) {
        foreach ($cap in $capsToRemove) {
            $capName = $cap.Name.Split('~')[0].ToLower()
            Write-Step "capability: $capName" 'run'
            try {
                Remove-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null
                Write-Step "capability: $capName" 'ok'
            } catch {
                Write-Step "capability: $capName" 'fail'
            }
        }
    }
} catch { Write-Step 'capability removal skipped' 'warn' }

# optional features
Write-Step 'disabling optional features'
$keepFeatures = @(
    'DirectPlay', 'LegacyComponents', 'NetFx', 'SearchEngine-Client', 'Server-Shell',
    'Windows-Defender', 'Drivers-General', 'Server-Gui-Mgmt', 'WirelessNetworking',
    'PowerShell', 'Subsystem-Linux', 'VirtualMachinePlatform'
)
$featRegex = '(?i)' + ($keepFeatures -join '|')

try {
    $featsToDisable = Get-WindowsOptionalFeature -Online -ErrorAction Stop | Where-Object {
        $_.State -eq 'Enabled' -and $_.FeatureName -notmatch $featRegex
    }

    if ($featsToDisable) {
        foreach ($feat in $featsToDisable) {
            $featName = $feat.FeatureName.ToLower()
            Write-Step "feature: $featName" 'run'
            try {
                Disable-WindowsOptionalFeature -Online -FeatureName $feat.FeatureName -NoRestart -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
                Write-Step "feature: $featName" 'ok'
            } catch {
                Write-Step "feature: $featName" 'fail'
            }
        }
    }
} catch { Write-Step 'optional feature removal skipped' 'warn' }

# ── edge ──────────────────────────────────────────────────
Write-Step 'removing microsoft edge'

function Remove-MicrosoftEdgeAll {
    $updRoot = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate'

    Write-Step 'stopping edge processes' 'run'
    $edgeProcs = @('msedge','MicrosoftEdgeUpdate','MicrosoftEdge','msedgewebview2','setup','identity_helper','msedge_proxy','MicrosoftEdgeUpdateBroker','MicrosoftEdgeUpdateOnDemand','MicrosoftEdgeUpdateComRegisterShell64','msedgeupdate')
    foreach ($pname in $edgeProcs) {
        Get-Process -Name $pname -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    Write-Step 'disabling edge tasks & services' 'run'
    @('\MicrosoftEdgeUpdateTaskMachineCore', '\MicrosoftEdgeUpdateTaskMachineUA', '\MicrosoftEdgeUpdateBrowserReplacementTask', '\MicrosoftEdgeUpdateTaskMachineCoreSystem') | ForEach-Object {
        try { Disable-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue | Out-Null } catch {}
        try { Unregister-ScheduledTask -TaskName $_ -Confirm:$false -ErrorAction SilentlyContinue } catch {}
        $tn = $_.TrimStart('\')
        $tf = "$env:windir\System32\Tasks\$tn"
        if (Test-Path $tf) {
            Remove-Item -Path $tf -Force -ErrorAction SilentlyContinue
        }
    }

    @('edgeupdate','edgeupdatem','MicrosoftEdgeElevationService') | ForEach-Object {
        try { Stop-Service -Name $_ -Force -ErrorAction SilentlyContinue } catch {}
        & sc.exe config $_ start= disabled 2>&1 | Out-Null
        & sc.exe delete $_ 2>&1 | Out-Null
    }

    [Microsoft.Win32.Registry]::SetValue('HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdateDev', 'AllowUninstall', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge' -Name 'NoRemove' -ErrorAction SilentlyContinue | Out-Null
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update' -Name 'NoRemove' -ErrorAction SilentlyContinue | Out-Null
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft EdgeWebView' -Name 'NoRemove' -ErrorAction SilentlyContinue | Out-Null

    Write-Step 'removing edge appx packages' 'run'
    $edgePkg = Get-AppxPackage -AllUsers -Name 'Microsoft.MicrosoftEdge*' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*WebView*' }
    foreach ($pkg in $edgePkg) {
        try { Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction SilentlyContinue | Out-Null } catch {}
    }

    Write-Step 'executing edge uninstaller' 'run'
    $edgeDirs = @("$env:ProgramFiles\Microsoft\Edge", "${env:ProgramFiles(x86)}\Microsoft\Edge")
    foreach ($d in $edgeDirs) {
        if ($d -and (Test-Path $d)) {
            $appDir = Join-Path $d 'Application'
            if (Test-Path $appDir) {
                $ver = Get-ChildItem $appDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+\.' } | Select-Object -First 1
                if ($ver) {
                    $setupExe = Join-Path $ver.FullName 'Installer\setup.exe'
                    if (Test-Path $setupExe) {
                        Start-Process $setupExe -ArgumentList '--uninstall --system-level --verbose-logging --force-uninstall' -Wait -NoNewWindow -ErrorAction SilentlyContinue | Out-Null
                    }
                }
            }
        }
    }

    $csPaths = @("$updRoot\ClientState\{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}", "$updRoot\ClientState\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}")
    foreach ($csPath in $csPaths) {
        if (Test-Path $csPath) {
            Remove-ItemProperty -Path $csPath -Name 'experiment_control_labels' -ErrorAction SilentlyContinue | Out-Null
            $fakeDir = "$env:SystemRoot\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe"
            if (!(Test-Path $fakeDir)) { New-Item -ItemType Directory -Path $fakeDir -Force -ErrorAction SilentlyContinue | Out-Null }
            New-Item -ItemType File -Path "$fakeDir\MicrosoftEdge.exe" -Force -ErrorAction SilentlyContinue | Out-Null
            
            $prevWinDir = $env:windir; $env:windir = ''
            $exe = (Get-ItemProperty -Path $csPath -ErrorAction SilentlyContinue).UninstallString
            $uargs = (Get-ItemProperty -Path $csPath -ErrorAction SilentlyContinue).UninstallArguments
            
            if ($exe -and $uargs -and (Test-Path $exe)) {
                $uargs += ' --force-uninstall --delete-profile'
                $spoofPath = "$env:SystemRoot\ImmersiveControlPanel\sihost.exe"
                try {
                    if (!(Test-Path "$env:SystemRoot\ImmersiveControlPanel")) { New-Item -ItemType Directory -Path "$env:SystemRoot\ImmersiveControlPanel" -Force -ErrorAction SilentlyContinue | Out-Null }
                    Copy-Item "$env:SystemRoot\System32\cmd.exe" -Destination $spoofPath -Force -ErrorAction SilentlyContinue
                    Start-Process -FilePath $spoofPath -ArgumentList "/c `"$exe`" $uargs" -Wait -NoNewWindow -ErrorAction SilentlyContinue | Out-Null
                } finally {
                    Remove-Item $spoofPath -Force -ErrorAction SilentlyContinue
                }
            }
            $env:windir = $prevWinDir
        }
    }

    $unCmd = (Get-ItemProperty -Path $updRoot -ErrorAction SilentlyContinue).UninstallCmdLine
    if ($unCmd) {
        Start-Process cmd.exe -ArgumentList "/c $unCmd" -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue | Out-Null
    }

    foreach ($pname in $edgeProcs) {
        Get-Process -Name $pname -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    Write-Step 'cleaning up shortcuts & files' 'run'
    $desktopPaths = @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs","$env:PUBLIC\Desktop")
    Get-ChildItem 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('Public','Default','Default User','All Users','WDAGUtilityAccount') } | ForEach-Object {
        $desktopPaths += (Join-Path $_.FullName 'Desktop')
    }
    foreach ($p in $desktopPaths) {
        Remove-Item (Join-Path $p 'Microsoft Edge.lnk') -Force -ErrorAction SilentlyContinue
    }

    $edgeUpdateDirs = @(
        "$env:ProgramFiles\Microsoft\EdgeUpdate", "${env:ProgramFiles(x86)}\Microsoft\EdgeUpdate",
        "$env:ProgramFiles\Microsoft\EdgeCore", "${env:ProgramFiles(x86)}\Microsoft\EdgeCore"
    )
    foreach ($d in ($edgeDirs + $edgeUpdateDirs)) {
        if ($d -and (Test-Path $d)) { Remove-Item -Path $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Get-ChildItem 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('Public','Default','Default User','All Users','WDAGUtilityAccount') } | ForEach-Object {
        foreach ($sub in @('Microsoft\Edge','Microsoft\EdgeUpdate','Microsoft\EdgeCore','Microsoft\EdgeWebView')) {
            $p = Join-Path $_.FullName "AppData\Local\$sub"
            if (Test-Path $p) { Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Write-Step 'purging edge registry keys' 'run'
    foreach ($k in @(
        'HKLM:\SOFTWARE\Microsoft\Edge', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Edge',
        'HKLM:\SOFTWARE\Microsoft\EdgeUpdate', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft EdgeWebView',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update'
    )) {
        if (Test-Path $k) { Remove-Item -Path $k -Recurse -Force -ErrorAction SilentlyContinue }
    }

    $liveUserKeys = @()
    try {
        if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
            New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS | Out-Null
        }
        $liveUserKeys = Get-ChildItem -Path 'Registry::HKU' -ErrorAction SilentlyContinue | Where-Object {
            ($_.PSChildName -match '^S-1-5-21-' -and $_.PSChildName -notmatch '_Classes$') -or $_.PSChildName -match '^Albus_UserHive_'
        }
    } catch {}

    foreach ($userKey in $liveUserKeys) {
        $sid = $userKey.PSChildName
        $hivePath = "Registry::HKU\$sid"
        $appData = $null
        if ($sid -match '^Albus_UserHive_') {
            $appData = "$env:SystemDrive\Users\Default\AppData\Roaming"
        } else {
            try {
                $sf = "$hivePath\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"
                $appData = (Get-ItemProperty -Path $sf -Name 'AppData' -ErrorAction SilentlyContinue).AppData
            } catch {}
            if ([string]::IsNullOrEmpty($appData) -or -not (Test-Path $appData)) {
                try {
                    $profileList = "Registry::HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
                    $profPath = (Get-ItemProperty -Path $profileList -Name 'ProfileImagePath' -ErrorAction SilentlyContinue).ProfileImagePath
                    if ($profPath -and (Test-Path $profPath)) { $appData = Join-Path $profPath 'AppData\Roaming' }
                } catch {}
            }
        }
        if (-not [string]::IsNullOrEmpty($appData) -and (Test-Path $appData)) {
            $taskBarDir = Join-Path $appData 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
            if (Test-Path $taskBarDir) {
                Get-ChildItem -Path $taskBarDir -File -Force -ErrorAction SilentlyContinue | Where-Object {
                    $_.Name -match '^Microsoft Edge.*\.lnk$' -or $_.Name -ieq 'Edge.lnk'
                } | Remove-Item -Force -ErrorAction SilentlyContinue
            }
            $implicitDir = Join-Path $taskBarDir 'ImplicitAppShortcuts'
            if (Test-Path $implicitDir) {
                Get-ChildItem -Path $implicitDir -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {
                    $_.Name -match '^Microsoft Edge.*\.lnk$' -or $_.Name -ieq 'Edge.lnk'
                } | Remove-Item -Force -ErrorAction SilentlyContinue
            }
        }
        $taskband = "$hivePath\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Taskband"
        if (Test-Path $taskband) {
            try { Remove-ItemProperty -Path $taskband -Name 'Favorites' -Force -ErrorAction SilentlyContinue } catch {}
            try { Remove-ItemProperty -Path $taskband -Name 'FavoritesResolve' -Force -ErrorAction SilentlyContinue } catch {}
            try { Remove-ItemProperty -Path $taskband -Name 'Pinned' -Force -ErrorAction SilentlyContinue } catch {}
            try { Set-ItemProperty -Path $taskband -Name 'FavoritesChanges' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue } catch {}
        }
        $auxPins = "$taskband\AuxilliaryPins"
        if (Test-Path $auxPins) {
            try { Set-ItemProperty -Path $auxPins -Name 'EdgePin' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue } catch {}
        }
    }

    try {
        $sig = '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);'
        $type = Add-Type -MemberDefinition $sig -Name 'AlbusShellRefresh' -Namespace 'Albus' -PassThru -ErrorAction SilentlyContinue
        if ($type) { $type::SHChangeNotify(0x08000000, 0x1000, [IntPtr]::Zero, [IntPtr]::Zero) }
    } catch {}

    Write-Step 'edge completely removed' 'ok'
}

Remove-MicrosoftEdgeAll

# ── onedrive ──────────────────────────────────────────────
Write-Step 'removing onedrive'

function Remove-OneDrive {
    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS | Out-Null
    }
    $exePaths = New-Object System.Collections.Generic.List[string]
    $fallbackPaths = @(
        "$env:SystemRoot\System32\OneDriveSetup.exe",
        "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
    )
    Get-ChildItem 'HKU:\' -ErrorAction SilentlyContinue | ForEach-Object {
        $sid = $_.PSChildName
        if ($sid -notmatch '^S-1-5-21-') { return }
        $regPath = "HKU:\$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe"
        try {
            $uninstallStr = (Get-ItemProperty -Path $regPath -ErrorAction Stop).UninstallString
        } catch {
            $uninstallStr = $null
        }
        if ($uninstallStr) {
            $exePath = $null
            if ($uninstallStr -match '^"(.+?)"') {
                $exePath = $matches[1]
            } else {
                $exePath = $uninstallStr.Split(' ')[0]
            }
            if ($exePath -and (Test-Path $exePath)) {
                $exePaths.Add($exePath) | Out-Null
            }
        }
        Remove-ItemProperty `
            -Path "HKU:\$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" `
            -Name 'OneDrive' `
            -ErrorAction SilentlyContinue
        Remove-Item -Path $regPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    foreach ($f in $fallbackPaths) {
        if (Test-Path $f) {
            $exePaths.Add($f) | Out-Null
        }
    }
    $exePaths = $exePaths | Select-Object -Unique
    foreach ($exe in $exePaths) {
        try {
            Write-Step "uninstalling onedrive → $exe"
            Start-Process -FilePath $exe -ArgumentList '/uninstall' -Wait -NoNewWindow | Out-Null
        } catch {}
    }
    try {
        Get-AppxProvisionedPackage -Online | Where-Object {
            $_.DisplayName -like '*OneDrive*'
        } | ForEach-Object {
            Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue
        }
    } catch {}
    try {
        Get-AppxPackage -AllUsers *OneDrive* | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    } catch {}
    Get-ChildItem "$env:SystemDrive\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $paths = @(
            "$($_.FullName)\OneDrive",
            "$($_.FullName)\AppData\Local\Microsoft\OneDrive",
            "$($_.FullName)\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\OneDrive.lnk"
        )
        foreach ($p in $paths) {
            if (Test-Path $p) {
                Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $clsid = '{018D5C66-4533-4307-9B53-224DE2ED1FE6}'
    try {
        New-Item -Path "HKCR:\CLSID\$clsid" -Force | Out-Null
        Set-ItemProperty -Path "HKCR:\CLSID\$clsid" -Name 'System.IsPinnedToNameSpaceTree' -Value 0 -Type DWord
    } catch {}
    try {
        New-Item -Path "HKCR:\Wow6432Node\CLSID\$clsid" -Force | Out-Null
        Set-ItemProperty -Path "HKCR:\Wow6432Node\CLSID\$clsid" -Name 'System.IsPinnedToNameSpaceTree' -Value 0 -Type DWord
    } catch {}
    Write-Step 'onedrive removal complete'
}

Remove-OneDrive

# ════════════════════════════════════════════════════════════
#  WINSXS · TELEMETRY & AI PURGE
# ════════════════════════════════════════════════════════════
Write-Phase 'telemetry & ai purge'

# ── binary nötralize ──────────────────────────────────────
Write-Step 'neutralizing telemetry & ai binaries'
$purgeBinaries = @(
    # telemetry
    "$env:SystemRoot\System32\CompatTelRunner.exe"
    "$env:SystemRoot\System32\DeviceCensus.exe"
    "$env:SystemRoot\System32\AggregatorHost.exe"
    "$env:SystemRoot\System32\wsqmcons.exe"
    "$env:SystemRoot\System32\WerFault.exe"
    "$env:SystemRoot\System32\WerFaultSecure.exe"
    "$env:SystemRoot\System32\wermgr.exe"
    "$env:SystemRoot\System32\omadmclient.exe"
    "$env:SystemRoot\System32\DiagSvcs\DiagnosticsHub.StandardCollector.Service.exe"
    "$env:SystemRoot\SysWOW64\CompatTelRunner.exe"
    "$env:SystemRoot\SysWOW64\DeviceCensus.exe"
    # copilot & ai
    "$env:SystemRoot\System32\Copilot.exe"
    "$env:SystemRoot\SysWOW64\Copilot.exe"
    "$env:SystemRoot\System32\WindowsCopilotRuntimeActions.exe"
    # smartscreen
    "$env:SystemRoot\System32\smartscreen.exe"
)
foreach ($bin in $purgeBinaries) {
    if (-not (Test-Path $bin)) { continue }
    try {
        Rename-Item $bin "$bin.bak" -Force -ErrorAction Stop
        Write-Step "neutralized: $(Split-Path $bin -Leaf)" 'ok'
    } catch {
        Write-Step "skipped (locked): $(Split-Path $bin -Leaf)" 'warn'
    }
}

# ── dism package purge ────────────────────────────────────
Write-Step 'querying installed dism packages'

$allPackages = dism /Online /Get-Packages 2>$null |
    Where-Object { $_ -match '^\s*Package Identity\s*:' } |
    ForEach-Object { ($_ -split ':\s*', 2)[1].Trim() }

Write-Step "total packages found: $($allPackages.Count)" 'ok'

$dismTargets = @(
    'DiagTrack', 'Telemetry', 'CEIP', 'CEIPEnable', 'SQM',
    'UsbCeip', 'TelemetryClient', 'Unified-Telemetry', 'Update-Aggregators',
    'DataCollection', 'SetupPlatform-Telemetry', 'SettingsHandlers-SIUF',
    'SettingsHandlers-Flights', 'Application-Experience', 'Compat-Appraiser',
    'Compat-CompatTelRunner', 'Compat-GeneralTel', 'OneCoreUAP-Feedback',
    'Diagnostics-Telemetry', 'Diagnostics-TraceReporting', 'BuildFlighting',
    'Flighting', 'Feedback', 'FeedbackNotifications', 'StringFeedbackEngine',
    'ErrorReporting', 'Microsoft-Copilot', 'SettingsHandlers-Copilot',
    'UserExperience-AIX', 'UserExperience-CoreAI', 'AI-MachineLearning',
    'BingSearch', 'Windows-UNP', 'Cortana', 'AdvertisingId', 'RetailDemo',
    'OneDrive', 'QuickAssist', 'PeopleExperienceHost', 'OOBE-FirstLogonAnim',
    'Skype-ORTC', 'FlipGridPWA', 'OutlookPWA', 'PortableWorkspaces',
    'StepsRecorder', 'Holographic', 'Adobe-Flash', 'Bubbles', 'Mystify',
    'PhotoScreensaver', 'scrnsave', 'ssText3d', 'Shell-SoundThemes',
    'KeyboardDiagnostic', 'SecureAssessment', 'InputCloudStore',
    'Windows-Ribbons', 'PhotoBasic', 'shimgvw'
)

$removedCount = 0

foreach ($target in $dismTargets) {
    $matched = $allPackages | Where-Object { $_ -match $target }
    if (-not $matched) { continue }
    foreach ($pkg in $matched) {
        Write-Step "removing: $($pkg.Split('~')[0].ToLower())" 'run'
        $r = Start-Process dism `
            -ArgumentList "/Online /Remove-Package /PackageName:$pkg /NoRestart /Quiet" `
            -Wait -NoNewWindow -PassThru
        if ($r.ExitCode -eq 0) {
            Write-Step "removed: $($pkg.Split('~')[0].ToLower())" 'ok'
            $removedCount++
        } else {
            Write-Step "skip: $($pkg.Split('~')[0].ToLower())" 'warn'
        }
    }
}

if ($removedCount -eq 0) {
    Write-Step 'no targets found — system already clean' 'skip'
} else {
    Write-Step "dism purge complete — removed: $removedCount" 'ok'
}

# ── winsxs manifest deaktive ──────────────────────────────
Write-Step 'disabling telemetry & ai winsxs manifests'
$manifestPatterns = @(
    '*diagtrack*'
    '*telemetry*'
    '*ceip*'
    '*diaghub*'
    '*wer*'
    '*compattelrunner*'
    '*devicecensus*'
    '*sqmclient*'
    '*aggregatorhost*'
    '*copilot*'
    '*cortana*'
    '*bingsearch*'
    '*retaildemo*'
    '*feedback*'
    '*flighting*'
    '*errorrepor*'
)
$manifestDir = "$env:SystemRoot\WinSxS\Manifests"
foreach ($pattern in $manifestPatterns) {
    Get-ChildItem $manifestDir -Filter $pattern -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Rename-Item $_.FullName "$($_.FullName).bak" -Force -ErrorAction Stop
            Write-Step "manifest: $($_.Name)" 'ok'
        } catch {
            Write-Step "manifest locked: $($_.Name)" 'warn'
        }
    }
}

# ── dism component store cleanup ──────────────────────────
Write-Step 'dism component store cleanup'
$dismCleanup = @(
    '/Online /Cleanup-Image /StartComponentCleanup /ResetBase'
    '/Online /Cleanup-Image /SPSuperseded'
)
foreach ($arg in $dismCleanup) {
    $label = ($arg -split '/')[-1].Trim()
    Write-Step "dism: $label" 'run'
    $r = Start-Process dism -ArgumentList $arg -Wait -NoNewWindow -PassThru
    if ($r.ExitCode -eq 0) { Write-Step "dism: $label" 'ok' }
    else                   { Write-Step "dism: $label exit $($r.ExitCode)" 'warn' }
}

Write-Step 'telemetry & ai purge complete' 'ok'
Write-Done 'telemetry & ai purge'

# update health tools
Write-Step 'removing update health tools'
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match 'Update for x64-based Windows Systems|Microsoft Update Health Tools' } |
    ForEach-Object {
        if ($_.PSChildName) { Start-Process 'msiexec.exe' -ArgumentList "/x $($_.PSChildName) /qn /norestart" -Wait -NoNewWindow }
    }
sc.exe delete 'uhssvc' *>$null
Unregister-ScheduledTask -TaskName PLUGScheduler -Confirm:$false -ErrorAction SilentlyContinue

# gameinput
Write-Step 'removing microsoft gameinput'
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like '*Microsoft GameInput*' } |
    ForEach-Object { Start-Process 'msiexec.exe' -ArgumentList "/x $($_.PSChildName) /qn /norestart" -Wait -NoNewWindow }

# ════════════════════════════════════════════════════════════
#  DONE
# ════════════════════════════════════════════════════════════

$totalTime = [math]::Round(((Get-Date) - $TODAY).TotalMinutes, 1)

Write-Host ''
Write-Host '  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor DarkGray
Write-Host "     albus v$ALBUS_VERSION  ·  complete  ·  ${totalTime}m" -ForegroundColor White
Write-Host '  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor DarkGray
Write-Host ''
Write-Log "COMPLETE in ${totalTime}m"
Start-Sleep -Seconds 5
#shutdown -r -t 00
pause
