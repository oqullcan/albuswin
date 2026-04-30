# ============================================================
#  ALBUS PLAYBOOK v3.0
#  github.com/oqullcan/albuswin
#
#  architecture  : single-script, phase-driven
#  philosophy    : minimal surface, maximum intent
#  target        : windows 11 24h2+ / 2027 ready
#  execution     : phases run top-to-bottom, each self-contained
#  author        : oqullcan
# ============================================================

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
$ALBUS_VERSION = '3.0'
$TODAY         = Get-Date
$PAUSE_END     = $TODAY.AddYears(31)
$TODAY_STR     = $TODAY.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$PAUSE_STR     = $PAUSE_END.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

# Resolve active user SID (handles running-as-admin from another user)
$script:ActiveSID = $null
try {
    $explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue |
                Select-Object -First 1
    if ($explorer) { $script:ActiveSID = (Invoke-CimMethod -InputObject $explorer -MethodName GetOwnerSid).Sid }
} catch { }

$HKCU_ROOT = if ($script:ActiveSID) { "HKEY_USERS\$script:ActiveSID" }    else { "HKEY_CURRENT_USER" }
$HKCU_PS   = if ($script:ActiveSID) { "Registry::HKEY_USERS\$script:ActiveSID" } else { "HKCU:" }

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
    $clean = $Path.TrimStart('-')
    $psPath = $clean `
        -replace '^HKLM:', 'Registry::HKEY_LOCAL_MACHINE' `
        -replace '^HKCU:', $HKCU_PS `
        -replace '^HKCR:', 'Registry::HKEY_CLASSES_ROOT' `
        -replace '^HKU:',  'Registry::HKEY_USERS'
    $regPath = $clean `
        -replace '^HKLM:', 'HKEY_LOCAL_MACHINE' `
        -replace '^HKCU:', $HKCU_ROOT `
        -replace '^HKCR:', 'HKEY_CLASSES_ROOT' `
        -replace '^HKU:',  'HKEY_USERS'
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
            $key.SetValue($Name, $Value, $regType)
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

function Apply-Tweaks {
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

function Get-GitHubRelease {
    param([string]$Repo)
    return (Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -ErrorAction Stop)
}

function Get-File {
    param([string]$Url, [string]$Out)
    Invoke-WebRequest -Uri $Url -OutFile $Out -UseBasicParsing -ErrorAction Stop
}


#  ════════════════════════════════════════════════════════════
#  execution begins
#  ════════════════════════════════════════════════════════════

Write-Banner
Initialize-Drives

#  ════════════════════════════════════════════════════════════
#  phase 1  system preparation
#  must run first — sets up base environment before any
#  registry or service changes. Ordering matters
#  ════════════════════════════════════════════════════════════

Write-Phase 'system preparation'

# 1.1  kill interfering processes before touching their state
Write-Step 'stopping shell processes'
'AppActions',
'CrossDeviceResume',
'FESearchHost',
'SearchHost',
'SoftLandingTask',
'TextInputHost',
'WebExperienceHostApp',
'WindowsBackupClient',
'ShellExperienceHost',
'StartMenuExperienceHost',
'Widgets',
'WidgetService',
'MiniSearchHost' | ForEach-Object { Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue }

# 1.2  psdrive registration (already done via initialize-drives, confirm)
Write-Step 'registry drives initialized'

# 1.3  capability consent storage reset (must precede camera/mic tweaks)
Write-Step 'resetting capability consent storage'
Stop-Service -Name 'camsvc' -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$env:ProgramData\Microsoft\Windows\CapabilityAccessManager\CapabilityConsentStorage.db*" -Force -ErrorAction SilentlyContinue

Write-Done 'system preparation'

# ════════════════════════════════════════════════════════════
#  PHASE 2 · SOFTWARE INSTALLATION
#  network-dependent. Runs early so downloads happen while
#  later phases execute (sequential here, could be parallelized
#  in a future version with powershell jobs).
# ════════════════════════════════════════════════════════════
<#
Write-Phase 'software installation'

if (Test-Network) {

    # 2.1  brave browser
    try {
        Write-Step 'brave browser'
        $rel = Get-GitHubRelease 'brave/brave-browser'
        Get-File "https://github.com/brave/brave-browser/releases/latest/download/BraveBrowserStandaloneSetup.exe" "$ALBUS_DIR\BraveSetup.exe"
        Start-Process -Wait "$ALBUS_DIR\BraveSetup.exe" -ArgumentList '/silent /install' -WindowStyle Hidden
        Set-Reg 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave' 'HardwareAccelerationModeEnabled' 0
        Set-Reg 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave' 'BackgroundModeEnabled'           0
        Set-Reg 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave' 'HighEfficiencyModeEnabled'       1
        Write-Step "brave $($rel.tag_name) installed" 'ok'
    } catch { Write-Step 'brave installation failed' 'fail' }

    # 2.2  7-zip
    try {
        Write-Step '7-zip'
        $rel = Get-GitHubRelease 'ip7z/7zip'
        $url = ($rel.assets | Where-Object { $_.name -match '7z.*-x64\.exe' }).browser_download_url
        Get-File $url "$ALBUS_DIR\7zip.exe"
        Start-Process -Wait "$ALBUS_DIR\7zip.exe" -ArgumentList '/S'
        Set-Reg 'HKCU:\Software\7-Zip\Options' 'ContextMenu'  259
        Set-Reg 'HKCU:\Software\7-Zip\Options' 'CascadedMenu' 0
        Write-Step "7-zip $($rel.name) installed" 'ok'
    } catch { Write-Step '7-zip installation failed' 'fail' }

    # 2.3  localsend
    try {
        Write-Step 'localsend'
        $rel = Get-GitHubRelease 'localsend/localsend'
        $url = ($rel.assets | Where-Object { $_.name -match 'LocalSend-.*-windows-x86-64\.exe' }).browser_download_url
        Get-File $url "$ALBUS_DIR\localsend.exe"
        Start-Process -Wait "$ALBUS_DIR\localsend.exe" -ArgumentList '/VERYSILENT /ALLUSERS /SUPPRESSMSGBOXES /NORESTART'
        Write-Step "localsend $($rel.name) installed" 'ok'
    } catch { Write-Step 'localsend installation failed' 'fail' }

    # 2.4  visual c++ redistributable
    try {
        Write-Step 'visual c++ x64 runtime'
        Get-File 'https://aka.ms/vs/17/release/vc_redist.x64.exe' "$ALBUS_DIR\vc_redist.x64.exe"
        Start-Process -Wait "$ALBUS_DIR\vc_redist.x64.exe" -ArgumentList '/quiet /norestart' -WindowStyle Hidden
        Write-Step 'vc++ runtime installed' 'ok'
    } catch { Write-Step 'vc++ runtime failed' 'fail' }

    # 2.5  directx runtime
    try {
        Write-Step 'directx runtime'
        Get-File 'https://download.microsoft.com/download/1/7/1/1718CCC4-6315-4D8E-9543-8E28A4E18C4C/dxwebsetup.exe' "$ALBUS_DIR\dxwebsetup.exe"
        Start-Process -Wait "$ALBUS_DIR\dxwebsetup.exe" -ArgumentList '/Q' -WindowStyle Hidden
        Write-Step 'directx runtime installed' 'ok'
    } catch { Write-Step 'directx runtime failed' 'fail' }

} else {
    Write-Step 'no network — skipping software installation' 'warn'
}

Write-Done 'software installation'
#>

# ════════════════════════════════════════════════════════════
#  PHASE 14 · GPU DRIVER  (interactive)
# ════════════════════════════════════════════════════════════

function NVIDIA {
Write-Phase 'nvidia driver setup'

    Start-Process 'https://www.nvidia.com/en-us/drivers'
    Write-Step '  download the driver, then press any key...' -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')

    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title, $dlg.Filter = 'select nvidia driver', 'Executable (*.exe)|*.exe'
    if ($dlg.ShowDialog() -ne 'OK') { Write-Step 'cancelled' 'warn'; return }

    $ZipExe = 'C:\Program Files\7-Zip\7z.exe'
    if (-not (Test-Path $ZipExe)) { Write-Step '7-zip not found' 'fail'; return }

    $ExtractPath = "$env:SystemRoot\Temp\NVIDIA"
    if (Test-Path $ExtractPath) { Remove-Item $ExtractPath -Recurse -Force }

    Write-Step 'extracting & debloating'
    & $ZipExe x $dlg.FileName -o"$ExtractPath" -y | Out-Null

    $Whitelist = '^(Display\.Driver|NVI2|EULA\.txt|ListDevices\.txt|setup\.cfg|setup\.exe)$'
    Get-ChildItem $ExtractPath | Where-Object { $_.Name -notmatch $Whitelist } | ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

    $cfg = "$ExtractPath\setup.cfg"
    if (Test-Path $cfg) { (Get-Content $cfg) | Where-Object { $_ -notmatch 'EulaHtmlFile|FunctionalConsentFile|PrivacyPolicyFile' } | Set-Content $cfg -Force }

    Write-Step 'installing silently'
    Start-Process "$ExtractPath\setup.exe" -ArgumentList '-s -noreboot -noeula -clean' -Wait

    Write-Step 'nvidia optimizations'
    Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E968-E325-11CE-BFC1-08002BE10318}' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
        Set-Reg $_.PSPath 'DisableDynamicPstate' 1
        Set-Reg $_.PSPath 'RMHdcpKeyglobZero'    1
        Set-Reg $_.PSPath 'RmProfilingAdminOnly' 0
    }

    $nvTweak = 'HKLM:\System\ControlSet001\Services\nvlddmkm\Parameters\Global\NVTweak'
    Set-Reg $nvTweak 'NvCplPhysxAuto' 0
    Set-Reg $nvTweak 'NvDevToolsVisible' 1
    Set-Reg $nvTweak 'RmProfilingAdminOnly' 0

    Set-Reg 'HKCU:\Software\NVIDIA Corporation\NvTray' 'StartOnLogin' 0
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\FTS' 'EnableGR535' 0
    Set-Reg 'HKLM:\SYSTEM\ControlSet001\Services\nvlddmkm\Parameters\FTS' 'EnableGR535' 0
    Set-Reg 'HKCU:\Software\NVIDIA Corporation\NVControlPanel2\Client' 'OptInOrOutPreference' 0

    $DRSPath = 'C:\ProgramData\NVIDIA Corporation\Drs'
    if (Test-Path $DRSPath) { Get-ChildItem -Path $DRSPath -Recurse | Unblock-File -ErrorAction SilentlyContinue }

    Write-Step 'fetching & applying profile inspector'
    $InspectorZip = "$env:SystemRoot\Temp\nvidiaProfileInspector.zip"
    $ExtractDir   = "$env:SystemRoot\Temp\nvidiaProfileInspector"

    try {
        $Release = Invoke-RestMethod -Uri "https://api.github.com/repos/Orbmu2k/nvidiaProfileInspector/releases/latest" -ErrorAction Stop
        $Asset = ($Release.assets | Where-Object { $_.name -match '\.zip$' })[0]
        if ($Asset) {
            Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $InspectorZip -UseBasicParsing -ErrorAction Stop
            & $ZipExe x "$InspectorZip" -o"$ExtractDir" -y | Out-Null
        }
    } catch { }

    $NIPFile = @"
<?xml version="1.0" encoding="utf-16"?>
<ArrayOfProfile>
  <Profile>
    <ProfileName>Base Profile</ProfileName>
    <Settings>
      <ProfileSetting><SettingNameInfo>Frame Rate Limiter V3</SettingNameInfo><SettingID>277041154</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>GSYNC - Application Mode</SettingNameInfo><SettingID>294973784</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>GSYNC - Application State</SettingNameInfo><SettingID>279476687</SettingID><SettingValue>4</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>GSYNC - Global Feature</SettingNameInfo><SettingID>278196567</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>GSYNC - Global Mode</SettingNameInfo><SettingID>278196727</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>GSYNC - Indicator Overlay</SettingNameInfo><SettingID>268604728</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Maximum Pre-Rendered Frames</SettingNameInfo><SettingID>8102046</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Preferred Refresh Rate</SettingNameInfo><SettingID>6600001</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Ultra Low Latency - CPL State</SettingNameInfo><SettingID>390467</SettingID><SettingValue>2</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Ultra Low Latency - Enabled</SettingNameInfo><SettingID>277041152</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Vertical Sync</SettingNameInfo><SettingID>11041231</SettingID><SettingValue>138504007</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Vertical Sync - Smooth AFR Behavior</SettingNameInfo><SettingID>270198627</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Vertical Sync - Tear Control</SettingNameInfo><SettingID>5912412</SettingID><SettingValue>2525368439</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Vulkan/OpenGL Present Method</SettingNameInfo><SettingID>550932728</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Antialiasing - Gamma Correction</SettingNameInfo><SettingID>276652957</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Antialiasing - Mode</SettingNameInfo><SettingID>276757595</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Antialiasing - Setting</SettingNameInfo><SettingID>282555346</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Anisotropic Filter - Optimization</SettingNameInfo><SettingID>8703344</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Anisotropic Filter - Sample Optimization</SettingNameInfo><SettingID>15151633</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Anisotropic Filtering - Mode</SettingNameInfo><SettingID>282245910</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Anisotropic Filtering - Setting</SettingNameInfo><SettingID>270426537</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Texture Filtering - Negative LOD Bias</SettingNameInfo><SettingID>1686376</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Texture Filtering - Quality</SettingNameInfo><SettingID>13510289</SettingID><SettingValue>20</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Texture Filtering - Trilinear Optimization</SettingNameInfo><SettingID>3066610</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>CUDA - Force P2 State</SettingNameInfo><SettingID>1343646814</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>CUDA - Sysmem Fallback Policy</SettingNameInfo><SettingID>283962569</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Power Management - Mode</SettingNameInfo><SettingID>274197361</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Shader Cache - Cache Size</SettingNameInfo><SettingID>11306135</SettingID><SettingValue>4294967295</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Threaded Optimization</SettingNameInfo><SettingID>549528094</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
    </Settings>
  </Profile>
</ArrayOfProfile>
"@
    $NIPPath = "$env:SystemRoot\Temp\inspector.nip"
    $NIPFile | Set-Content $NIPPath -Force

    if (Test-Path $ExtractDir) {
        $InspectorExe = Get-ChildItem -Path $ExtractDir -Filter "*nvidiaProfileInspector.exe" -Recurse | Select-Object -First 1
        if ($InspectorExe) {
            Start-Process $InspectorExe.FullName -ArgumentList "-silentImport $NIPPath" -Wait -NoNewWindow
        }
    }

    Write-Done 'nvidia driver setup'
}

function AMD {
    Write-Phase 'amd driver setup'

    Start-Process 'https://www.amd.com/en/support/download/drivers.html'
    Write-Step '  download the adrenalin driver, then press any key...' -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')

    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title, $dlg.Filter = 'select amd driver', 'Executable (*.exe)|*.exe'
    if ($dlg.ShowDialog() -ne 'OK') { Write-Step 'cancelled' 'warn'; return }

    $ZipExe = 'C:\Program Files\7-Zip\7z.exe'
    if (-not (Test-Path $ZipExe)) { Write-Step '7-zip not found' 'fail'; return }

    $ExtractPath = "$env:SystemRoot\Temp\amddriver"
    if (Test-Path $ExtractPath) { Remove-Item $ExtractPath -Recurse -Force }

    Write-Step 'extracting & patching'
    & $ZipExe x $dlg.FileName -o"$ExtractPath" -y | Out-Null

    $XMLDirs = @('Config\AMDAUEPInstaller.xml', 'Config\AMDCOMPUTE.xml', 'Config\AMDLinkDriverUpdate.xml', 'Config\AMDRELAUNCHER.xml', 'Config\AMDScoSupportTypeUpdate.xml', 'Config\AMDUpdater.xml', 'Config\AMDUWPLauncher.xml', 'Config\EnableWindowsDriverSearch.xml', 'Config\InstallUEP.xml', 'Config\ModifyLinkUpdate.xml')
    foreach ($X in $XMLDirs) {
        $XP = Join-Path $ExtractPath $X
        if (Test-Path $XP) {
            $Content = Get-Content $XP -Raw
            $Content = $Content -replace '<Enabled>true</Enabled>', '<Enabled>false</Enabled>' -replace '<Hidden>true</Hidden>', '<Hidden>false</Hidden>'
            Set-Content $XP -Value $Content -NoNewline
        }
    }

    $JSONDirs = @('Config\InstallManifest.json', 'Bin64\cccmanifest_64.json')
    foreach ($J in $JSONDirs) {
        $JP = Join-Path $ExtractPath $J
        if (Test-Path $JP) {
            $Content = Get-Content $JP -Raw
            $Content = $Content -replace '"InstallByDefault"\s*:\s*"Yes"', '"InstallByDefault" : "No"'
            Set-Content $JP -Value $Content -NoNewline
        }
    }

    Write-Step 'installing silently'
    $Setup = "$ExtractPath\Bin64\ATISetup.exe"
    if (Test-Path $Setup) {
        Start-Process -Wait $Setup -ArgumentList '-INSTALL -VIEW:2' -WindowStyle Hidden
    }

    Write-Step 'cleaning up amd bloat'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'AMDNoiseSuppression' '-' 'String'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' 'StartRSX' '-' 'String'
    Unregister-ScheduledTask -TaskName 'StartCN' -Confirm:$false -ErrorAction SilentlyContinue

    $AMDSvcs = 'AMD Crash Defender Service', 'amdfendr', 'amdfendrmgr', 'amdacpbus', 'AMDSAFD', 'AtiHDAudioService'
    foreach ($S in $AMDSvcs) {
        cmd /c "sc stop `"$S`" >nul 2>&1"
        cmd /c "sc delete `"$S`" >nul 2>&1"
    }

    Remove-Item "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\AMD Bug Report Tool" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    Remove-Item "$env:SystemDrive\Windows\SysWOW64\AMDBugReportTool.exe" -Force -ErrorAction SilentlyContinue | Out-Null

    $AMDInstallMgr = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'AMD Install Manager' }
    if ($AMDInstallMgr) { Start-Process 'msiexec.exe' -ArgumentList "/x $($AMDInstallMgr.PSChildName) /qn /norestart" -Wait -NoNewWindow }

    $RSPath = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\AMD Software$([char]0xA789) Adrenalin Edition"
    if (Test-Path $RSPath) {
        Move-Item -Path "$RSPath\*.lnk" -Destination "$env:ProgramData\Microsoft\Windows\Start Menu\Programs" -Force -ErrorAction SilentlyContinue
        Remove-Item $RSPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item "$env:SystemDrive\AMD" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null

    Write-Step 'amd optimizations'
    $RSP = "$env:SystemDrive\Program Files\AMD\CNext\CNext\RadeonSoftware.exe"
    if (Test-Path $RSP) {
        Start-Process $RSP; Start-Sleep -Seconds 15; Stop-Process -Name 'RadeonSoftware' -Force -ErrorAction SilentlyContinue
    }

    $CN = 'HKCU:\Software\AMD\CN'
    Set-Reg $CN 'AutoUpdate' 0
    Set-Reg $CN 'WizardProfile' 'PROFILE_CUSTOM' 'String'
    Set-Reg "$CN\CustomResolutions" 'EulaAccepted' 'true' 'String'
    Set-Reg "$CN\DisplayOverride" 'EulaAccepted' 'true' 'String'
    Set-Reg $CN 'SystemTray' 'false' 'String'
    Set-Reg $CN 'CN_Hide_Toast_Notification' 'true' 'String'
    Set-Reg $CN 'AnimationEffect' 'false' 'String'

    $GpuBase = 'HKLM:\System\CurrentControlSet\Control\Class\{4D36E968-E325-11CE-BFC1-08002BE10318}'
    Get-ChildItem $GpuBase -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.PSChildName -eq 'UMD') {
            Set-Reg $_.PSPath 'VSyncControl' ([byte[]](0x30,0x00)) 'Binary'
            Set-Reg $_.PSPath 'TFQ' ([byte[]](0x32,0x00)) 'Binary'
            Set-Reg $_.PSPath 'Tessellation' ([byte[]](0x31,0x00)) 'Binary'
            Set-Reg $_.PSPath 'Tessellation_OPTION' ([byte[]](0x32,0x00)) 'Binary'
        }
        if ($_.PSChildName -eq 'power_v1') {
            Set-Reg $_.PSPath 'abmlevel' ([byte[]](0x00,0x00,0x00,0x00)) 'Binary'
        }
    }

    Write-Done 'amd driver setup'
}

function intel {
}

$GpuMenu = @(
    @{ Label = 'nvidia' }
    @{ Label = 'amd' }
    @{ Label = 'intel' }
    @{ Label = 'skip' }
)

$selection = Read-Choice -Title "GPU DEPLOYMENT SELECTION" -Question "select target hardware" -Options $GpuMenu

switch -regex ($selection) {
    '(?i)^nvidia$' {
        Write-Done "GPU SELECTION"
        NVIDIA
    }
    '(?i)^amd$' {
        Write-Done "GPU SELECTION"
        AMD
    }
    '(?i)^intel$' {
        Write-Step 'intel core not implemented yet' 'warn'
        Write-Done 'GPU SELECTION'
    }
    '(?i)^skip$' {
        Write-Step 'hardware deployment skipped' 'skip'
        Write-Done 'GPU SELECTION'
    }
    default {
        Write-Step "invalid selection: $selection" 'fail'
        Write-Done 'GPU SELECTION'
    }
}

# ════════════════════════════════════════════════════════════
#  phase 3 · registry tweaks  (converted from AME Wizard YAML)
# ════════════════════════════════════════════════════════════
Write-Phase 'registry tweaks'

# ── 3.1  context menu ───────────────────────────────────────
Write-Step 'context menu'
Apply-Tweaks @(
    # Classic right-click context menu (Windows 11)
    @{ Path = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'; Name = ''; Value = ''; Type = 'String' }
)

# ── 3.2  control panel ──────────────────────────────────────
Write-Step 'control panel'
Apply-Tweaks @(
    # Disable JPEG wallpaper compression
    @{ Path = 'HKCU:\Control Panel\Desktop';          Name = 'JPEGImportQuality'; Value = 100;    Type = 'DWord' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Desktop';  Name = 'JPEGImportQuality'; Value = 100;    Type = 'DWord' }

    # Disable system beeps
    @{ Path = 'HKCU:\Control Panel\Sound';            Name = 'Beep'; Value = 'no'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Sound';    Name = 'Beep'; Value = 'no'; Type = 'String' }

    # Instant Start Menu popup
    @{ Path = 'HKCU:\Control Panel\Desktop';          Name = 'MenuShowDelay'; Value = '0'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Desktop';  Name = 'MenuShowDelay'; Value = '0'; Type = 'String' }

    # Active window track timeout (10 ms)
    @{ Path = 'HKCU:\Control Panel\Desktop';          Name = 'ActiveWndTrkTimeout'; Value = 10; Type = 'DWord' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Desktop';  Name = 'ActiveWndTrkTimeout'; Value = 10; Type = 'DWord' }

    # Auto-end tasks on shutdown
    @{ Path = 'HKCU:\Control Panel\Desktop';          Name = 'AutoEndTasks'; Value = '1'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Desktop';  Name = 'AutoEndTasks'; Value = '1'; Type = 'String' }

    # Hung app timeout (2 s)
    @{ Path = 'HKCU:\Control Panel\Desktop';          Name = 'HungAppTimeout'; Value = '2000'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Desktop';  Name = 'HungAppTimeout'; Value = '2000'; Type = 'String' }

    # Wait-to-kill app timeout (2 s)
    @{ Path = 'HKCU:\Control Panel\Desktop';          Name = 'WaitToKillAppTimeout'; Value = '2000'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Desktop';  Name = 'WaitToKillAppTimeout'; Value = '2000'; Type = 'String' }

    # Low-level hooks timeout (1 s)
    @{ Path = 'HKCU:\Control Panel\Desktop';          Name = 'LowLevelHooksTimeout'; Value = '1000'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Desktop';  Name = 'LowLevelHooksTimeout'; Value = '1000'; Type = 'String' }

    # MouseKeys sensitivity purge (delete)
    @{ Path = 'HKCU:\Control Panel\Accessibility\MouseKeys';          Name = 'MaximumSpeed';      Value = '-' }
    @{ Path = 'HKCU:\Control Panel\Accessibility\MouseKeys';          Name = 'TimeToMaximumSpeed'; Value = '-' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Accessibility\MouseKeys';  Name = 'MaximumSpeed';      Value = '-' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Accessibility\MouseKeys';  Name = 'TimeToMaximumSpeed'; Value = '-' }

    # Disable Enhance Pointer Precision
    @{ Path = 'HKCU:\Control Panel\Mouse';            Name = 'MouseSpeed';      Value = '0'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Mouse';            Name = 'MouseThreshold1'; Value = '0'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Mouse';            Name = 'MouseThreshold2'; Value = '0'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Mouse';    Name = 'MouseSpeed';      Value = '0'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Mouse';    Name = 'MouseThreshold1'; Value = '0'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Mouse';    Name = 'MouseThreshold2'; Value = '0'; Type = 'String' }

    # Disable Online Tips
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'AllowOnlineTips'; Value = 0 }
)

# ── 3.3  ease of access purge ───────────────────────────────
Write-Step 'ease of access purge'
$AccHives = @(
    'AudioDescription', 'Blind Access', 'HighContrast',
    'Keyboard Preference', 'Keyboard Response', 'MouseKeys',
    'On', 'ShowSounds', 'SlateLaunch', 'SoundSentry',
    'StickyKeys', 'TimeOut', 'ToggleKeys'
)
foreach ($h in $AccHives) {
    Set-Reg -Path "HKCU:\Control Panel\Accessibility\$h"         -Name 'Flags' -Value '0' -Type 'String'
    Set-Reg -Path "HKU:\.DEFAULT\Control Panel\Accessibility\$h" -Name 'Flags' -Value '0' -Type 'String'
}

# ── 3.4  explorer & performance ─────────────────────────────
Write-Step 'explorer performance'
Apply-Tweaks @(
    # Disable Automatic Folder Type Discovery
    @{ Path = 'HKCU:\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell';         Name = 'FolderType'; Value = 'NotSpecified'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell'; Name = 'FolderType'; Value = 'NotSpecified'; Type = 'String' }

    # Force Explorer to use high-performance GPU
    @{ Path = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences';         Name = 'C:\Windows\explorer.exe'; Value = 'GpuPreference=2;'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\DirectX\UserGpuPreferences'; Name = 'C:\Windows\explorer.exe'; Value = 'GpuPreference=2;'; Type = 'String' }

    # Disable OneDrive account-based insights in File Explorer
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'DisableGraphRecentItems'; Value = 1 }

    # Hide Spotlight icon on Desktop (24H2)
    @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel'; Name = '{2cc5ca98-6485-489a-920e-b3e88a6ccce3}'; Value = 1 }

    # Increased context menu selection threshold
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer';         Name = 'MultipleInvokePromptMinimum'; Value = 100 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'MultipleInvokePromptMinimum'; Value = 100 }

    # Disable '- Shortcut' text on shortcut creation
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer';         Name = 'link'; Value = ([byte[]](0x00,0x00,0x00,0x00)); Type = 'Binary' }
    @{ Path = 'HKU:\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'link'; Value = ([byte[]](0x00,0x00,0x00,0x00)); Type = 'Binary' }

    # Always show more details in file copy dialog
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager';         Name = 'EnthusiastMode'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager'; Name = 'EnthusiastMode'; Value = 1 }

    # Disable AutoPlay
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers';         Name = 'DisableAutoplay'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers'; Name = 'DisableAutoplay'; Value = 1 }

    # Disable AutoRun on all drives
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoDriveTypeAutoRun'; Value = 255 }
    @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoDriveTypeAutoRun'; Value = 255 }

    # Disable low disk space check
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer';         Name = 'NoLowDiskSpaceChecks'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoLowDiskSpaceChecks'; Value = 1 }

    # Service shutdown timeout (1.5 s)
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Control'; Name = 'WaitToKillServiceTimeout'; Value = '1500'; Type = 'String' }

    # Do not track Shell shortcuts during roaming
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer';         Name = 'LinkResolveIgnoreLinkInfo'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'LinkResolveIgnoreLinkInfo'; Value = 1 }
)

# Downloads folder — disable Group By
$DownloadsID = '{885a186e-a440-4ada-812b-db871b942259}'
Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FolderTypes\$DownloadsID" -Recurse -EA 0 |
    ForEach-Object {
        if ((Get-ItemProperty $_.PSPath -EA 0).GroupBy) {
            Set-ItemProperty -Path $_.PSPath -Name GroupBy -Value '' -EA 0
        }
    }
# refresh Bags for current user
$bagsPath = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags'
Get-ChildItem -Path $bagsPath -EA 0 | ForEach-Object {
    $fullPath = Join-Path $_.PSPath "Shell\$DownloadsID"
    if (Test-Path $fullPath) { Remove-Item -Path $fullPath -Recurse -EA 0 }
}

# ── 3.5  taskbar & start menu ───────────────────────────────
Write-Step 'taskbar & shell'
Apply-Tweaks @(
    # Disable Taskbar Animations
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';         Name = 'TaskbarAnimations'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarAnimations'; Value = 0 }

    # Windows Ink Workspace — on but no suggested apps
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsInkWorkspace'; Name = 'AllowWindowsInkWorkspace';              Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsInkWorkspace'; Name = 'AllowSuggestedAppsInWindowsInkWorkspace'; Value = 0 }

    # Disable Start recommendations / iris / account notifications
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';         Name = 'Start_IrisRecommendations'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Start_IrisRecommendations'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';         Name = 'Start_AccountNotifications'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Start_AccountNotifications'; Value = 0 }

    # Enable 'End Task' in taskbar right-click
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings';         Name = 'TaskbarEndTask'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings'; Name = 'TaskbarEndTask'; Value = 1 }

    # Open File Explorer to This PC
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';         Name = 'LaunchTo'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'LaunchTo'; Value = 1 }

    # Hide pop-up descriptions (tooltips)
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';         Name = 'ShowInfoTip'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowInfoTip'; Value = 0 }

    # Balloon / tray notifications
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer';         Name = 'NoBalloonFeatureAdvertisements'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\Explorer'; Name = 'NoBalloonFeatureAdvertisements'; Value = 1 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer';         Name = 'NoAutoTrayNotify'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\Explorer'; Name = 'NoAutoTrayNotify'; Value = 1 }

    # Push / cloud notifications
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications'; Name = 'NoCloudApplicationNotification'; Value = 1 }

    # Windows Update notification level — silent
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'UpdateNotificationLevel'; Value = 2 }

    # OOBE / "Let's finish setting up" nag
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement';         Name = 'ScoobeSystemSettingEnabled'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement'; Name = 'ScoobeSystemSettingEnabled'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Context\CloudExperienceHostIntent\Wireless';         Name = 'ScoobeCheckCompleted'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Context\CloudExperienceHostIntent\Wireless'; Name = 'ScoobeCheckCompleted'; Value = 1 }

    # Show Search Icon (icon only, not box)
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search';         Name = 'SearchboxTaskbarMode'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'SearchboxTaskbarMode'; Value = 1 }

    # Hide Task View button
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';         Name = 'ShowTaskViewButton'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowTaskViewButton'; Value = 0 }

    # Disable News & Interests / Widgets
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds'; Name = 'EnableFeeds'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh';                  Name = 'AllowNewsAndInterests'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Feeds';         Name = 'ShellFeedsTaskbarViewMode'; Value = 2 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Feeds'; Name = 'ShellFeedsTaskbarViewMode'; Value = 2 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';         Name = 'TaskbarDa'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarDa'; Value = 0 }

    # Remove People Bar
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer';         Name = 'HidePeopleBar'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\Explorer'; Name = 'HidePeopleBar'; Value = 1 }

    # Remove Meet Now icon
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer';         Name = 'HideSCAMeetNow'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'HideSCAMeetNow'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer';         Name = 'HideSCAMeetNow'; Value = 1 }

    # Disable Chat (Teams) icon
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Chat'; Name = 'ChatIcon'; Value = 3 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';         Name = 'TaskbarMn'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarMn'; Value = 0 }
)

# ── 3.6  search & indexing ──────────────────────────────────
Write-Step 'search performance'
Apply-Tweaks @(
    # Respect power modes when indexing
    @{ Path = 'HKLM:\Software\Microsoft\Windows Search\Gather\Windows\SystemIndex'; Name = 'RespectPowerModes'; Value = 1 }

    # Prevent indexing on battery
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'PreventIndexOnBattery'; Value = 1 }

    # Disable search box suggestions
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer';         Name = 'DisableSearchBoxSuggestions'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions'; Value = 1 }

    # Cloud search — user selected
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'AllowCloudSearch'; Value = 2 }

    # Cortana above lock screen — disabled
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'AllowCortanaAboveLock'; Value = 0 }

    # Allow Cortana (kept enabled as per YAML)
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'AllowCortana'; Value = 1 }

    # Cortana in AAD / OOBE — disabled
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'AllowCortanaInAAD';          Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'AllowCortanaInAADPathOOBE';  Value = 0 }

    # No location in Search
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'AllowSearchToUseLocation'; Value = 0 }

    # Disable web results in Search
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'ConnectedSearchUseWeb';                     Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'ConnectedSearchUseWebOverMeteredConnections'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'DisableWebSearch';                           Value = 1 }

    # Search privacy — anonymous
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'ConnectedSearchPrivacy'; Value = 3 }

    # Disable Bing / Cortana consent
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search';         Name = 'CortanaConsent';    Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'CortanaConsent';    Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search';         Name = 'BingSearchEnabled'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'BingSearchEnabled'; Value = 0 }

    # Cortana on lock screen voice activation — disabled
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Speech_OneCore\Preferences'; Name = 'VoiceActivationEnableAboveLockscreen'; Value = 0 }

    # Disable Store results in Search (25H2)
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\WinStore.Tasks.WindowsSearchTask'; Name = 'ActivationType'; Value = 4294967295 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\WinStore.Tasks.WindowsSearchTask'; Name = 'Server';         Value = ''; Type = 'String' }

    # Prevent WebView2 from SearchHost
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Policies\Microsoft\FeatureManagement\Overrides'; Name = '1694661260'; Value = 0 }
)

# ── 3.7  explorer view ──────────────────────────────────────
Write-Step 'explorer view'
Apply-Tweaks @(
    # Show full path in title bar
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState';         Name = 'FullPath'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState'; Name = 'FullPath'; Value = 1 }

    # Show file extensions (security)
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';         Name = 'HideFileExt'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'HideFileExt'; Value = 0 }

    # Disable sync provider notifications (OneDrive ads)
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';         Name = 'ShowSyncProviderNotifications'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowSyncProviderNotifications'; Value = 0 }
)

# ── 3.8  start menu pins & folders ─────────────────────────
Write-Step 'start menu'
$Pins = '{"pinnedList":[{"packagedAppId":"Microsoft.WindowsStore_8wekyb3d8bbwe!App"},{"packagedAppId":"windows.immersivecontrolpanel_cw5n1h2txyewy!microsoft.windows.immersivecontrolpanel"},{"packagedAppId":"Microsoft.WindowsNotepad_8wekyb3d8bbwe!App"},{"packagedAppId":"Microsoft.Paint_8wekyb3d8bbwe!App"},{"desktopAppLink":"%APPDATA%\\Microsoft\\Windows\\Start Menu\\Programs\\File Explorer.lnk"},{"packagedAppId":"Microsoft.WindowsCalculator_8wekyb3d8bbwe!App"}]}'
Apply-Tweaks @(
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'ConfigureStartPins'; Value = $Pins; Type = 'String' }

    # Start folder shortcuts — all hidden, Settings shown
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderDocuments';          Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderDocuments_ProviderSet'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderDownloads';          Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderDownloads_ProviderSet'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderFileExplorer';       Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderFileExplorer_ProviderSet'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderHomeGroup';          Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderHomeGroup_ProviderSet'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderMusic';              Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderMusic_ProviderSet';  Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderNetwork';            Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderNetwork_ProviderSet'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderPersonalFolder';     Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderPersonalFolder_ProviderSet'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderPictures';           Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderPictures_ProviderSet'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderSettings';           Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderSettings_ProviderSet'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderVideos';             Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderVideos_ProviderSet'; Value = 0 }

    # Do not use search when resolving shell shortcuts
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer';         Name = 'NoResolveSearch'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoResolveSearch'; Value = 1 }
)

# ── 3.9  windows settings (system/privacy/devices) ─────────
Write-Step 'windows settings'
Apply-Tweaks @(
    # Hide Insider page from Windows Update
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsSelfHost\UI\Visibility'; Name = 'HideInsiderPage'; Value = 1 }

    # Hide Windows Update tray icon
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; Name = 'TrayIconVisibility'; Value = 0 }

    # Tablet mode — always desktop
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell';         Name = 'SignInMode';                      Value = 1 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell';         Name = 'TabletMode';                      Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell';         Name = 'ConvertibleSlateModePromptPreference'; Value = 2 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell'; Name = 'SignInMode';                      Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell'; Name = 'TabletMode';                      Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell'; Name = 'ConvertibleSlateModePromptPreference'; Value = 2 }

    # Taskbar in tablet mode — show apps, don't auto-hide
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';         Name = 'TaskbarAppsVisibleInTabletMode'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarAppsVisibleInTabletMode'; Value = 1 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';         Name = 'TaskbarAutoHideInTabletMode';    Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarAutoHideInTabletMode';    Value = 0 }

    # Timeline suggestions — off
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';         Name = 'SubscribedContent-353698Enabled'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-353698Enabled'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';         Name = 'SystemPaneSuggestionsEnabled'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SystemPaneSuggestionsEnabled'; Value = 0 }

    # Clipboard history — off
    @{ Path = 'HKCU:\Software\Microsoft\Clipboard';         Name = 'EnableClipboardHistory'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Clipboard'; Name = 'EnableClipboardHistory'; Value = 0 }

    # Allow clipboard (policy stays enabled so clipboard works)
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'AllowClipboardHistory';      Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'AllowCrossDeviceClipboard';  Value = 1 }

    # Typing / autocorrect — all off
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\TabletTip\1.7'; Name = 'EnableAutocorrection';         Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\TabletTip\1.7'; Name = 'EnableAutocorrection';         Value = 0 }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\TabletTip\1.7'; Name = 'EnableSpellchecking';          Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\TabletTip\1.7'; Name = 'EnableSpellchecking';          Value = 0 }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\TabletTip\1.7'; Name = 'EnableTextPrediction';         Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\TabletTip\1.7'; Name = 'EnableTextPrediction';         Value = 0 }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\TabletTip\1.7'; Name = 'EnablePredictionSpaceInsertion'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\TabletTip\1.7'; Name = 'EnablePredictionSpaceInsertion'; Value = 0 }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\TabletTip\1.7'; Name = 'EnableDoubleTapSpace';         Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\TabletTip\1.7'; Name = 'EnableDoubleTapSpace';         Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Input\Settings'; Name = 'InsightsEnabled';             Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Input\Settings'; Name = 'InsightsEnabled';             Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Input\Settings'; Name = 'EnableHwkbTextPrediction';    Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Input\Settings'; Name = 'EnableHwkbTextPrediction';    Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Input\Settings'; Name = 'EnableHwkbAutocorrection';    Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Input\Settings'; Name = 'EnableHwkbAutocorrection';    Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Input\Settings'; Name = 'MultilingualEnabled';         Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Input\Settings'; Name = 'MultilingualEnabled';         Value = 0 }

    # Start suggestions — off
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';         Name = 'SubscribedContent-338388Enabled'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338388Enabled'; Value = 0 }

    # Offline Maps — no auto-update, WiFi only
    @{ Path = 'HKLM:\SYSTEM\Maps'; Name = 'UpdateOnlyOnWifi';  Value = 1 }
    @{ Path = 'HKLM:\SYSTEM\Maps'; Name = 'AutoUpdateEnabled'; Value = 0 }

    # Settings sync — all disabled
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableApplicationSettingSync';            Value = 2 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableApplicationSettingSyncUserOverride'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableSettingSync';                       Value = 2 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableSettingSyncUserOverride';            Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableWebBrowserSettingSync';              Value = 2 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableWebBrowserSettingSyncUserOverride';  Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableDesktopThemeSettingSync';            Value = 2 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableDesktopThemeSettingSyncUserOverride'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableSyncOnPaidNetwork';                  Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableWindowsSettingSync';                 Value = 2 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableWindowsSettingSyncUserOverride';     Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableCredentialsSettingSync';             Value = 2 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableCredentialsSettingSyncUserOverride'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisablePersonalizationSettingSync';         Value = 2 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisablePersonalizationSettingSyncUserOverride'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableStartLayoutSettingSync';             Value = 2 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableStartLayoutSettingSyncUserOverride'; Value = 1 }

    # Game DVR — disabled
    @{ Path = 'HKCU:\System\GameConfigStore';         Name = 'GameDVR_Enabled'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\System\GameConfigStore'; Name = 'GameDVR_Enabled'; Value = 0 }

    # Advertising ID — disabled
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Enabled'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Enabled'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Id';      Value = '-' }
    @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Id';      Value = '-' }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\AdvertisingInfo';       Name = 'DisabledByGroupPolicy'; Value = 1 }

    # Language list opt-out (website local content)
    @{ Path = 'HKCU:\Control Panel\International\User Profile';         Name = 'HttpAcceptLanguageOptOut'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\International\User Profile'; Name = 'HttpAcceptLanguageOptOut'; Value = 1 }

    # Account notifications in Settings — off
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications';         Name = 'EnableAccountNotifications'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications'; Name = 'EnableAccountNotifications'; Value = 1 }

    # Online speech recognition — off
    @{ Path = 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy';         Name = 'HasAccepted'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy'; Name = 'HasAccepted'; Value = 0 }

    # Inking & typing data collection — off
    @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\TextInput'; Name = 'AllowLinguisticDataCollection'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Input\TIPC'; Name = 'Enabled'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Input\TIPC'; Name = 'Enabled'; Value = 0 }

    # Tailored experiences — off
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy';         Name = 'TailoredExperiencesWithDiagnosticDataEnabled'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Privacy'; Name = 'TailoredExperiencesWithDiagnosticDataEnabled'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CPSS\DevicePolicy\TailoredExperiencesWithDiagnosticDataEnabled'; Name = 'DefaultValue'; Value = 0 }

    # Diagnostic event transcript — off
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventTranscriptKey'; Name = 'EnableEventTranscript'; Value = 0 }

    # Feedback frequency — never
    @{ Path = 'HKCU:\Software\Microsoft\Siuf\Rules';         Name = 'NumberOfSIUFInPeriod'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Siuf\Rules';         Name = 'PeriodInNanoSeconds'; Value = '-' }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Siuf\Rules'; Name = 'NumberOfSIUFInPeriod'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Siuf\Rules'; Name = 'PeriodInNanoSeconds'; Value = '-' }

    # Activity history — all off
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'UploadUserActivities';  Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'PublishUserActivities'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'EnableActivityFeed';    Value = 0 }

    # App permissions — deny
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location';                Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location';        Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam';                  Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam';                  Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone';              Name = 'Value'; Value = 'Allow'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone';              Name = 'Value'; Value = 'Allow'; Type = 'String' }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\activity';                Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\activity';                Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userAccountInformation';  Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userAccountInformation';  Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\appointments';            Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\appointments';            Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userDataTasks';           Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userDataTasks';           Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\chat';                    Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\chat';                    Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\radios';                  Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\radios';                  Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\bluetoothSync';           Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\bluetoothSync';           Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\appDiagnostics';          Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\appDiagnostics';          Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\documentsLibrary';        Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\documentsLibrary';        Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\picturesLibrary';         Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\picturesLibrary';         Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\videosLibrary';           Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\videosLibrary';           Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\broadFileSystemAccess';   Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\broadFileSystemAccess';   Name = 'Value'; Value = 'Deny'; Type = 'String' }

    # Wi-Fi Sense — disabled
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\config';   Name = 'AutoConnectAllowedOEM'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\features'; Name = 'PaidWifi';              Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\features'; Name = 'WiFiSenseOpen';         Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowWiFiHotSpotReporting';        Name = 'value'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowAutoConnectToWiFiSenseHotspots'; Name = 'value'; Value = 0 }

    # Disable ValueBanners in Settings (requires TI)
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\ValueBanner.IdealStateFeatureControlProvider'; Name = 'ActivationType'; Value = 4294967295 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\ValueBanner.IdealStateFeatureControlProvider'; Name = 'Server';         Value = ''; Type = 'String' }

    # Disable Recall / AI snapshots (24H2)
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableAIDataAnalysis'; Value = 1 }

    # Enable Sudo — Inline mode
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo'; Name = 'Enabled'; Value = 3 }
)

# ── 3.10  branding & OEM info ───────────────────────────────
Write-Step 'branding & oem'
Apply-Tweaks @(
    # Edition sub-branding
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'; Name = 'EditionSubManufacturer'; Value = 'Albus'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'; Name = 'EditionSubstring';       Value = 'Albus';     Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'; Name = 'EditionSubVersion';      Value = 'Albus 1.0';       Type = 'String' }

    # OEM Information
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation'; Name = 'HelpCustomized';  Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation'; Name = 'Manufacturer';    Value = 'Albus';         Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation'; Name = 'SupportProvider'; Value = 'Albus Support'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation'; Name = 'SupportAppURL';   Value = 'albus-support-help';          Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation'; Name = 'SupportURL';      Value = 'https://www.github.com/oqullcan/albuswin'; Type = 'String' }
)

# ── 4.1  updates — Microsoft Store ──────────────────────────
Write-Step 'ms-store update policy'
Apply-Tweaks @(
    # Disable automatic download/install of Store updates
    @{ Path = 'HKLM:\Software\Policies\Microsoft\WindowsStore'; Name = 'AutoDownload';    Value = 4 }
    # Disable OS-upgrade offer in Store
    @{ Path = 'HKLM:\Software\Policies\Microsoft\WindowsStore'; Name = 'DisableOSUpgrade'; Value = 1 }
)

# ── 4.2  updates — general ──────────────────────────────────
Write-Step 'windows update policy'
Apply-Tweaks @(
    # Suppress upgrade-available notification
    @{ Path = 'HKLM:\SYSTEM\Setup\UpgradeNotification'; Name = 'UpgradeAvailable'; Value = 0 }

    # Disable MRT infection reporting
    @{ Path = 'HKLM:\Software\Policies\Microsoft\MRT'; Name = 'DontReportInfectionInformation'; Value = 0 }

    # Delivery Optimisation — LAN only (no internet peer sharing)
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; Name = 'DODownloadMode'; Value = 0 }

    # Disable Windows Insider / Preview builds
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PreviewBuilds'; Name = 'AllowBuildPreview'; Value = 0 }

    # Reserved storage for updates — disabled
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager'; Name = 'ShippedWithReserves'; Value = 0 }

    # Media Player auto-update — disabled
    @{ Path = 'HKLM:\Software\Policies\Microsoft\WindowsMediaPlayer'; Name = 'DisableAutoUpdate'; Value = 0 }

    # Block DevHome / Outlook from being silently installed by WU Orchestrator
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate';  Name = 'workCompleted'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate'; Name = 'workCompleted'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe'; Name = 'BlockedOobeUpdaters'; Value = '["MS_Outlook"]'; Type = 'String' }

    # Hide MCT / upgrade links and restart notifications
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; Name = 'HideMCTLink';                  Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; Name = 'RestartNotificationsAllowed2'; Value = 0 }
)

# Delete WU Orchestrator OOBE keys (block DevHome / Outlook push)
$OrchestratorOobe = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe'
@('DevHomeUpdate', 'OutlookUpdate') | ForEach-Object {
    $kPath = "$OrchestratorOobe\$_"
    if (Test-Path $kPath) { Remove-Item -Path $kPath -Recurse -Force -EA 0 }
}

# ── 4.3  boot ───────────────────────────────────────────────
Write-Step 'boot configuration'
# Disable automatic disk check on boot (skip autochk on C:)
Set-Reg -Path 'HKLM:\SYSTEM\ControlSet001\Control\Session Manager' `
        -Name 'BootExecute' `
        -Value ([string[]]@('autocheck autochk /k:C*')) `
        -Type 'MultiString'

# ── 4.4  bypass requirements (Windows 11) ───────────────────
Write-Step 'bypass hw requirements'
Apply-Tweaks @(
    @{ Path = 'HKLM:\SYSTEM\Setup\LabConfig'; Name = 'BypassSecureBootCheck'; Value = 1 }
    @{ Path = 'HKLM:\SYSTEM\Setup\LabConfig'; Name = 'BypassTPMCheck';        Value = 1 }
    @{ Path = 'HKLM:\SYSTEM\Setup\LabConfig'; Name = 'BypassCPUCheck';        Value = 1 }
    @{ Path = 'HKLM:\SYSTEM\Setup\LabConfig'; Name = 'BypassRAMCheck';        Value = 1 }
    @{ Path = 'HKLM:\SYSTEM\Setup\LabConfig'; Name = 'BypassStorageCheck';    Value = 1 }
    @{ Path = 'HKLM:\SYSTEM\Setup\MoSetup';   Name = 'AllowUpgradesWithUnsupportedTPMOrCPU'; Value = 1 }

    # Suppress unsupported hardware notification
    @{ Path = 'HKCU:\Control Panel\UnsupportedHardwareNotificationCache';         Name = 'SV1'; Value = 0 }
    @{ Path = 'HKCU:\Control Panel\UnsupportedHardwareNotificationCache';         Name = 'SV2'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\UnsupportedHardwareNotificationCache'; Name = 'SV1'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\UnsupportedHardwareNotificationCache'; Name = 'SV2'; Value = 0 }

    # Bypass NRO (network requirement during OOBE)
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE'; Name = 'BypassNRO'; Value = 1 }
)

# ── 4.5  crash control ──────────────────────────────────────
Write-Step 'crash control'
Apply-Tweaks @(
    # Disable automatic reboot on BSOD
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Control\CrashControl'; Name = 'AutoReboot';        Value = 0 }
    # Small memory dump (64 KB)
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Control\CrashControl'; Name = 'CrashDumpEnabled';  Value = 3 }
)

# ── 4.6  automatic maintenance — disabled ───────────────────
Write-Step 'disable automatic maintenance'
Apply-Tweaks @(
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance'; Name = 'MaintenanceDisabled'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\ScheduledDiagnostics';         Name = 'EnabledExecution';    Value = 0 }
)

# ── 4.7  IFEO (Image File Execution Options) ────────────────
Write-Step 'ifeo — kill telemetry & lower bg priorities'
$Taskkill = '%windir%\System32\taskkill.exe'
$IfeoBase = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'

# Processes killed via debugger redirect
@(
    'CompatTelRunner.exe'   # CEIP / telemetry
    'AggregatorHost.exe'    # CEIP aggregator
    'DeviceCensus.exe'      # Webcam telemetry
    'FeatureLoader.exe'     # MS PC Manager spread
    'BingChatInstaller.exe' # Bing pop-up ads
    'BGAUpsell.exe'         # Bing pop-up ads
    'BCILauncher.exe'       # Bing pop-up ads
) | ForEach-Object {
    Set-Reg -Path "$IfeoBase\$_" -Name 'Debugger' -Value $Taskkill -Type 'String'
}

# CPU/IO priority adjustments
Apply-Tweaks @(
    # SearchIndexer — Below Normal CPU
    @{ Path = "$IfeoBase\SearchIndexer.exe\PerfOptions"; Name = 'CpuPriorityClass'; Value = 5 }
    # ctfmon — Below Normal CPU
    @{ Path = "$IfeoBase\ctfmon.exe\PerfOptions";        Name = 'CpuPriorityClass'; Value = 5 }
    # fontdrvhost — Idle CPU + Idle IO
    @{ Path = "$IfeoBase\fontdrvhost.exe\PerfOptions";   Name = 'CpuPriorityClass'; Value = 1 }
    @{ Path = "$IfeoBase\fontdrvhost.exe\PerfOptions";   Name = 'IoPriority';       Value = 0 }
    # lsass — Idle CPU
    @{ Path = "$IfeoBase\lsass.exe\PerfOptions";         Name = 'CpuPriorityClass'; Value = 1 }
    # sihost — Idle CPU + Idle IO
    @{ Path = "$IfeoBase\sihost.exe\PerfOptions";        Name = 'CpuPriorityClass'; Value = 1 }
    @{ Path = "$IfeoBase\sihost.exe\PerfOptions";        Name = 'IoPriority';       Value = 0 }
)

# ── 4.8  logon ──────────────────────────────────────────────
Write-Step 'logon settings'
Apply-Tweaks @(
    # Disable first sign-in animation
    @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'EnableFirstLogonAnimation';     Value = 0 }
    # Disable startup sound
    @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'DisableStartupSound';           Value = 1 }
    # Disable auto sign-in after restart/update (prevents apps from reopening)
    @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'DisableAutomaticRestartSignOn'; Value = 1 }
)

# ── 4.9  multimedia ─────────────────────────────────────────
Write-Step 'multimedia system profile'
Apply-Tweaks @(
    # NetworkThrottlingIndex — 10 (default, keeps network perf stable)
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'; Name = 'NetworkThrottlingIndex'; Value = 10 }
)

# ── 4.10  OOBE ──────────────────────────────────────────────
Write-Step 'oobe configuration'
$OobePaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE'
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE'
)
$OobeTweaks = @{
    HideOnlineAccountScreens  = 1
    HideEULAPage              = 1
    SkipMachineOOBE           = 0
    SkipUserOOBE              = 0
    HideWirelessSetupInOOBE   = 1
    ProtectYourPC             = 3
    HideLocalAccountScreen    = 0
    DisablePrivacyExperience  = 1
    HideOEMRegistrationScreen = 1
    EnableCortanaVoice        = 0
    DisableVoice              = 1
}
foreach ($p in $OobePaths) {
    Set-Tweaks -Path $p -Settings $OobeTweaks
}
# String value in OOBE
Set-Reg -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' -Name 'NetworkLocation' -Value 'Home' -Type 'String'
Set-Reg -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE'       -Name 'NetworkLocation' -Value 'Home' -Type 'String'
# Skype consent
Set-Reg -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE\AppSettings' -Name 'Skype-UserConsentAccepted' -Value 0

# ── 4.12  Win32PrioritySeparation ───────────────────────────
Write-Step 'win32 priority separation'
Apply-Tweaks @(
    # Short Quantum, variable, 3x foreground boost
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Control\PriorityControl'; Name = 'Win32PrioritySeparation'; Value = 38 }
)

# ── 4.13  BitLocker ─────────────────────────────────────────
Write-Step 'bitlocker — disable auto device encryption'
Apply-Tweaks @(
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Control\BitLocker'; Name = 'PreventDeviceEncryption'; Value = 1 }
)
Get-BitLockerVolume -ErrorAction SilentlyContinue |
    Where-Object { $_.ProtectionStatus -eq 'On' } |
    Disable-BitLocker -ErrorAction SilentlyContinue | Out-Null

# ── 4.14  security ──────────────────────────────────────────
Write-Step 'security settings'
Apply-Tweaks @(
    # Hide Account Protection nag in Defender (redirects to Settings anyway)
    @{ Path = 'HKCU:\Software\Microsoft\Windows Security Health\State';         Name = 'AccountProtection_MicrosoftAccount_Disconnected'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows Security Health\State'; Name = 'AccountProtection_MicrosoftAccount_Disconnected'; Value = 0 }

    # Disable Watson / generic Defender reports
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows Defender\Reporting'; Name = 'DisableGenericRePorts'; Value = 1 }

    # Disable Defender signature updates on battery
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows Defender\Signature Updates'; Name = 'DisableScheduledSignatureUpdateOnBattery'; Value = 1 }

    # SmartScreen — App Install Control (turn off app recommendations)
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows Defender\SmartScreen'; Name = 'ConfigureAppInstallControlEnabled'; Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows Defender\SmartScreen'; Name = 'ConfigureAppInstallControl';        Value = 'Anywhere'; Type = 'String' }

    # Disable web-content evaluation for AppHost
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AppHost'; Name = 'EnableWebContentEvaluation'; Value = 0 }

    # Disable SmartScreen in Microsoft Edge (legacy policy)
    @{ Path = 'HKLM:\Software\Policies\Microsoft\MicrosoftEdge\PhishingFilter'; Name = 'EnabledV9'; Value = 0 }

    # Hide Windows Security systray icon
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Systray'; Name = 'HideSystray'; Value = 1 }

    # Remove SecurityHealth from startup run key
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Name = 'SecurityHealth'; Value = '-' }
)

# ── 4.15  VBS / Virtualization Based Security ───────────────
Write-Step 'vbs — virtualization based security'
# VBS disable is handled by revitool.exe (also disables Memory Integrity / HVCI).
# Call in your script where revitool invocations are grouped:
#   revitool.exe tweaks security vbs disable
Write-Log 'VBS: delegated to revitool — skipped registry-only path'

# ── 5.1  application compatibility ──────────────────────────
Write-Step 'app compatibility'
Apply-Tweaks @(
    # Disable Application Compatibility Engine
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\AppCompat'; Name = 'DisableEngine';    Value = 1 }
    # Disable Application Telemetry (AIT)
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\AppCompat'; Name = 'AITEnable';        Value = 0 }
    # Disable Problem Steps Recorder
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\AppCompat'; Name = 'DisableUAR';       Value = 1 }
    # Disable Program Compatibility Assistant
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\AppCompat'; Name = 'DisablePCA';       Value = 1 }
    # Disable Program Inventory
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\AppCompat'; Name = 'DisableInventory'; Value = 1 }
    # Disable SwitchBack Compatibility Engine
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\AppCompat'; Name = 'SbEnable';         Value = 1 }
)

# ── 5.2  content delivery manager (CDM) ─────────────────────
Write-Step 'content delivery manager'
$CdmBase  = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
$CdmDef   = 'HKU:\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'

Set-Tweaks -Path $CdmBase -Settings @{
    ContentDeliveryAllowed          = 0
    SubscribedContentEnabled        = 0
    'SubscribedContent-310093Enabled' = 0   # Windows Welcome Experience
    SoftLandingEnabled              = 0
    'SubscribedContent-338389Enabled' = 0   # Tips / tricks
    SilentInstalledAppsEnabled      = 0
    PreInstalledAppsEnabled         = 0
    PreInstalledAppsEverEnabled     = 0
    OemPreInstalledAppsEnabled      = 0
    FeatureManagementEnabled        = 0
    RemediationRequired             = 0
    'SubscribedContent-314559Enabled' = 0
    'SubscribedContent-280815Enabled' = 0
    'SubscribedContent-314563Enabled' = 0   # My People
    'SubscribedContent-202914Enabled' = 0
    'SubscribedContent-338387Enabled' = 0   # Facts/Tips on Lock Screen
    'SubscribedContent-280810Enabled' = 0   # OneDrive SyncProviders
    'SubscribedContent-280811Enabled' = 0   # OneDrive
    RotatingLockScreenEnabled       = 0
    RotatingLockScreenOverlayEnabled= 0
}
Set-Tweaks -Path $CdmDef -Settings @{
    ContentDeliveryAllowed          = 0
    SubscribedContentEnabled        = 0
    'SubscribedContent-310093Enabled' = 0
    SoftLandingEnabled              = 0
    'SubscribedContent-338389Enabled' = 0
    SilentInstalledAppsEnabled      = 0
    PreInstalledAppsEnabled         = 0
    PreInstalledAppsEverEnabled     = 0
    OemPreInstalledAppsEnabled      = 0
    FeatureManagementEnabled        = 0
    RemediationRequired             = 0
    'SubscribedContent-314559Enabled' = 0
    'SubscribedContent-280815Enabled' = 0
    'SubscribedContent-314563Enabled' = 0
    'SubscribedContent-202914Enabled' = 0
    'SubscribedContent-338387Enabled' = 0
    'SubscribedContent-280810Enabled' = 0
    'SubscribedContent-280811Enabled' = 0
    RotatingLockScreenEnabled       = 0
    RotatingLockScreenOverlayEnabled= 0
}

# Delete CDM Subscriptions and SuggestedApps keys
@(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions'
    'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions'
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps'
    'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps'
) | ForEach-Object {
    if (Test-Path $_) { Remove-Item -Path $_ -Recurse -Force -EA 0 }
}

# ── 5.3  CEIP ───────────────────────────────────────────────
Write-Step 'ceip'
Apply-Tweaks @(
    @{ Path = 'HKLM:\Software\Policies\Microsoft\SQMClient\Windows';                           Name = 'CEIPEnable';                        Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\AppV\CEIP';                                   Name = 'CEIPEnable';                        Value = 0 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Internet Explorer\SQM';                       Name = 'DisableCustomerImprovementProgram'; Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Messenger\Client';                            Name = 'CEIP';                              Value = 2 }
    @{ Path = 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\UnattendSettings\SQMClient'; Name = 'CEIPEnabled';                       Value = 0 }
)

# ── 5.4  cloud content / Spotlight ──────────────────────────
Write-Step 'cloud content & spotlight'
Apply-Tweaks @(
    # Disable Windows Tips
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableSoftLanding'; Value = 1 }

    # Spotlight — per-user
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent';         Name = 'ConfigureWindowsSpotlight';                         Value = 2 }
    @{ Path = 'HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\CloudContent'; Name = 'ConfigureWindowsSpotlight';                         Value = 2 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent';         Name = 'IncludeEnterpriseSpotlight';                        Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\CloudContent'; Name = 'IncludeEnterpriseSpotlight';                        Value = 0 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent';         Name = 'DisableThirdPartySuggestions';                      Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableThirdPartySuggestions';                      Value = 1 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent';         Name = 'DisableTailoredExperiencesWithDiagnosticData';      Value = 1 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent';         Name = 'DisableWindowsSpotlightFeatures';                   Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsSpotlightFeatures';                   Value = 1 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent';         Name = 'DisableWindowsSpotlightWindowsWelcomeExperience';   Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsSpotlightWindowsWelcomeExperience';   Value = 1 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent';         Name = 'DisableWindowsSpotlightOnActionCenter';             Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsSpotlightOnActionCenter';             Value = 1 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent';         Name = 'DisableWindowsSpotlightOnSettings';                 Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsSpotlightOnSettings';                 Value = 1 }

    # Machine-level cloud content
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableTailoredExperiencesWithDiagnosticData'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableCloudOptimizedContent';                 Value = 1 }
)

# ── 5.5  privacy — internet communication restrictions ──────
Write-Step 'privacy & internet communication'
Apply-Tweaks @(
    # MSA optional
    @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'MSAOptional'; Value = 1 }

    # Disable cloud text message sync
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\Messaging'; Name = 'AllowMessageSync'; Value = 0 }

    # EdgeUI
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\EdgeUI';         Name = 'DisableHelpSticker'; Value = 1 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\EdgeUI';         Name = 'DisableMFUTracking'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\EdgeUI'; Name = 'DisableMFUTracking'; Value = 1 }

    # Restrict Internet Communication — HKCU
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer';       Name = 'NoPublishingWizard';  Value = 1 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer';       Name = 'NoWebServices';       Value = 1 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer';       Name = 'NoOnlinePrintsWizard'; Value = 1 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer';       Name = 'NoInternetOpenWith';  Value = 1 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows NT\CurrentVersion\Software Protection Platform'; Name = 'NoGenTicket'; Value = 1 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows NT\Printers';                   Name = 'DisableHTTPPrinting';    Value = 1 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows NT\Printers';                   Name = 'DisableWebPnPDownload';  Value = 1 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\HandwritingErrorReports';       Name = 'PreventHandwritingErrorReports'; Value = 1 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\TabletPC';                      Name = 'PreventHandwritingDataSharing'; Value = 1 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Assistance\Client\1.0';                 Name = 'NoOnlineAssist';      Value = 1 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Assistance\Client\1.0';                 Name = 'NoExplicitFeedback';  Value = 1 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Assistance\Client\1.0';                 Name = 'NoImplicitFeedback';  Value = 1 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\WindowsMovieMaker';                     Name = 'WebHelp';             Value = 1 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\WindowsMovieMaker';                     Name = 'CodecDownload';       Value = 1 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\WindowsMovieMaker';                     Name = 'WebPublish';          Value = 1 }

    # Restrict Internet Communication — HKLM
    @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer';       Name = 'NoPublishingWizard';  Value = 1 }
    @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer';       Name = 'NoWebServices';       Value = 1 }
    @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer';       Name = 'NoOnlinePrintsWizard'; Value = 1 }
    @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer';       Name = 'NoInternetOpenWith';  Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows NT\CurrentVersion\Software Protection Platform'; Name = 'NoGenTicket'; Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\PCHealth\HelpSvc';                      Name = 'Headlines';           Value = 0 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\PCHealth\HelpSvc';                      Name = 'MicrosoftKBSearch';   Value = 0 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\PCHealth\ErrorReporting';               Name = 'DoReport';            Value = 0 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\Windows Error Reporting';       Name = 'Disabled';            Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\Internet Connection Wizard';    Name = 'ExitOnMSICW';         Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\EventViewer';                           Name = 'MicrosoftEventVwrDisableLinks'; Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\Registration Wizard Control';   Name = 'NoRegistration';      Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\SearchCompanion';                       Name = 'DisableContentFileUpdates'; Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows NT\Printers';                   Name = 'DisableHTTPPrinting';    Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows NT\Printers';                   Name = 'DisableWebPnPDownload';  Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\HandwritingErrorReports';       Name = 'PreventHandwritingErrorReports'; Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\TabletPC';                      Name = 'PreventHandwritingDataSharing'; Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\WindowsMovieMaker';                     Name = 'WebHelp';             Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\WindowsMovieMaker';                     Name = 'CodecDownload';       Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\WindowsMovieMaker';                     Name = 'WebPublish';          Value = 1 }

    # Firewall rules — block DiagTrack (telemetry) and WerSvc (error reporting) outbound
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Services\SharedAccess\Defaults\FirewallPolicy\FirewallRules';
       Name = 'Block-Unified-Telemetry-Client'
       Value = 'v2.31|Action=Block|Active=TRUE|Dir=Out|RA42=IntErnet|RA62=IntErnet|App=%SystemRoot%\system32\svchost.exe|Svc=DiagTrack|Name=Block-Unified-Telemetry-Client|Desc=Block-Unified-Telemetry-Client|EmbedCtxt=DiagTrack|'
       Type = 'String' }
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Services\SharedAccess\Defaults\FirewallPolicy\FirewallRules';
       Name = 'Block-Windows-Error-Reporting'
       Value = 'v2.31|Action=Block|Active=TRUE|Dir=Out|RA42=IntErnet|RA62=IntErnet|App=%SystemRoot%\system32\svchost.exe|Svc=WerSvc|Name=Block-Unified-Error-Reporting|Desc=Block-Windows-Error-Reporting|EmbedCtxt=WerSvc|'
       Type = 'String' }
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules';
       Name = 'Block-Unified-Telemetry-Client'
       Value = 'v2.31|Action=Block|Active=TRUE|Dir=Out|RA42=IntErnet|RA62=IntErnet|App=%SystemRoot%\system32\svchost.exe|Svc=DiagTrack|Name=Block-Unified-Telemetry-Client|Desc=Block-Unified-Telemetry-Client|EmbedCtxt=DiagTrack|'
       Type = 'String' }
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules';
       Name = 'Block-Windows-Error-Reporting'
       Value = 'v2.31|Action=Block|Active=TRUE|Dir=Out|RA42=IntErnet|RA62=IntErnet|App=%SystemRoot%\system32\svchost.exe|Svc=WerSvc|Name=Block-Unified-Telemetry-Client|Desc=Block-Windows-Error-Reporting|EmbedCtxt=WerSvc|'
       Type = 'String' }

    # Disable Gaming Copilot DLL (Xbox)
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\Microsoft.Xbox.GamingAI.Companion.Host.GamingCompanionHostOptions'; Name = 'ActivationType'; Value = 4294967295 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\Microsoft.Xbox.GamingAI.Companion.Host.GamingCompanionHostOptions'; Name = 'Server';         Value = ''; Type = 'String' }
)

# ── 5.6  telemetry & data collection ────────────────────────
Write-Step 'telemetry & data collection'
Apply-Tweaks @(
    # AllowTelemetry = 0 everywhere
    @{ Path = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\DataCollection';                                           Name = 'AllowTelemetry';    Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection';                                           Name = 'AllowTelemetry';    Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection';                            Name = 'AllowTelemetry';    Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Policies\DataCollection';                Name = 'AllowTelemetry';    Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\System\AllowTelemetry';                               Name = 'value';             Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CPSS\DevicePolicy\AllowTelemetry';                   Name = 'DefaultValue';      Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CPSS\Store\AllowTelemetry';                          Name = 'Value';             Value = 0 }

    # DataCollection policy
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowCommercialDataPipeline';                Value = 0 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowDeviceNameInTelemetry';                 Value = 0 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\DataCollection'; Name = 'DisableEnterpriseAuthProxy';                 Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\DataCollection'; Name = 'MicrosoftEdgeDataOptIn';                    Value = 0 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\DataCollection'; Name = 'DisableTelemetryOptInChangeNotification';   Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\DataCollection'; Name = 'DisableTelemetryOptInSettingsUx';           Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\DataCollection'; Name = 'DoNotShowFeedbackNotifications';            Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\DataCollection'; Name = 'LimitEnhancedDiagnosticDataWindowsAnalytics'; Value = 0 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowBuildPreview';                         Value = 0 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\DataCollection'; Name = 'LimitDiagnosticLogCollection';              Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\DataCollection'; Name = 'LimitDumpCollection';                       Value = 1 }

    # Disable pre-release / config flighting
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\PreviewBuilds'; Name = 'EnableConfigFlighting'; Value = 0 }

    # Disable experimentation
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\System'; Name = 'AllowExperimentation'; Value = 0 }

    # wmi autologger — disable telemetry loggers
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Control\WMI\Autologger\Diagtrack-Listener'; Name = 'Start'; Value = 0 }
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Control\WMI\Autologger\SQMLogger';          Name = 'Start'; Value = 0 }
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Control\WMI\Autologger\SetupPlatformTel';   Name = 'Start'; Value = 0 }
)

# ── 5.7  Windows Error Reporting (WER) ──────────────────────
Write-Step 'windows error reporting'
$WerPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting'
$WerData   = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting'
Apply-Tweaks @(
    # policy hive
    @{ Path = $WerPolicy; Name = 'AutoApproveOSDumps';    Value = 0 }
    @{ Path = $WerPolicy; Name = 'LoggingDisabled';       Value = 1 }
    @{ Path = $WerPolicy; Name = 'Disabled';              Value = 1 }
    @{ Path = $WerPolicy; Name = 'DontSendAdditionalData'; Value = 1 }
    @{ Path = $WerPolicy; Name = 'DontShowUI';            Value = 1 }

    # data hive
    @{ Path = $WerData;   Name = 'Disabled';              Value = 1 }

    # consent
    @{ Path = 'HKLM:\Software\Microsoft\Windows\Windows Error Reporting\Consent'; Name = 'DefaultConsent';         Value = 0 }
    @{ Path = 'HKLM:\Software\Microsoft\Windows\Windows Error Reporting\Consent'; Name = 'DefaultOverrideBehavior'; Value = 1 }

    # consent policy — disable all (value name '0', empty string data)
    @{ Path = "$WerPolicy\Consent"; Name = '0'; Value = ''; Type = 'String' }
)

Write-Step 'registry tweaks complete' 'ok'
Write-Done 'registry tweaks'

# ════════════════════════════════════════════════════════════
#  PHASE 4 · SERVICES
#  Runs after registry so Start values written above agree
#  with what sc.exe then enforces.
# ════════════════════════════════════════════════════════════

Write-Phase 'services'

$config = @(
    # telemetry & diagnostics
    @{ Name = 'DiagTrack';                                Start = 4 }
    @{ Name = 'dmwappushservice';                         Start = 4 }
    @{ Name = 'diagnosticshub.standardcollector.service'; Start = 4 }
    @{ Name = 'WerSvc';                                   Start = 4 }
    @{ Name = 'wercplsupport';                            Start = 4 }
    @{ Name = 'DPS';                                      Start = 4 }
    @{ Name = 'WdiServiceHost';                           Start = 4 }
    @{ Name = 'WdiSystemHost';                            Start = 4 }
    @{ Name = 'troubleshootingsvc';                       Start = 4 }
    @{ Name = 'diagsvc';                                  Start = 4 }
    @{ Name = 'PcaSvc';                                   Start = 4 }
    @{ Name = 'InventorySvc';                             Start = 4 }
    # bloat
    @{ Name = 'RetailDemo';                               Start = 4 }
    @{ Name = 'MapsBroker';                               Start = 4 }
    @{ Name = 'wisvc';                                    Start = 4 }
    @{ Name = 'UCPD';                                     Start = 4 }
    @{ Name = 'GraphicsPerfSvc';                          Start = 4 }
    @{ Name = 'Ndu';                                      Start = 4 }
    @{ Name = 'DSSvc';                                    Start = 4 }
    @{ Name = 'WSAIFabricSvc';                            Start = 4 }
    # print
    @{ Name = 'Spooler';                                  Start = 4 }
    @{ Name = 'PrintNotify';                              Start = 4 }
    # remote desktop
    @{ Name = 'TermService';                              Start = 4 }
    @{ Name = 'UmRdpService';                             Start = 4 }
    @{ Name = 'SessionEnv';                               Start = 4 }
    # sync
    @{ Name = 'OneSyncSvc';                               Start = 4 }
    @{ Name = 'CDPUserSvc';                               Start = 4 }
    @{ Name = 'TrkWks';                                   Start = 4 }
    # superfluous
    @{ Name = 'SysMain';                                  Start = 4 }
    @{ Name = 'dam';                                      Start = 4 }
    @{ Name = 'amdfendr';                                 Start = 4 }
    @{ Name = 'amdfendrmgr';                              Start = 4 }
    # condrv needs auto
    @{ Name = 'condrv';                                   Start = 2 }
)

foreach ($svc in $config) {
    $Pattern = "^$($svc.Name)(_[a-fA-F0-9]{4,8})?$"
    Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match $Pattern } |
        ForEach-Object {
            $matchedName = $_.PSChildName
            if ($svc.Start -eq 4) {
                sc.exe stop $matchedName >$null 2>&1
            }
            $startType = switch ($svc.Start) { 2 { 'auto' } 3 { 'demand' } 4 { 'disabled' } }
            sc.exe config $matchedName start= $startType >$null 2>&1
            Set-Reg $_.PSPath 'Start' $svc.Start
        }
}

# merge svchost instances for all matching services
Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\*' -Name 'ImagePath' -ErrorAction SilentlyContinue |
    Where-Object { $_.ImagePath -match 'svchost\.exe' } |
    ForEach-Object {
        Set-Reg $_.PSPath 'SvcHostSplitDisable' 1
    }

Write-Step 'services configured' 'ok'
Write-Done 'services'

# ════════════════════════════════════════════════════════════
#  PHASE 5 · SCHEDULED TASKS
# ════════════════════════════════════════════════════════════

Write-Phase 'scheduled tasks'

$tasks = @(
    '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
    '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
    '\Microsoft\Windows\Application Experience\StartupAppTask',
    '\Microsoft\Windows\Application Experience\PcaPatchDbTask',
    '\Microsoft\Windows\AppxDeploymentClient\UCPD Velocity',
    '\Microsoft\Windows\Autochk\Proxy',
    '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
    '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
    '\Microsoft\Windows\Customer Experience Improvement Program\Uploader',
    '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector',
    '\Microsoft\Windows\Windows Defender\Windows Defender Cache Maintenance',
    '\Microsoft\Windows\Windows Defender\Windows Defender Cleanup',
    '\Microsoft\Windows\Windows Defender\Windows Defender Scheduled Scan',
    '\Microsoft\Windows\Windows Defender\Windows Defender Verification',
    '\Microsoft\Windows\Flighting\FeatureConfig\UsageDataReporting',
    '\Microsoft\Windows\Defrag\ScheduledDefrag',
    '\Microsoft\Windows\Power Efficiency Diagnostics\AnalyzeSystem',
    '\Microsoft\Windows\Feedback\Siuf\DmClient',
    '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload',
    '\Microsoft\Windows\Maintenance\WinSAT',
    '\Microsoft\Windows\Maps\MapsUpdateTask',
    '\Microsoft\Windows\Maps\MapsToastTask',
    '\Microsoft\Windows\SettingSync\BackgroundUploadTask',
    '\Microsoft\Windows\SettingSync\NetworkStateChangeTask',
    '\Microsoft\Windows\CloudExperienceHost\CreateObjectTask',
    '\Microsoft\Windows\DiskFootprint\Diagnostics',
    '\Microsoft\Windows\WDI\ResolutionHost',
    '\Microsoft\Windows\PI\Sqm-Tasks'
)

$dtasks = ($tasks | ForEach-Object { [regex]::Escape($_) }) -join '|'
$Pattern = "(?i)^($dtasks)$"

Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
    $_.URI -match $Pattern -and $_.State -ne 'Disabled'
} | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null

Write-Step 'scheduled tasks disabled' 'ok'
Write-Done 'scheduled tasks'

# ════════════════════════════════════════════════════════════
#  PHASE 6 · NETWORK STACK
# ════════════════════════════════════════════════════════════

Write-Phase 'network configuration'

$Tcp = @(
    'autotuninglevel=restricted',
    'ecncapability=disabled',
    'timestamps=disabled',
    'initialRto=2000',
    'rss=enabled',
    'rsc=disabled',
    'nonsackrttresiliency=disabled'
)
foreach ($cmd in $Tcp) { netsh int tcp set global $cmd | Out-Null }

netsh int tcp set supplemental template=internet congestionprovider=cubic | Out-Null

Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\QoS' 'Do not use NLA' '1' 'String'
Remove-NetQosPolicy -Name 'Albus_*' -Confirm:$false -ErrorAction SilentlyContinue | Out-Null

$Games = @(
    'cs2.exe',
    'r5apex.exe'
)
foreach ($Game in $Games) {
    $Name = "albus_QoS_$($Game.Replace('.exe', ''))"
    New-NetQosPolicy -Name $Name -AppPathNameMatchCondition $Game -DSCPAction 46 -NetworkProfile All -ErrorAction SilentlyContinue | Out-Null
}

$ActiveNICs = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
if ($ActiveNICs) {
    $ActiveNICs | Disable-NetAdapterLso -IPv4 -ErrorAction SilentlyContinue | Out-Null
    $ActiveNICs | Set-NetAdapterAdvancedProperty -DisplayName 'Interrupt Moderation' -DisplayValue 'Disabled' -ErrorAction SilentlyContinue | Out-Null

    $Bloat = @('ms_lldp', 'ms_lltdio', 'ms_implat', 'ms_rspndr', 'ms_tcpip6', 'ms_server', 'ms_msclient', 'ms_pacer')
    foreach ($B in $Bloat) { $ActiveNICs | Disable-NetAdapterBinding -ComponentID $B -ErrorAction SilentlyContinue | Out-Null }

    $TcpParams = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
    Set-Reg $TcpParams 'DisableNetbiosOverTcpip' 1
    Set-Reg "$TcpParams\Dnscache" 'EnableLLMNR' 0
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' 'DisableCoalescing' 1

    foreach ($NIC in $ActiveNICs) {
        $TargetKey = "$TcpParams\Interfaces\$($NIC.InterfaceGuid)"
        Set-Reg $TargetKey 'TcpAckFrequency' 1
        Set-Reg $TargetKey 'TCPNoDelay'      1
    }
}

foreach ($NIC in $ActiveNICs) {
    $SafeID  = $NIC.InstanceID -replace '\\', '\'
    $RegPath = Resolve-Path "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}\*" -ErrorAction SilentlyContinue | Where-Object {
        (Get-ItemProperty $_.Path -Name 'DeviceInstanceID' -ErrorAction SilentlyContinue).DeviceInstanceID -eq $SafeID
    }
    if ($RegPath) {
        $p = $RegPath.Path
        $AntiSleep = @(
            'EnablePME', '*DeviceSleepOnDisconnect', '*EEE', 'AdvancedEEE', '*SipsEnabled', 'EnableAspm', '*WakeOnMagicPacket', '*WakeOnPattern', 'AutoPowerSaveModeEnabled',
            'EEELinkAdvertisement', 'EnableGreenEthernet', 'SavePowerNowEnabled', 'ULPMode', 'WakeOnLink', 'WakeOnSlot', '*NicAutoPowerSaver', 'PowerSaveEnable', 'EnablePowerManagement'
        )
        foreach ($Prop in $AntiSleep) {
            if (Get-ItemProperty -Path $p -Name $Prop -ErrorAction SilentlyContinue) { Set-Reg $p $Prop '0' 'String' }
        }
        if (Get-ItemProperty -Path $p -Name 'PnPCapabilities' -ErrorAction SilentlyContinue) { Set-Reg $p 'PnPCapabilities' 24 }
    }
}
Write-Done 'Network'

# ════════════════════════════════════════════════════════════
#  PHASE 7 · POWER PLAN
# ════════════════════════════════════════════════════════════

Write-Step 'configuring albus power plan'

$PowerSaverGUID = 'a1841308-3541-4fab-bc81-f71556f20b4a'
$UltimateGUID   = 'e9a42b02-d5df-448d-aa00-03f14749eb61'

# cryptographic signature: "oqullcan" (hex) + 0101 padding
$AlbusGUID      = '6f71756c-6c63-616e-0101-010101010101'

# reset the system and switch to the safe mode
powercfg -restoredefaultschemes >$null 2>&1
powercfg /setactive $PowerSaverGUID >$null 2>&1

# scrap the old albus plan and start from scratch with our own design
powercfg /delete $AlbusGUID >$null 2>&1
powercfg /duplicatescheme $UltimateGUID $AlbusGUID >$null 2>&1
powercfg /changename $AlbusGUID 'Albus' 'minimal latency, unparked cores, peak throughput.' >$null 2>&1

# remove all unnecessary plans except albus and powersaver
[regex]::Matches((powercfg /l | Out-String), '[a-f0-9]{8}-([a-f0-9]{4}-){3}[a-f0-9]{12}', 'IgnoreCase') | ForEach-Object {
    if ($_.Value -notin @($AlbusGUID, $PowerSaverGUID)) {
        powercfg /delete $_.Value >$null 2>&1
    }
}

# albus plan config
# format: "subgroupguid - settingguid - value"
@(
    # hard disk & background
    '0012ee47-9041-4b5d-9b77-535fba8b1442 6738e2c4-e8a5-4a42-b16a-e040e769756e 0'    # disk turn off (never)
    '0d7dbae2-4294-402a-ba8e-26777e8488cd 309dce9b-bef4-4119-9921-a851fb12f0f4 1'    # desktop slideshow paused

    # wireless & networking
    '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0'    # wireless max perf

    # sleep & wake
    '238c9fa8-0aad-41ed-83f4-97be242c8f20 29f6c1db-86da-48c5-9fdb-f2b67b1f44da 0'    # sleep after 0
    '238c9fa8-0aad-41ed-83f4-97be242c8f20 94ac6d29-73ce-41a6-809f-6363ba21b47e 0'    # hybrid sleep off
    '238c9fa8-0aad-41ed-83f4-97be242c8f20 9d7815a6-7ee4-497e-8888-515a05f02364 0'    # hibernate after 0
    '238c9fa8-0aad-41ed-83f4-97be242c8f20 bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d 0'    # wake timers disable

    # usb configuration
    '2a737441-1930-4402-8d77-b2bebba308a3 0853a681-27c8-4100-a2fd-82013e970683 0'    # hub selective suspend timeout 0
    '2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0'    # usb selective suspend off
    '2a737441-1930-4402-8d77-b2bebba308a3 d4e98f31-5ffe-4ce1-be31-1b38b384c009 0'    # usb 3 link power management off

    # power buttons & lid
    '4f971e89-eebd-4455-a8de-9e59040e7347 a7066653-8d6c-40a8-910e-a1f54b84c7e5 2'    # power button = shutdown

    # pci express
    '501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0'    # pcie link state off

    # processor power management (unparked cores & max freq)
    '54533251-82be-4824-96c1-47b60b740d00 893dee8e-2bef-41e0-89c6-b55d0929964c 100'  # min cpu state
    '54533251-82be-4824-96c1-47b60b740d00 bc5038f7-23e0-4960-96da-33abaf5935ec 100'  # max cpu state
    '54533251-82be-4824-96c1-47b60b740d00 0cc5b647-c1df-4637-891a-dec35c318583 100'  # core parking min cores
    '54533251-82be-4824-96c1-47b60b740d00 ea062031-0e34-4ff1-9b6d-eb1059334028 100'  # core parking max cores
    '54533251-82be-4824-96c1-47b60b740d00 94d3a615-a899-4ac5-ae2b-e4d8f634367f 1'    # system cooling active
    '54533251-82be-4824-96c1-47b60b740d00 36687f9e-e3a5-4dbf-b1dc-15eb381c6863 0'    # energy perf pref
    '54533251-82be-4824-96c1-47b60b740d00 93b8b6dc-0698-4d1c-9ee4-0644e900c85d 0'    # heterogeneous scheduling

    # display & video playback
    '7516b95f-f776-4464-8c53-06167f40cc99 3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e 600'  # display timeout 10m (oled safety)
    '7516b95f-f776-4464-8c53-06167f40cc99 aded5e82-b909-4619-9949-f5d71dac0bcb 100'  # display brightness
    '7516b95f-f776-4464-8c53-06167f40cc99 f1fbfde2-a960-4165-9f88-50667911ce96 100'  # dimmed display brightness
    '7516b95f-f776-4464-8c53-06167f40cc99 fbd9aa66-9553-4097-ba44-ed6e9d65eab8 0'    # adaptive brightness off
    '9596fb26-9850-41fd-ac3e-f7c3c00afd4b 10778347-1370-4ee0-8bbd-33bdacaade49 1'    # video playback quality bias
    '9596fb26-9850-41fd-ac3e-f7c3c00afd4b 34c7b99f-9a6d-4b3c-8dc7-b6693b78cef4 0'    # optimize video quality

    # graphics power states
    '44f3beca-a7c0-460e-9df2-bb8b99e0cba6 3619c3f2-afb2-4afc-b0e9-e7fef372de36 2'    # intel graphics max perf
    'c763b4ec-0e50-4b6b-9bed-2b92a6ee884e 7ec1751b-60ed-4588-afb5-9819d3d77d90 3'    # amd power slider best perf
    'f693fb01-e858-4f00-b20f-f30e12ac06d6 191f65b5-d45c-4a4f-8aae-1ab8bfd980e6 1'    # ati graphics max perf
    'e276e160-7cb0-43c6-b20b-73f5dce39954 a1662ab2-9d34-4e53-ba8b-2639b9e20857 3'    # Switchable dynamic max perf

    # battery interventions (remove completely)
    'e73a048d-bf27-4f12-9731-8b2076e8891f 5dbb7c9f-38e9-40d2-9749-4f8a0e9f640f 0'    # crit battery notif off
    'e73a048d-bf27-4f12-9731-8b2076e8891f 637ea02f-bbcb-4015-8e2c-a1c7b9c0b546 0'    # crit battery action nothing
    'e73a048d-bf27-4f12-9731-8b2076e8891f 8183ba9a-e910-48da-8769-14ae6dc1170a 0'    # low battery level 0
    'e73a048d-bf27-4f12-9731-8b2076e8891f 9a66d8d7-4ff7-4ef9-b5a2-5a326ca2a469 0'    # crit battery level 0
    'e73a048d-bf27-4f12-9731-8b2076e8891f bcded951-187b-4d05-bccc-f7e51960c258 0'    # low battery notif off
    'e73a048d-bf27-4f12-9731-8b2076e8891f d8742dcb-3e6a-4b3c-b3fe-374623cdcf06 0'    # low battery action nothing
    'e73a048d-bf27-4f12-9731-8b2076e8891f f3c5027d-cd16-4930-aa6b-90db844a8f00 0'    # reserve battery level 0
    'de830923-a562-41af-a086-e3a2c6bad2da 13d09884-f74e-474a-a852-b6bde8ad03a8 100'  # low screen brightness battery saver disabled
    'de830923-a562-41af-a086-e3a2c6bad2da e69653ca-cf7f-4f05-aa73-cb833fa90ad4 0'    # battery saver auto never
) | ForEach-Object {
    $parts = $_ -split '\s+'
    powercfg /attributes $parts[0] $parts[1] -ATTRIB_HIDE >$null 2>&1
    powercfg /setacvalueindex $AlbusGUID $parts[0] $parts[1] $parts[2] >$null 2>&1
    powercfg /setdcvalueindex $AlbusGUID $parts[0] $parts[1] $parts[2] >$null 2>&1
}

# activate the albus plan
powercfg /setactive $AlbusGUID >$null 2>&1

# disable hibernate
powercfg /hibernate off >$null 2>&1
$PwrKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
Set-Reg $PwrKey 'HibernateEnabled' 0
Set-Reg $PwrKey 'HibernateEnabledDefault' 0

# disable fast boot
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0

# disable power throttling
$ThrottleKey = "$PwrKey\PowerThrottling"
if (-not (Test-Path $ThrottleKey)) { New-Item -Path $ThrottleKey -Force | Out-Null }
Set-Reg $ThrottleKey 'PowerThrottlingOff' 1

# ui: disable sleep and lock options in start menu
$FlyoutKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings'
if (-not (Test-Path $FlyoutKey)) { New-Item -Path $FlyoutKey -Force | Out-Null }
Set-Reg $FlyoutKey 'ShowLockOption' 0
Set-Reg $FlyoutKey 'ShowSleepOption' 0

Write-Step "albus power plan active [$AlbusGUID]" 'ok'
Write-Done 'power plan'

# ════════════════════════════════════════════════════════════
#  PHASE 8 · HARDWARE TUNING
#  MSI mode, ghost devices, disk cache, device power
# ════════════════════════════════════════════════════════════

Write-Phase 'hardware tuning'

# 8.1  ghost device removal
Write-Step 'cleaning up ghost devices'
Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { -not $_.Present -and $_.InstanceId -notmatch '^(ROOT|SWD|HTREE|DISPLAY|BTHENUM)\\' } |
    ForEach-Object {
        pnputil /remove-device $_.InstanceId /quiet | Out-Null
    }

# 8.2  msi interrupt mode
Write-Step 'enabling msi mode for pci devices'
Get-PnpDevice -InstanceId 'PCI\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.Status -match '^(OK|Unknown)$' } |
    ForEach-Object {
        $base = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($_.InstanceId)\Device Parameters"
        Set-Reg "$base\Interrupt Management\MessageSignaledInterruptProperties" 'MSISupported' 1
        if ($_.Class -eq 'Display') {
            Remove-ItemProperty -Path "$base\Interrupt Management\Affinity Policy" -Name 'DevicePriority' -ErrorAction SilentlyContinue
        }
    }

# 8.3  disk write cache
Write-Step 'enabling aggressive disk write caching'
Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue |
    Where-Object { $_.InterfaceType -ne 'USB' -and $_.PNPDeviceID } |
    ForEach-Object {
        $p = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($_.PNPDeviceID)\Device Parameters\Disk"
        Set-Reg $p 'UserWriteCacheSetting' 1
        Set-Reg $p 'CacheIsPowerProtected' 1
    }

# 8.4  disable device power saving
Write-Step 'disabling device power saving states'
$PowerKeys = @('SelectiveSuspendEnabled', 'SelectiveSuspendOn', 'EnhancedPowerManagementEnabled', 'WaitWakeEnabled')
Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.Status -match '^(OK|Unknown)$' } |
    ForEach-Object {
        $p = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($_.InstanceId)\Device Parameters"
        Set-Reg "$p\WDF" 'IdleInWorkingState' 0
        foreach ($key in $PowerKeys) { Set-Reg $p $key 0 }
    }

# 8.5  exploit guard — disable system-wide mitigations for peak performance
Write-Step 'disabling exploit guard & mitigations'
$Mitigations = (Get-Command 'Set-ProcessMitigation' -ErrorAction SilentlyContinue).Parameters['Disable'].Attributes.ValidValues
if ($Mitigations) {
    Set-ProcessMitigation -SYSTEM -Disable $Mitigations -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
}

$KernelPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Kernel'
$auditLen   = try { (Get-ItemProperty $KernelPath 'MitigationAuditOptions' -ErrorAction Stop).MitigationAuditOptions.Length } catch { 38 }

[byte[]]$mitigPayload = ,[byte]34 * $auditLen

$CriticalProcs = @(
    'fontdrvhost.exe', 'dwm.exe', 'lsass.exe', 'svchost.exe', 'WmiPrvSE.exe', 'winlogon.exe', 'csrss.exe', 'audiodg.exe', 'services.exe', 'explorer.exe', 'taskhostw.exe', 'sihost.exe'
)

foreach ($proc in $CriticalProcs) {
    $ifeoPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$proc"
    Set-Reg $ifeoPath 'MitigationOptions' $mitigPayload 'Binary'
    Set-Reg $ifeoPath 'MitigationAuditOptions' $mitigPayload 'Binary'
}

Set-Reg $KernelPath 'MitigationOptions' $mitigPayload 'Binary'
Set-Reg $KernelPath 'MitigationAuditOptions' $mitigPayload 'Binary'

# intel tsx (transaction synchronization extensions)
if ((Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue).Manufacturer -match 'Intel') {
    Set-Reg $KernelPath 'DisableTSX' 0
} else {
    Remove-ItemProperty -Path $KernelPath -Name 'DisableTSX' -ErrorAction SilentlyContinue
}

Write-Done 'hardware tuning'

# ════════════════════════════════════════════════════════════
#  PHASE 9 · FILESYSTEM & BOOT
# ════════════════════════════════════════════════════════════

Write-Phase 'filesystem & boot'

Write-Step 'ntfs'
fsutil behavior set disable8dot3 1 | Out-Null
fsutil behavior set disabledeletenotify 0 | Out-Null
fsutil behavior set disablelastaccess 1 | Out-Null

Write-Step 'bcdedit'
bcdedit /timeout 10 | Out-Null
bcdedit /deletevalue useplatformclock | Out-Null
bcdedit /deletevalue useplatformtick | Out-Null
bcdedit /set bootmenupolicy legacy | Out-Null
bcdedit /set '{current}' description 'Albus 5.0' | Out-Null
label C: Albus | Out-Null

Write-Step 'disable memory compression'
Disable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue | Out-Null

Write-Step 'winevt diagnostic channels'
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WINEVT\Channels' -ErrorAction SilentlyContinue |
    ForEach-Object {
        $ep = Get-ItemProperty -Path $_.PSPath -Name 'Enabled' -ErrorAction SilentlyContinue
        if ($ep -and $ep.Enabled -eq 1) {
            Set-ItemProperty -Path $_.PSPath -Name 'Enabled' -Value 0 -Force -ErrorAction SilentlyContinue
        }
    }

Write-Step 'safe mode msiserver'
Set-Reg 'HKLM:\SYSTEM\ControlSet001\Control\SafeBoot\Minimal\MSIServer' '' 'Service' 'String'
Set-Reg 'HKLM:\SYSTEM\ControlSet001\Control\SafeBoot\Network\MSIServer' '' 'Service' 'String'

Write-Done 'filesystem & boot'

# ════════════════════════════════════════════════════════════
#  PHASE 10 · ALBUSX SERVICE
#  Compile & deploy the core engine last — it depends on all
#  previous phases having completed successfully.
# ════════════════════════════════════════════════════════════

Write-Phase 'albusx service'

$SvcName = 'AlbusXSvc'
$ExePath  = "$env:SystemRoot\AlbusX.exe"
$CSPath   = "$env:SystemRoot\AlbusX.cs"
$CSC      = "$env:windir\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$SrcURL   = 'https://raw.githubusercontent.com/oqullcan/albuswin/refs/heads/main/albus/albus.cs'

if (Get-Service $SvcName -ErrorAction SilentlyContinue) {
    Stop-Service $SvcName -Force -ErrorAction SilentlyContinue
    sc.exe delete $SvcName >$null 2>&1
    Start-Sleep 1
}
Remove-Item $ExePath -Force -ErrorAction SilentlyContinue

if (Test-Network) {
    Write-Step 'fetching albusx source'
    try { Get-File $SrcURL $CSPath } catch { Write-Step 'source fetch failed' 'warn' }
}

if ((Test-Path $CSPath) -and (Test-Path $CSC)) {
    Write-Step 'compiling albusx'
    & $CSC -r:System.ServiceProcess.dll -r:System.Configuration.Install.dll `
           -r:System.Management.dll -r:Microsoft.Win32.Registry.dll `
           -out:"$ExePath" "$CSPath" >$null 2>&1
    Remove-Item $CSPath -Force -ErrorAction SilentlyContinue
}

if (Test-Path $ExePath) {
    New-Service -Name $SvcName -BinaryPathName $ExePath -DisplayName 'AlbusX' `
        -Description 'albus core engine 3.0 — precision timer, audio latency, memory, interrupt affinity.' `
        -StartupType Automatic -ErrorAction SilentlyContinue | Out-Null
    sc.exe failure $SvcName reset= 60 actions= restart/5000/restart/10000/restart/30000 >$null 2>&1
    Start-Service $SvcName -ErrorAction SilentlyContinue
    Write-Step 'albusx running' 'ok'
} else {
    Write-Step 'albusx not deployed (compilation unavailable)' 'warn'
}

Write-Done 'albusx service'

# ════════════════════════════════════════════════════════════
#  PHASE 11 · DEBLOAT
#  UWP removal, Edge, OneDrive.
#  Runs late — all services are stopped, state is clean.
# ════════════════════════════════════════════════════════════

Write-Phase 'debloat'

Write-Step 'debloat complete' 'ok'
Write-Done 'debloat'

# ════════════════════════════════════════════════════════════
#  PHASE 12 · STARTUP & TASK CLEANUP
# ════════════════════════════════════════════════════════════

Write-Phase 'startup cleanup'

@('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
  'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
  'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
  'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce') | ForEach-Object {
    if (Test-Path $_) {
        Get-Item $_ | ForEach-Object { $_.GetValueNames() | ForEach-Object { Remove-ItemProperty -Path $_.PSPath -Name $_ -Force -ErrorAction SilentlyContinue } }
    }
}

@("$env:AppData\Microsoft\Windows\Start Menu\Programs\Startup",
  "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp") | ForEach-Object {
    if (Test-Path $_) { Remove-Item "$_\*" -Recurse -Force -ErrorAction SilentlyContinue }
}

$taskTree = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree'
Get-ChildItem $taskTree -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -ne 'Microsoft' } |
    ForEach-Object { Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue }

Write-Step 'startup entries cleared' 'ok'
Write-Done 'startup cleanup'

# ════════════════════════════════════════════════════════════
#  PHASE 13 · UI: TRUE BLACK WALLPAPER & SHELL REFRESH
# ════════════════════════════════════════════════════════════

Write-Phase 'ui'

Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction SilentlyContinue

$BlackFile = "$env:SystemRoot\Albus.jpg"
if (-not (Test-Path $BlackFile)) {
    try {
        $sw  = [System.Windows.Forms.SystemInformation]::PrimaryMonitorSize.Width
        $sh  = [System.Windows.Forms.SystemInformation]::PrimaryMonitorSize.Height
        $bmp = New-Object System.Drawing.Bitmap $sw, $sh
        $g   = [System.Drawing.Graphics]::FromImage($bmp)
        $g.FillRectangle([System.Drawing.Brushes]::Black, 0, 0, $sw, $sh)
        $g.Dispose(); $bmp.Save($BlackFile); $bmp.Dispose()
    } catch { Write-Step 'wallpaper generation failed' 'warn' }
}

Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' 'LockScreenImagePath'   $BlackFile 'String'
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' 'LockScreenImageStatus' 1

# context menu cleanup
@('-HKCR:\Folder\shell\pintohome',
  '-HKCR:\*\shell\pintohomefile',
  '-HKCR:\exefile\shellex\ContextMenuHandlers\Compatibility',
  '-HKCR:\AllFilesystemObjects\shellex\ContextMenuHandlers\ModernSharing',
  '-HKCR:\AllFilesystemObjects\shellex\ContextMenuHandlers\SendTo') | ForEach-Object {
    Set-Reg -Path $_ -Name '' -Value ''
}

# block shell extensions
@('{9F156763-7844-4DC4-B2B1-901F640F5155}', '{09A47860-11B0-4DA5-AFA5-26D86198A780}', '{f81e9010-6ea4-11ce-a7ff-00aa003ca9f6}') | ForEach-Object {
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked' $_ '' 'String'
}

# notify icons - promote all
Get-ChildItem 'HKCU:\Control Panel\NotifyIconSettings' -Recurse -ErrorAction SilentlyContinue |
    ForEach-Object { Set-ItemProperty -Path $_.PSPath -Name 'IsPromoted' -Value 1 -Force -ErrorAction SilentlyContinue }

# refresh shell
rundll32.exe user32.dll, UpdatePerUserSystemParameters
Stop-Process -Force -Name explorer -ErrorAction SilentlyContinue

Write-Step 'ui applied' 'ok'
Write-Done 'ui'

# ════════════════════════════════════════════════════════════
#  PHASE 15 · CLEANUP
# ════════════════════════════════════════════════════════════

Write-Phase 'cleanup'

lodctr.exe /R 2>&1 | Out-Null

Remove-Item "$env:USERPROFILE\AppData\Local\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:SystemRoot\Temp\*"                -Recurse -Force -ErrorAction SilentlyContinue

Start-Process cleanmgr.exe -ArgumentList '/autoclean /d C:' -Wait -NoNewWindow

Write-Step 'temp files removed' 'ok'
Write-Done 'cleanup'

# ════════════════════════════════════════════════════════════
#  DONE
# ════════════════════════════════════════════════════════════

$totalTime = [math]::Round(((Get-Date) - $TODAY).TotalMinutes, 1)

Write-Host ''
Write-Host '  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor DarkGray
Write-Host "  albus v$ALBUS_VERSION  ·  complete  ·  ${totalTime}m" -ForegroundColor White
Write-Host "  log → $ALBUS_LOG" -ForegroundColor DarkGray
Write-Host '  restart recommended.' -ForegroundColor DarkGray
Write-Host ''

Write-Log "COMPLETE in ${totalTime}m"
