# =============================================================================================================================================================================
# albus playbook v2
# https://github.com/oqullcan/albuswin
# =============================================================================================================================================================================

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ── 64-bit enforcement ────────────────────────────────────────────────────────
if ($env:PROCESSOR_ARCHITECTURE -eq 'AMD64' -and -not [Environment]::Is64BitProcess) {
    $sysnative = "$env:windir\sysnative\WindowsPowerShell\v1.0\powershell.exe"
    if (Test-Path $sysnative) { & $sysnative -ExecutionPolicy Bypass -NoProfile -File $PSCommandPath; exit }
}

# ── active user sid resolver ──────────────────────────────────────────────────
# writes HKCU keys to the real user's hive, not SYSTEM/Default when running as TrustedInstaller
$script:ActiveSID = $null
try {
    $exp = Get-WmiObject Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exp) { $script:ActiveSID = $exp.GetOwnerSid().Sid }
} catch { }

$Identity  = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$Privilege = $Identity.Split('\')[-1]
[Console]::Title = "albus playbook v2 — $Privilege"

# ── status engine ─────────────────────────────────────────────────────────────
function status ($msg, $type = "info") {
    $p, $c = switch ($type) {
        "info"  { "info", "Cyan"    }
        "done"  { "done", "Green"   }
        "warn"  { "warn", "Yellow"  }
        "fail"  { "fail", "Red"     }
        "step"  { "step", "Magenta" }
        default { "albus", "Gray"   }
    }
    Write-Host "$p - " -NoNewline -ForegroundColor $c
    Write-Host $msg.ToLower()
}

# ── registry engine ───────────────────────────────────────────────────────────
function Set-Reg {
    param ([string]$Path, [string]$Name, $Value, [string]$Type = "DWord")
    try {
        $del     = $Path.StartsWith("-")
        $actual  = if ($del) { $Path.Substring(1) } else { $Path }

        $hkcu    = if ($script:ActiveSID) { "HKEY_USERS\$script:ActiveSID" }         else { "HKEY_CURRENT_USER" }
        $hkcuPS  = if ($script:ActiveSID) { "Registry::HKEY_USERS\$script:ActiveSID" } else { "HKCU:" }

        $native  = $actual.Replace("HKLM:", "HKEY_LOCAL_MACHINE").Replace("HKCU:", $hkcu).Replace("HKCR:", "HKEY_CLASSES_ROOT").Replace("HKU:", "HKEY_USERS")
        $ps      = $actual.Replace("HKLM:", "Registry::HKEY_LOCAL_MACHINE").Replace("HKCU:", $hkcuPS).Replace("HKCR:", "Registry::HKEY_CLASSES_ROOT").Replace("HKU:", "Registry::HKEY_USERS")

        # delete key
        if ($del) {
            if ($native -like "*HKEY_CLASSES_ROOT*") { cmd /c "reg delete `"$native`" /f 2>nul" }
            elseif (Test-Path $ps) { Remove-Item $ps -Recurse -Force -ErrorAction SilentlyContinue | Out-Null }
            return
        }

        # delete value
        if ($Value -eq "-") {
            if (Test-Path $ps) { Remove-ItemProperty $ps -Name $Name -Force -ErrorAction SilentlyContinue | Out-Null }
            return
        }

        if (-not (Test-Path $ps)) { New-Item $ps -Force -ErrorAction SilentlyContinue | Out-Null }

        if ($Name -eq "") { Set-Item $ps -Value $Value -Force -ErrorAction SilentlyContinue | Out-Null; return }

        try {
            New-ItemProperty $ps -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        } catch {
            $regtype = switch ($Type) {
                "DWord"        { "REG_DWORD"     }
                "QWord"        { "REG_QWORD"     }
                "String"       { "REG_SZ"        }
                "ExpandString" { "REG_EXPAND_SZ" }
                "Binary"       { "REG_BINARY"    }
                "MultiString"  { "REG_MULTI_SZ"  }
                default        { "REG_DWORD"     }
            }
            $val = if ($Type -eq "Binary") { ($Value | ForEach-Object { "{0:X2}" -f $_ }) -join "" } else { $Value }
            cmd /c "reg add `"$native`" /v `"$Name`" /t $regtype /d `"$val`" /f 2>nul"
            if ($LASTEXITCODE -ne 0) {
                $logdir = "C:\Albus"
                if (-not (Test-Path $logdir)) { New-Item -ItemType Directory $logdir -Force | Out-Null }
                Add-Content "$logdir\albus_error.log" "[$(Get-Date -Format 'HH:mm:ss')] fail → $native\$Name" -ErrorAction SilentlyContinue
            }
        }
    } catch { }
}

# ── environment setup ─────────────────────────────────────────────────────────
$dest = "C:\Albus"
if (-not (Test-Path $dest)) { New-Item -ItemType Directory $dest | Out-Null }

# ── registry drives ───────────────────────────────────────────────────────────
if (-not (Get-PSDrive HKCR -ErrorAction SilentlyContinue)) { New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT | Out-Null }
if (-not (Get-PSDrive HKU  -ErrorAction SilentlyContinue)) { New-PSDrive -Name HKU  -PSProvider Registry -Root HKEY_USERS       | Out-Null }

# ─────────────────────────────────────────────────────────────────────────────
# software installation
# ─────────────────────────────────────────────────────────────────────────────

if (Test-Connection -ComputerName "8.8.8.8" -Count 1 -Quiet -ErrorAction SilentlyContinue) {

    status "network available — starting payload retrieval..." "step"

    # brave browser
    try {
        $rel = Invoke-RestMethod "https://api.github.com/repos/brave/brave-browser/releases/latest" -ErrorAction Stop
        status "fetching brave browser ($($rel.tag_name))..." "info"
        Invoke-WebRequest "https://github.com/brave/brave-browser/releases/latest/download/BraveBrowserStandaloneSetup.exe" -OutFile "$dest\BraveSetup.exe" -UseBasicParsing -ErrorAction Stop
        Start-Process -Wait "$dest\BraveSetup.exe" -ArgumentList "/silent /install" -WindowStyle Hidden
        Set-Reg "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave" "HardwareAccelerationModeEnabled" 0
        Set-Reg "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave" "BackgroundModeEnabled"           0
        Set-Reg "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave" "HighEfficiencyModeEnabled"       1
        status "brave browser installed." "done"
    } catch { status "brave browser failed." "fail" }

    # 7-zip
    try {
        $rel = Invoke-RestMethod "https://api.github.com/repos/ip7z/7zip/releases/latest" -ErrorAction Stop
        $url = ($rel.assets | Where-Object { $_.name -match "7z.*-x64\.exe" }).browser_download_url
        if ($url) {
            status "fetching 7-zip ($($rel.name))..." "info"
            Invoke-WebRequest $url -OutFile "$dest\7zip.exe" -UseBasicParsing
            Start-Process -Wait "$dest\7zip.exe" -ArgumentList "/S"
            Set-Reg "HKCU:\Software\7-Zip\Options" "ContextMenu"  259
            Set-Reg "HKCU:\Software\7-Zip\Options" "CascadedMenu" 0
            Move-Item "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\7-Zip\7-Zip File Manager.lnk" "$env:ProgramData\Microsoft\Windows\Start Menu\Programs" -Force -ErrorAction SilentlyContinue | Out-Null
            Remove-Item "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\7-Zip" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
            status "7-zip installed." "done"
        }
    } catch { status "7-zip failed." "fail" }

    # visual c++ runtimes
    try {
        status "fetching visual c++ x64 runtime..." "info"
        Invoke-WebRequest "https://aka.ms/vs/17/release/vc_redist.x64.exe" -OutFile "$dest\vc_redist.x64.exe" -UseBasicParsing
        Start-Process -Wait "$dest\vc_redist.x64.exe" -ArgumentList "/quiet /norestart" -WindowStyle Hidden
        status "visual c++ installed." "done"
    } catch { status "visual c++ failed." "fail" }

    # directx runtime
    try {
        status "fetching directx end-user runtime..." "info"
        Invoke-WebRequest "https://download.microsoft.com/download/1/7/1/1718CCC4-6315-4D8E-9543-8E28A4E18C4C/dxwebsetup.exe" -OutFile "$dest\dxwebsetup.exe" -UseBasicParsing -ErrorAction Stop
        Start-Process -Wait "$dest\dxwebsetup.exe" -ArgumentList "/Q" -WindowStyle Hidden
        status "directx installed." "done"
    } catch { status "directx failed." "fail" }

} else {
    status "no network — skipping software installation." "warn"
}

# ─────────────────────────────────────────────────────────────────────────────
# registry optimization engine
# ─────────────────────────────────────────────────────────────────────────────

status "executing registry optimization engine..." "step"

$today    = Get-Date
$pauseEnd = $today.AddYears(31)
$todayStr = $today.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$pauseStr = $pauseEnd.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$tweaks = @(

    # ── ease of access ────────────────────────────────────────────────────────
    @{ Path = "HKCU:\Software\Microsoft\Narrator\NoRoam"; Name = "DuckAudio";             Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Narrator\NoRoam"; Name = "WinEnterLaunchEnabled"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Narrator\NoRoam"; Name = "ScriptingEnabled";      Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Narrator\NoRoam"; Name = "OnlineServicesEnabled"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Narrator";        Name = "NarratorCursorHighlight";      Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Narrator";        Name = "CoupleNarratorCursorKeyboard"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Narrator";        Name = "IntonationPause";        Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Narrator";        Name = "ReadHints";              Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Narrator";        Name = "ErrorNotificationType";  Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Narrator";        Name = "EchoChars";              Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Narrator";        Name = "EchoWords";              Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Narrator\NarratorHome"; Name = "MinimizeType"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Narrator\NarratorHome"; Name = "AutoStart";    Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Narrator\NoRoam";       Name = "EchoToggleKeys"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Ease of Access";        Name = "selfvoice"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Ease of Access";        Name = "selfscan";  Value = 0 }
    @{ Path = "HKCU:\Control Panel\Accessibility";              Name = "Sound on Activation"; Value = 0 }
    @{ Path = "HKCU:\Control Panel\Accessibility";              Name = "Warning Sounds";       Value = 0 }
    @{ Path = "HKCU:\Control Panel\Accessibility\HighContrast";    Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\Keyboard Response"; Name = "Flags";          Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\Keyboard Response"; Name = "AutoRepeatRate"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\Keyboard Response"; Name = "AutoRepeatDelay"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\MouseKeys";  Name = "Flags";           Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\MouseKeys";  Name = "MaximumSpeed";    Value = "-"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\MouseKeys";  Name = "TimeToMaximumSpeed"; Value = "-"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\StickyKeys"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\ToggleKeys"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\SoundSentry"; Name = "Flags";        Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\SoundSentry"; Name = "FSTextEffect"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\SoundSentry"; Name = "TextEffect";   Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\SoundSentry"; Name = "WindowsEffect"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\SlateLaunch"; Name = "ATapp";    Value = ""; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\SlateLaunch"; Name = "LaunchAT"; Value = 0 }
    @{ Path = "HKCU:\Control Panel\Accessibility\AudioDescription";  Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\Blind Access";      Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\Keyboard Preference"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\On";                Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\ShowSounds";        Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\TimeOut";           Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\ScreenMagnifier"; Name = "FollowCaret";    Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\ScreenMagnifier"; Name = "FollowNarrator"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\ScreenMagnifier"; Name = "FollowMouse";    Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\ScreenMagnifier"; Name = "FollowFocus";    Value = 0 }
    @{ Path = "HKCU:\Control Panel\Keyboard"; Name = "PrintScreenKeyForSnippingEnabled"; Value = 0 }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\AudioDescription";   Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\Blind Access";       Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\HighContrast";       Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\Keyboard Preference"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\Keyboard Response";  Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\MouseKeys";          Name = "Flags";           Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\MouseKeys";          Name = "MaximumSpeed";    Value = "-"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\MouseKeys";          Name = "TimeToMaximumSpeed"; Value = "-"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\On";                 Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\ShowSounds";         Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\SlateLaunch";        Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\SoundSentry";        Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\StickyKeys";         Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\TimeOut";            Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\ToggleKeys";         Name = "Flags"; Value = "0"; Type = "String" }

    # ── clock and region ──────────────────────────────────────────────────────
    @{ Path = "HKCU:\Control Panel\TimeDate"; Name = "DstNotification"; Value = 0 }

    # ── explorer appearance ───────────────────────────────────────────────────
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer"; Name = "ShowFrequent";             Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer"; Name = "ShowCloudFilesInQuickAccess"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "LaunchTo";                  Value = 1 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "HideFileExt";               Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "FolderContentsInfoTip";      Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ShowInfoTip";                Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ShowPreviewHandlers";        Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ShowStatusBar";              Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ShowSyncProviderNotifications"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "SharingWizardOn";            Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarSmallIcons";          Value = 1 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "UseCompactMode";             Value = 1 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "MultipleInvokePromptMinimum"; Value = 100 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "EnthusiastMode"; Value = 1 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState"; Name = "FullPath"; Value = 1 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings";        Name = "IsDeviceSearchHistoryEnabled"; Value = 0 }
    @{ Path = "HKCU:\Software\Classes\CLSID\{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}"; Name = "System.IsPinnedToNameSpaceTree"; Value = 0 }
    @{ Path = "HKCU:\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell"; Name = "FolderType"; Value = "NotSpecified"; Type = "String" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer"; Name = "link"; Value = ([byte[]](0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKU:\.DEFAULT\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell"; Name = "FolderType"; Value = "NotSpecified"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer"; Name = "link"; Value = ([byte[]](0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "LaunchTo";   Value = 1 }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ShowInfoTip"; Value = 0 }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState"; Name = "FullPath"; Value = 1 }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer"; Name = "MultipleInvokePromptMinimum"; Value = 100 }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers"; Name = "DisableAutoplay"; Value = 1 }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager"; Name = "EnthusiastMode"; Value = 1 }

    # ── hardware and sound ────────────────────────────────────────────────────
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings"; Name = "ShowLockOption";  Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings"; Name = "ShowSleepOption"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Multimedia\Audio"; Name = "UserDuckingPreference"; Value = 3 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\BootAnimation"; Name = "DisableStartupSound"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\EditionOverrides"; Name = "UserSetting_DisableStartupSound"; Value = 1 }
    @{ Path = "HKCU:\AppEvents\Schemes"; Name = ""; Value = ".None"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers"; Name = "DisableAutoplay"; Value = 1 }

    # ── mouse and cursors ─────────────────────────────────────────────────────
    @{ Path = "HKCU:\Control Panel\Mouse"; Name = "MouseSpeed";      Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Mouse"; Name = "MouseThreshold1"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Mouse"; Name = "MouseThreshold2"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Mouse"; Name = "MouseSensitivity"; Value = "10"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Mouse"; Name = "RawMouseThrottleEnabled"; Value = 0 }
    @{ Path = "HKCU:\Control Panel\Mouse"; Name = "SmoothMouseXCurve"; Value = ([byte[]](0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xC0,0xCC,0x0C,0x00,0x00,0x00,0x00,0x00,0x80,0x99,0x19,0x00,0x00,0x00,0x00,0x00,0x40,0x66,0x26,0x00,0x00,0x00,0x00,0x00,0x00,0x33,0x33,0x00,0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKCU:\Control Panel\Mouse"; Name = "SmoothMouseYCurve"; Value = ([byte[]](0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x38,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x70,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xA8,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xE0,0x00,0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "ContactVisualization"; Value = 0 }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "GestureVisualization"; Value = 0 }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "Scheme Source";        Value = 0 }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "";                     Value = ""; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "AppStarting"; Value = ""; Type = "ExpandString" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "Arrow";       Value = ""; Type = "ExpandString" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "Crosshair";   Value = ""; Type = "ExpandString" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "Hand";        Value = ""; Type = "ExpandString" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "Help";        Value = ""; Type = "ExpandString" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "IBeam";       Value = ""; Type = "ExpandString" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "No";          Value = ""; Type = "ExpandString" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "NWPen";       Value = ""; Type = "ExpandString" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "SizeAll";     Value = ""; Type = "ExpandString" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "SizeNESW";    Value = ""; Type = "ExpandString" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "SizeNS";      Value = ""; Type = "ExpandString" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "SizeNWSE";    Value = ""; Type = "ExpandString" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "SizeWE";      Value = ""; Type = "ExpandString" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "UpArrow";     Value = ""; Type = "ExpandString" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "Wait";        Value = ""; Type = "ExpandString" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Mouse"; Name = "MouseSpeed";      Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Mouse"; Name = "MouseThreshold1"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Mouse"; Name = "MouseThreshold2"; Value = "0"; Type = "String" }

    # ── hardware and device management ───────────────────────────────────────
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata"; Name = "PreventDeviceMetadataFromNetwork"; Value = 1 }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\Network\SharedAccessConnection"; Name = "EnableControl"; Value = 0 }

    # ── system performance ────────────────────────────────────────────────────
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Dfrg\TaskSettings"; Name = "fAllVolumes";     Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Dfrg\TaskSettings"; Name = "fDeadlineEnabled"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Dfrg\TaskSettings"; Name = "fExclude";        Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Dfrg\TaskSettings"; Name = "fTaskEnabled";    Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Dfrg\TaskSettings"; Name = "fUpgradeRestored"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Dfrg\TaskSettings"; Name = "TaskFrequency";   Value = 4 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Dfrg\TaskSettings"; Name = "Volumes";         Value = " "; Type = "String" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl"; Name = "Win32PrioritySeparation"; Value = 38 }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\PriorityControl";     Name = "Win32PrioritySeparation"; Value = 38 }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance"; Name = "fAllowToGetHelp"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance"; Name = "MaintenanceDisabled"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\ScheduledDiagnostics"; Name = "EnabledExecution"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"; Name = "Disabled"; Value = 1 }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control"; Name = "WaitToKillServiceTimeout"; Value = "1500"; Type = "String" }

    # ── visual effects and dwm ────────────────────────────────────────────────
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects"; Name = "VisualFXSetting"; Value = 3 }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "UserPreferencesMask"; Value = ([byte[]](0x90,0x12,0x03,0x80,0x12,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKCU:\Control Panel\Desktop\WindowMetrics"; Name = "MinAnimate"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarAnimations";   Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "IconsOnly";           Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ListviewAlphaSelect"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ListviewShadow";      Value = 0 }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "DragFullWindows"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "FontSmoothing";   Value = "2"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\DWM"; Name = "EnableAeroPeek";          Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\DWM"; Name = "AlwaysHibernateThumbnails"; Value = 0 }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarAnimations"; Value = 0 }

    # ── delivery optimization ─────────────────────────────────────────────────
    @{ Path = "HKU:\S-1-5-20\Software\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Settings"; Name = "DownloadMode"; Value = 0 }

    # ── privacy and tracking ──────────────────────────────────────────────────
    @{ Path = "HKLM:\SOFTWARE\Microsoft\MdmCommon\SettingValues"; Name = "LocationSyncEnabled"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications"; Name = "EnableAccountNotifications"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CPSS\Store\TailoredExperiencesWithDiagnosticDataEnabled"; Name = "Value"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy"; Name = "TailoredExperiencesWithDiagnosticDataEnabled"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location";               Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CPSS\Store\UserLocationOverridePrivacySetting";               Name = "Value"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location";               Name = "ShowGlobalPrompts"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam";                 Name = "Value"; Value = "Allow"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";             Name = "Value"; Value = "Allow"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Speech_OneCore\Settings\VoiceActivation\UserPreferenceForAllApps";  Name = "AgentActivationEnabled";  Value = 0 }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Speech_OneCore\Settings\VoiceActivation\UserPreferenceForAllApps"; Name = "AgentActivationLastUsed"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userNotificationListener"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userAccountInformation";  Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\contacts";                Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\appointments";            Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\phoneCall";               Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\phoneCallHistory";        Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\email";                   Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userDataTasks";           Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\chat";                    Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\radios";                  Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\bluetoothSync";           Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\appDiagnostics";          Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\documentsLibrary";        Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\downloadsFolder";         Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\musicLibrary";            Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\picturesLibrary";         Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\videosLibrary";           Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\broadFileSystemAccess";   Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\systemAIModels";          Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\passkeys";                Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\passkeysEnumeration";     Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\International\User Profile"; Name = "HttpAcceptLanguageOptOut"; Value = 1 }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\EdgeUI"; Name = "DisableMFUTracking"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI"; Name = "DisableMFUTracking"; Value = 1 }
    @{ Path = "HKCU:\Software\Microsoft\InputPersonalization"; Name = "RestrictImplicitInkCollection";  Value = 1 }
    @{ Path = "HKCU:\Software\Microsoft\InputPersonalization"; Name = "RestrictImplicitTextCollection"; Value = 1 }
    @{ Path = "HKCU:\Software\Microsoft\InputPersonalization\TrainedDataStore"; Name = "HarvestContacts"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Personalization\Settings"; Name = "AcceptedPrivacyPolicy"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "AllowTelemetry"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Siuf\Rules"; Name = "NumberOfSIUFInPeriod"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Siuf\Rules"; Name = "PeriodInNanoSeconds"; Value = "-" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; Name = "PublishUserActivities"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; Name = "EnableActivityFeed";    Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; Name = "UploadUserActivities";  Value = 0 }

    # ── search and cloud ──────────────────────────────────────────────────────
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings"; Name = "IsDynamicSearchBoxEnabled"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings"; Name = "SafeSearchMode";            Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings"; Name = "IsAADCloudSearchEnabled";   Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings"; Name = "IsMSACloudSearchEnabled";   Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "SearchboxTaskbarMode"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "GleamEnabled";         Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "WeatherEnabled";       Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "HolidayEnabled";       Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "CortanaConsent";       Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "BingSearchEnabled";    Value = 0 }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "CortanaConsent";    Value = 0 }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "BingSearchEnabled"; Value = 0 }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\Explorer"; Name = "DisableSearchBoxSuggestions"; Value = 1 }
    @{ Path = "HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\Explorer"; Name = "DisableSearchBoxSuggestions"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "AllowCloudSearch";                    Value = 2 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "AllowCortanaAboveLock";               Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "AllowCortana";                        Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "AllowCortanaInAAD";                   Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "AllowCortanaInAADPathOOBE";            Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "AllowSearchToUseLocation";            Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "ConnectedSearchUseWeb";               Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "ConnectedSearchUseWebOverMeteredConnections"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "DisableWebSearch";                    Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "ConnectedSearchPrivacy";              Value = 3 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "PreventIndexOnBattery";               Value = 1 }
    @{ Path = "HKLM:\Software\Microsoft\Windows Search\Gather\Windows\SystemIndex"; Name = "RespectPowerModes"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Speech_OneCore\Preferences"; Name = "VoiceActivationEnableAboveLockscreen"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\WinStore.Tasks.WindowsSearchTask"; Name = "ActivationType"; Value = 4294967295 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\WinStore.Tasks.WindowsSearchTask"; Name = "Server"; Value = ""; Type = "String" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Policies\Microsoft\FeatureManagement\Overrides"; Name = "1694661260"; Value = 0 }

    # ── gaming and performance ────────────────────────────────────────────────
    @{ Path = "HKCU:\System\GameConfigStore"; Name = "GameDVR_Enabled"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "AppCaptureEnabled";       Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "AudioCaptureEnabled";     Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "HistoricalCaptureEnabled"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "MicrophoneCaptureEnabled"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "CursorCaptureEnabled";    Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "AudioEncodingBitrate";    Value = 128000 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "CustomVideoEncodingBitrate"; Value = 4000000 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "CustomVideoEncodingHeight"; Value = 720 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "CustomVideoEncodingWidth";  Value = 1280 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "HistoricalBufferLength";    Value = 30 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "HistoricalBufferLengthUnit"; Value = 1 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "MaximumRecordLength";      Value = 720000000000; Type = "QWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VideoEncodingBitrateMode"; Value = 2 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VideoEncodingResolutionMode"; Value = 2 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VideoEncodingFrameRateMode"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "EchoCancellationEnabled"; Value = 1 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "SystemAudioGain";  Value = 10000; Type = "QWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "MicrophoneGain";   Value = 10000; Type = "QWord" }
    # disable all gamebar hotkeys
    "VKToggleGameBar","VKMToggleGameBar","VKSaveHistoricalVideo","VKMSaveHistoricalVideo",
    "VKToggleRecording","VKMToggleRecording","VKTakeScreenshot","VKMTakeScreenshot",
    "VKToggleRecordingIndicator","VKMToggleRecordingIndicator","VKToggleMicrophoneCapture",
    "VKMToggleMicrophoneCapture","VKToggleCameraCapture","VKMToggleCameraCapture",
    "VKToggleBroadcast","VKMToggleBroadcast" | ForEach-Object {
        @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = $_; Value = 0 }
    }
    @{ Path = "HKCU:\Software\Microsoft\GameBar"; Name = "UseNexusForGameBarEnabled"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\GameBar"; Name = "GamepadNexusChordEnabled";  Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\GameBar"; Name = "AutoGameModeEnabled";       Value = 1 }

    # ── time, language and input ──────────────────────────────────────────────
    @{ Path = "HKCU:\Software\Microsoft\input\Settings"; Name = "IsVoiceTypingKeyEnabled"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\input\Settings"; Name = "InsightsEnabled";         Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Input\Settings"; Name = "EnableHwkbTextPrediction"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Input\Settings"; Name = "EnableHwkbAutocorrection"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Input\Settings"; Name = "MultilingualEnabled";      Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\TabletTip\1.7";  Name = "EnableAutoShiftEngage";    Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\TabletTip\1.7";  Name = "EnableKeyAudioFeedback";   Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\TabletTip\1.7";  Name = "EnableDoubleTapSpace";     Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\TabletTip\1.7";  Name = "TouchKeyboardTapInvoke";   Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\TabletTip\1.7";  Name = "TipbandDesiredVisibility"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\TabletTip\1.7";  Name = "IsKeyBackgroundEnabled";   Value = 0 }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\TabletTip\1.7";  Name = "EnableAutocorrection";     Value = 0 }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\TabletTip\1.7";  Name = "EnableSpellchecking";      Value = 0 }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\TabletTip\1.7";  Name = "EnableTextPrediction";     Value = 0 }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\TabletTip\1.7";  Name = "EnablePredictionSpaceInsertion"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\CTF\LangBar"; Name = "ExtraIconsOnMinimized"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\CTF\LangBar"; Name = "Label";        Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\CTF\LangBar"; Name = "ShowStatus";   Value = 3 }
    @{ Path = "HKCU:\Software\Microsoft\CTF\LangBar"; Name = "Transparency"; Value = 255 }
    @{ Path = "HKCU:\Keyboard Layout\Toggle"; Name = "Language Hotkey"; Value = "3"; Type = "String" }
    @{ Path = "HKCU:\Keyboard Layout\Toggle"; Name = "Hotkey";          Value = "3"; Type = "String" }
    @{ Path = "HKCU:\Keyboard Layout\Toggle"; Name = "Layout Hotkey";   Value = "3"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\TabletTip\1.7";  Name = "EnableAutocorrection";     Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\TabletTip\1.7";  Name = "EnableSpellchecking";      Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\TabletTip\1.7";  Name = "EnableTextPrediction";     Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\TabletTip\1.7";  Name = "EnablePredictionSpaceInsertion"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\TabletTip\1.7";  Name = "EnableDoubleTapSpace";     Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Input\Settings"; Name = "EnableHwkbTextPrediction"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Input\Settings"; Name = "EnableHwkbAutocorrection"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Input\Settings"; Name = "MultilingualEnabled";      Value = 0 }

    # ── accounts and sync ─────────────────────────────────────────────────────
    @{ Path = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon"; Name = "EnableGoodbye"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; Name = "DisableAutomaticRestartSignOn"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device"; Name = "DevicePasswordLessBuildVersion"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device"; Name = "DevicePasswordLessUpdateType";   Value = 1 }
    "DisableAccessibilitySettingSync","DisableAccessibilitySettingSyncUserOverride",
    "DisableAppSyncSettingSync","DisableAppSyncSettingSyncUserOverride",
    "DisableApplicationSettingSync","DisableApplicationSettingSyncUserOverride",
    "DisableCredentialsSettingSync","DisableCredentialsSettingSyncUserOverride",
    "DisableDesktopThemeSettingSync","DisableDesktopThemeSettingSyncUserOverride",
    "DisableLanguageSettingSync","DisableLanguageSettingSyncUserOverride",
    "DisablePersonalizationSettingSync","DisablePersonalizationSettingSyncUserOverride",
    "DisableSettingSync","DisableSettingSyncUserOverride",
    "DisableStartLayoutSettingSync","DisableStartLayoutSettingSyncUserOverride",
    "DisableSyncOnPaidNetwork",
    "DisableWebBrowserSettingSync","DisableWebBrowserSettingSyncUserOverride",
    "DisableWindowsSettingSync","DisableWindowsSettingSyncUserOverride",
    "EnableWindowsBackup" | ForEach-Object {
        $v = if ($_ -like "*Override" -or $_ -eq "DisableSyncOnPaidNetwork" -or $_ -eq "EnableWindowsBackup") { 1 } else { 2 }
        @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = $_; Value = $v }
    }

    # ── apps and maps ─────────────────────────────────────────────────────────
    @{ Path = "HKLM:\SYSTEM\Maps"; Name = "AutoUpdateEnabled";   Value = 0 }
    @{ Path = "HKLM:\SYSTEM\Maps"; Name = "UpdateOnlyOnWifi";    Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Appx"; Name = "AllowAutomaticAppArchiving"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Maps"; Name = "AllowUntriggeredNetworkTrafficOnSettingsPage"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Maps"; Name = "AutoDownloadAndUpdateMapData";                 Value = 0 }

    # ── personalization and themes ────────────────────────────────────────────
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "Wallpaper"; Value = ""; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers"; Name = "BackgroundType"; Value = 1 }
    @{ Path = "HKCU:\Control Panel\Colors"; Name = "Background"; Value = "0 0 0"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\ClassicStartMenu"; Name = "{645FF040-5081-101B-9F08-00AA002F954E}"; Value = 1 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel";    Name = "{645FF040-5081-101B-9F08-00AA002F954E}"; Value = 1 }

    # ── start menu and taskbar ────────────────────────────────────────────────
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"; Name = "ShowOrHideMostUsedApps"; Value = 2 }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\Explorer"; Name = "ShowOrHideMostUsedApps"; Value = "-" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoStartMenuMFUprogramsList"; Value = "-" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoInstrumentation";          Value = "-" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoStartMenuMFUprogramsList"; Value = "-" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoInstrumentation";          Value = "-" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "HideRecommendedSection"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Education"; Name = "IsEducationEnvironment"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"; Name = "HideRecommendedSection"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"; Name = "HideRecentlyAddedApps"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "HideRecentlyAddedApps"; Value = 1 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "Start_Layout";                Value = 1 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "Start_AccountNotifications"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "Start_RecoPersonalizedSites"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "Start_TrackDocs";            Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "Start_IrisRecommendations";  Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "IconSizePreference";         Value = 1 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarAl";  Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarSd";  Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarMn";  Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarDa";  Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarSn";  Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ShowTaskViewButton"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ShowCopilotButton"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "IsEnabled"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "HideSCAMeetNow"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds"; Name = "EnableFeeds"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer"; Name = "EnableAutoTray"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"; Name = "SecurityHealth"; Value = ([byte[]](0x07,0x00,0x00,0x00,0x05,0xDB,0x8A,0x69,0x8A,0x49,0xD9,0x01)); Type = "Binary" }
    @{ Path = "HKCU:\Software\Microsoft\Lighting"; Name = "AmbientLightingEnabled";   Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Lighting"; Name = "ControlledByForegroundApp"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Lighting"; Name = "UseSystemAccentColor";     Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Start"; Name = "ShowRecentList";            Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Start"; Name = "AllAppsViewMode";           Value = 2 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Start"; Name = "RightCompanionToggledOpen"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Start\Companions\Microsoft.YourPhone_8wekyb3d8bbwe"; Name = "IsEnabled";   Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Start\Companions\Microsoft.YourPhone_8wekyb3d8bbwe"; Name = "IsAvailable"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Dsh"; Name = "AllowNewsAndInterests"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\NewsAndInterests\AllowNewsAndInterests"; Name = "value"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Chat"; Name = "ChatIcon"; Value = 3 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Feeds"; Name = "ShellFeedsTaskbarViewMode"; Value = 2 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer"; Name = "HubMode"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "HideSCAMeetNow"; Value = 1 }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\Explorer"; Name = "NoBalloonFeatureAdvertisements"; Value = 1 }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\Explorer"; Name = "NoAutoTrayNotify";               Value = 1 }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\Explorer"; Name = "HidePeopleBar";                  Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"; Name = "DisableGraphRecentItems";        Value = 1 }
    @{ Path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"; Name = "{2cc5ca98-6485-489a-920e-b3e88a6ccce3}"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{0DB7E03F-FC29-4DC6-9020-FF41B59E513A}"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{0DB7E03F-FC29-4DC6-9020-FF41B59E513A}"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\Software\Classes\CLSID\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}"; Name = "System.IsPinnedToNameSpaceTree"; Value = 0 }
    @{ Path = "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "MenuShowDelay"; Value = "0"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching"; Name = "SearchOrderConfig"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoWebServices";        Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "SettingsPageVisibility"; Value = "hide:home;"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"; Name = "ShowOrHideMostUsedApps"; Value = 2 }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "Start_IrisRecommendations";  Value = 0 }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "Start_AccountNotifications"; Value = 0 }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ShowTaskViewButton"; Value = 0 }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarMn"; Value = 0 }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarDa"; Value = 0 }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings"; Name = "TaskbarEndTask"; Value = 1 }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarAutoHideInTabletMode"; Value = 0 }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarAppsVisibleInTabletMode"; Value = 1 }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Feeds"; Name = "ShellFeedsTaskbarViewMode"; Value = 2 }
    @{ Path = "HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\Explorer"; Name = "NoBalloonFeatureAdvertisements"; Value = 1 }
    @{ Path = "HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\Explorer"; Name = "NoAutoTrayNotify";               Value = 1 }
    @{ Path = "HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\Explorer"; Name = "HidePeopleBar";                  Value = 1 }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "HideSCAMeetNow";       Value = 1 }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoResolveSearch";      Value = 1 }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "LinkResolveIgnoreLinkInfo"; Value = 1 }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoLowDiskSpaceChecks"; Value = 1 }
    @{ Path = "HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\EdgeUI"; Name = "DisableMFUTracking"; Value = 1 }
    @{ Path = "HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\CloudContent"; Name = "ConfigureWindowsSpotlight";               Value = 2 }
    @{ Path = "HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableThirdPartySuggestions";            Value = 1 }
    @{ Path = "HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableWindowsSpotlightFeatures";         Value = 1 }
    @{ Path = "HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableWindowsSpotlightWindowsWelcomeExperience"; Value = 1 }
    @{ Path = "HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableWindowsSpotlightOnActionCenter";   Value = 1 }
    @{ Path = "HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableWindowsSpotlightOnSettings";       Value = 1 }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement"; Name = "ScoobeSystemSettingEnabled"; Value = 0 }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell"; Name = "SignInMode";                   Value = 1 }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell"; Name = "TabletMode";                   Value = 0 }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell"; Name = "ConvertibleSlateModePromptPreference"; Value = 2 }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Context\CloudExperienceHostIntent\Wireless"; Name = "ScoobeCheckCompleted"; Value = 1 }

    # ── start menu pins ───────────────────────────────────────────────────────
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "ConfigureStartPins"; Type = "String"; Value = '{"pinnedList":[{"packagedAppId":"Microsoft.WindowsStore_8wekyb3d8bbwe!App"},{"packagedAppId":"windows.immersivecontrolpanel_cw5n1h2txyewy!microsoft.windows.immersivecontrolpanel"},{"packagedAppId":"Microsoft.WindowsNotepad_8wekyb3d8bbwe!App"},{"packagedAppId":"Microsoft.Paint_8wekyb3d8bbwe!App"},{"desktopAppLink":"%APPDATA%\\Microsoft\\Windows\\Start Menu\\Programs\\File Explorer.lnk"},{"packagedAppId":"Microsoft.WindowsCalculator_8wekyb3d8bbwe!App"}]}' }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderDocuments";          Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderDocuments_ProviderSet"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderDownloads";          Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderDownloads_ProviderSet"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderFileExplorer";       Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderFileExplorer_ProviderSet"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderHomeGroup";          Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderHomeGroup_ProviderSet"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderMusic";              Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderMusic_ProviderSet";  Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderNetwork";            Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderNetwork_ProviderSet"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderPersonalFolder";     Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderPersonalFolder_ProviderSet"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderPictures";           Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderPictures_ProviderSet"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderSettings";           Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderSettings_ProviderSet"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderVideos";             Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderVideos_ProviderSet"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoResolveSearch";         Value = 1 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "LinkResolveIgnoreLinkInfo"; Value = 1 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoLowDiskSpaceChecks";    Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"; Name = "DisableGraphRecentItems"; Value = 1 }

    # ── cloud experience host intent ──────────────────────────────────────────
    "developer","gaming","family","creative","schoolwork","entertainment","business" | ForEach-Object {
        @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\$_"; Name = "Intent";   Value = 0 }
        @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\$_"; Name = "Priority"; Value = 0 }
    }

    # ── devices and hardware ──────────────────────────────────────────────────
    @{ Path = "HKCU:\Software\Microsoft\Shell\USB"; Name = "NotifyOnUsbErrors"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows"; Name = "LegacyDefaultPrinterMode"; Value = 1 }
    @{ Path = "HKCU:\Software\Microsoft\TabletTip\EmbeddedInkControl"; Name = "EnableInkingWithTouch"; Value = 0 }

    # ── system, gpu and dpi ───────────────────────────────────────────────────
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "LogPixels";              Value = 96 }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "Win8DpiScaling";         Value = 1 }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "EnablePerProcessSystemDPI"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\DWM"; Name = "UseDpiScaling"; Value = 0 }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"; Name = "HwSchMode"; Value = 2 }
    @{ Path = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"; Name = "DirectXUserGlobalSettings"; Value = "SwapEffectUpgradeEnable=1;VRROptimizeEnable=0;"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"; Name = "C:\Windows\explorer.exe"; Value = "GpuPreference=2;"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\DirectX\UserGpuPreferences"; Name = "C:\Windows\explorer.exe"; Value = "GpuPreference=2;"; Type = "String" }

    # ── notifications ─────────────────────────────────────────────────────────
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications"; Name = "ToastEnabled"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested"; Name = "Enabled"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings"; Name = "NOC_GLOBAL_SETTING_ALLOW_NOTIFICATION_SOUND"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings"; Name = "NOC_GLOBAL_SETTING_ALLOW_CRITICAL_TOASTS_ABOVE_LOCK"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings"; Name = "NOC_GLOBAL_SETTING_ALLOW_TOASTS_ABOVE_LOCK"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings"; Name = "AutoOpenCopilotLargeScreens"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Microsoft.SkyDrive.Desktop";                                          Name = "Enabled"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.AutoPlay";                                         Name = "Enabled"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.SecurityAndMaintenance";                           Name = "Enabled"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\windows.immersivecontrolpanel_cw5n1h2txyewy!microsoft.windows.immersivecontrolpanel"; Name = "Enabled"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.CapabilityAccess";                                 Name = "Enabled"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.StartupApp";                                       Name = "Enabled"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement"; Name = "ScoobeSystemSettingEnabled"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SmartActionPlatform\SmartClipboard"; Name = "Disabled"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications"; Name = "NoCloudApplicationNotification"; Value = 1 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate"; Name = "UpdateNotificationLevel"; Value = 2 }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement"; Name = "ScoobeSystemSettingEnabled"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Context\CloudExperienceHostIntent\Wireless"; Name = "ScoobeCheckCompleted"; Value = 1 }

    # ── focus assist ──────────────────────────────────────────────────────────
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache\DefaultAccount\$$windows.data.notifications.quiethourssettings\Current"; Name = "Data"; Type = "Binary"; Value = ([byte[]](0x02,0x00,0x00,0x00,0xB4,0x67,0x2B,0x68,0xF0,0x0B,0xD8,0x01,0x00,0x00,0x00,0x00,0x43,0x42,0x01,0x00,0xC2,0x0A,0x01,0xD2,0x14,0x28,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x51,0x00,0x75,0x00,0x69,0x00,0x65,0x00,0x74,0x00,0x48,0x00,0x6F,0x00,0x75,0x00,0x72,0x00,0x73,0x00,0x50,0x00,0x72,0x00,0x6F,0x00,0x66,0x00,0x69,0x00,0x6C,0x00,0x65,0x00,0x2E,0x00,0x55,0x00,0x6E,0x00,0x72,0x00,0x65,0x00,0x73,0x00,0x74,0x00,0x72,0x00,0x69,0x00,0x63,0x00,0x74,0x00,0x65,0x00,0x64,0x00,0xCA,0x28,0xD0,0x14,0x02,0x00,0x00)) }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache\DefaultAccount\$quietmomentfullscreen$windows.data.notifications.quietmoment\Current"; Name = "Data"; Type = "Binary"; Value = ([byte[]](0x02,0x00,0x00,0x00,0x97,0x1D,0x2D,0x68,0xF0,0x0B,0xD8,0x01,0x00,0x00,0x00,0x00,0x43,0x42,0x01,0x00,0xC2,0x0A,0x01,0xD2,0x1E,0x26,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x51,0x00,0x75,0x00,0x69,0x00,0x65,0x00,0x74,0x00,0x48,0x00,0x6F,0x00,0x75,0x00,0x72,0x00,0x73,0x00,0x50,0x00,0x72,0x00,0x6F,0x00,0x66,0x00,0x69,0x00,0x6C,0x00,0x65,0x00,0x2E,0x00,0x41,0x00,0x6C,0x00,0x61,0x00,0x72,0x00,0x6D,0x00,0x73,0x00,0x4F,0x00,0x6E,0x00,0x6C,0x00,0x79,0x00,0xC2,0x28,0x01,0xCA,0x50,0x00,0x00)) }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache\DefaultAccount\$quietmomentgame$windows.data.notifications.quietmoment\Current"; Name = "Data"; Type = "Binary"; Value = ([byte[]](0x02,0x00,0x00,0x00,0x6C,0x39,0x2D,0x68,0xF0,0x0B,0xD8,0x01,0x00,0x00,0x00,0x00,0x43,0x42,0x01,0x00,0xC2,0x0A,0x01,0xD2,0x1E,0x28,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x51,0x00,0x75,0x00,0x69,0x00,0x65,0x00,0x74,0x00,0x48,0x00,0x6F,0x00,0x75,0x00,0x72,0x00,0x73,0x00,0x50,0x00,0x72,0x00,0x6F,0x00,0x66,0x00,0x69,0x00,0x6C,0x00,0x65,0x00,0x2E,0x00,0x50,0x00,0x72,0x00,0x69,0x00,0x6F,0x00,0x72,0x00,0x69,0x00,0x74,0x00,0x79,0x00,0x4F,0x00,0x6E,0x00,0x6C,0x00,0x79,0x00,0xC2,0x28,0x01,0xCA,0x50,0x00,0x00)) }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache\DefaultAccount\$quietmomentpresentation$windows.data.notifications.quietmoment\Current"; Name = "Data"; Type = "Binary"; Value = ([byte[]](0x02,0x00,0x00,0x00,0x83,0x6E,0x2D,0x68,0xF0,0x0B,0xD8,0x01,0x00,0x00,0x00,0x00,0x43,0x42,0x01,0x00,0xC2,0x0A,0x01,0xD2,0x1E,0x26,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x51,0x00,0x75,0x00,0x69,0x00,0x65,0x00,0x74,0x00,0x48,0x00,0x6F,0x00,0x75,0x00,0x72,0x00,0x73,0x00,0x50,0x00,0x72,0x00,0x6F,0x00,0x66,0x00,0x69,0x00,0x6C,0x00,0x65,0x00,0x2E,0x00,0x41,0x00,0x6C,0x00,0x61,0x00,0x72,0x00,0x6D,0x00,0x73,0x00,0x4F,0x00,0x6E,0x00,0x6C,0x00,0x79,0x00,0xC2,0x28,0x01,0xCA,0x50,0x00,0x00)) }

    # ── storage, power and shell ──────────────────────────────────────────────
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\VideoSettings"; Name = "VideoQualityOnBattery"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense"; Name = "AllowStorageSenseGlobal"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"; Name = "04";   Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"; Name = "2048"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"; Name = "08";   Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"; Name = "256";  Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"; Name = "32";   Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"; Name = "StoragePoliciesChanged"; Value = 1 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CDP"; Name = "DragTrayEnabled";               Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CDP"; Name = "RomeSdkChannelUserAuthzPolicy"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CDP"; Name = "CdpSessionUserAuthzPolicy";     Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "SnapAssist";           Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "EnableSnapBar";        Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "EnableTaskGroups";     Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "EnableSnapAssistFlyout"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "SnapFill";             Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "JointResize";          Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "DITest";               Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "MultiTaskingAltTabFilter"; Value = 3 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings"; Name = "TaskbarEndTask"; Value = 1 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell"; Name = "SignInMode";   Value = 1 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell"; Name = "TabletMode";   Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell"; Name = "ConvertibleSlateModePromptPreference"; Value = 2 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarAppsVisibleInTabletMode"; Value = 1 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarAutoHideInTabletMode";    Value = 0 }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"; Name = "LongPathsEnabled"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsMitigation"; Name = "UserPreference"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate"; Name = "AutoDownload"; Value = 2 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; Name = "AllowClipboardHistory";    Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; Name = "AllowCrossDeviceClipboard"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\WindowsInkWorkspace"; Name = "AllowWindowsInkWorkspace";            Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\WindowsInkWorkspace"; Name = "AllowSuggestedAppsInWindowsInkWorkspace"; Value = 0 }

    # ── cross-device resume ───────────────────────────────────────────────────
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CrossDeviceResume\Configuration"; Name = "IsResumeAllowed";        Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CrossDeviceResume\Configuration"; Name = "IsOneDriveResumeAllowed"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Connectivity\DisableCrossDeviceResume"; Name = "value"; Value = 1 }

    # ── start menu feature management ─────────────────────────────────────────
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\14\2792562829"; Name = "EnabledState"; Value = 2 }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\14\3036241548"; Name = "EnabledState"; Value = 2 }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\14\734731404";  Name = "EnabledState"; Value = 2 }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\14\762256525";  Name = "EnabledState"; Value = 2 }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\8\1387020943";  Name = "EnabledState"; Value = 1 }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\8\1694661260";  Name = "EnabledState"; Value = 1 }

    # ── uwp, ai and copilot ───────────────────────────────────────────────────
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy"; Name = "LetAppsRunInBackground"; Value = 2 }
    @{ Path = "HKCU:\Software\Microsoft\input"; Name = "IsInputAppPreloadEnabled"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Dsh"; Name = "IsPrelaunchEnabled"; Value = 0 }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot";  Name = "TurnOffWindowsCopilot"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot";  Name = "TurnOffWindowsCopilot"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI";       Name = "DisableAIDataAnalysis"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI";       Name = "AllowRecallEnablement"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI";       Name = "DisableClickToDo";      Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\Shell\Copilot\BingChat";   Name = "IsUserEligible"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint"; Name = "DisableGenerativeFill"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint"; Name = "DisableCocreator";      Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint"; Name = "DisableImageCreator";   Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\WindowsNotepad"; Name = "DisableAIFeatures"; Value = 1 }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\WindowsAI"; Name = "DisableAIDataAnalysis"; Value = 1 }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\WindowsAI"; Name = "AllowRecallEnablement"; Value = 0 }
    @{ Path = "HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"; Name = "TurnOffWindowsCopilot"; Value = 1 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\Shell\Copilot\BingChat";  Name = "IsUserEligible"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FeatureUsage\ShowJumpView"; Name = "Microsoft.Copilot_8wekyb3d8bbwe!App"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\WindowsCopilot"; Name = "DisableAIDataAnalysis"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization"; Name = "RestrictImplicitInkCollection"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization"; Name = "AllowInputPersonalization";     Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\HandwritingErrorReports"; Name = "PreventHandwritingErrorReports"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\TabletPC"; Name = "PreventHandwritingDataSharing"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Input\TIPC"; Name = "Enabled"; Value = 0 }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Input\TIPC"; Name = "Enabled"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\TextInput"; Name = "AllowLinguisticDataCollection"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EventLog\ProtectedEventLogging"; Name = "EnableProtectedEventLogging"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\Windows.Gaming.GameBar.PresenceServer.Internal.PresenceWriter"; Name = "ActivationType"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\Microsoft.Xbox.GamingAI.Companion.Host.GamingCompanionHostOptions"; Name = "ActivationType"; Value = 4294967295 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\Microsoft.Xbox.GamingAI.Companion.Host.GamingCompanionHostOptions"; Name = "Server"; Value = ""; Type = "String" }

    # ── advertising and content delivery ──────────────────────────────────────
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo"; Name = "Enabled"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo"; Name = "DisabledByGroupPolicy"; Value = 1 }
    "ContentDeliveryAllowed","FeatureManagementEnabled","OemPreInstalledAppsEnabled",
    "PreInstalledAppsEnabled","PreInstalledAppsEverEnabled","RotatingLockScreenEnabled",
    "RotatingLockScreenOverlayEnabled","SilentInstalledAppsEnabled","SlideshowEnabled",
    "SoftLandingEnabled","SubscribedContentEnabled","RemediationRequired",
    "SubscribedContent-310093Enabled","SubscribedContent-338389Enabled",
    "SubscribedContent-314559Enabled","SubscribedContent-280815Enabled",
    "SubscribedContent-314563Enabled","SubscribedContent-202914Enabled",
    "SubscribedContent-338387Enabled","SubscribedContent-280810Enabled",
    "SubscribedContent-280811Enabled","SubscribedContent-338393Enabled",
    "SubscribedContent-353694Enabled","SubscribedContent-353696Enabled" | ForEach-Object {
        @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = $_; Value = 0 }
        @{ Path = "HKU:\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = $_; Value = 0 }
    }

    # ── gamebar protocol redirection ──────────────────────────────────────────
    @{ Path = "HKCR:\ms-gamebar"; Name = "";            Value = "URL:ms-gamebar"; Type = "String" }
    @{ Path = "HKCR:\ms-gamebar"; Name = "URL Protocol"; Value = "";              Type = "String" }
    @{ Path = "HKCR:\ms-gamebar"; Name = "NoOpenWith";   Value = "";              Type = "String" }
    @{ Path = "HKCR:\ms-gamebar\shell\open\command"; Name = ""; Value = "$env:SystemRoot\System32\systray.exe"; Type = "String" }
    @{ Path = "HKCR:\ms-gamebarservices"; Name = "";            Value = "URL:ms-gamebarservices"; Type = "String" }
    @{ Path = "HKCR:\ms-gamebarservices"; Name = "URL Protocol"; Value = "";                      Type = "String" }
    @{ Path = "HKCR:\ms-gamebarservices"; Name = "NoOpenWith";   Value = "";                      Type = "String" }
    @{ Path = "HKCR:\ms-gamebarservices\shell\open\command"; Name = ""; Value = "$env:SystemRoot\System32\systray.exe"; Type = "String" }
    @{ Path = "HKCR:\ms-gamingoverlay"; Name = "";            Value = "URL:ms-gamingoverlay"; Type = "String" }
    @{ Path = "HKCR:\ms-gamingoverlay"; Name = "URL Protocol"; Value = "";                    Type = "String" }
    @{ Path = "HKCR:\ms-gamingoverlay"; Name = "NoOpenWith";   Value = "";                    Type = "String" }
    @{ Path = "HKCU:\ms-gamingoverlay\shell\open\command"; Name = ""; Value = "$env:SystemRoot\System32\systray.exe"; Type = "String" }

    # ── control panel ─────────────────────────────────────────────────────────
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "JPEGImportQuality"; Value = 100 }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "ActiveWndTrkTimeout"; Value = 10 }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "AutoEndTasks";       Value = "1"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "HungAppTimeout";     Value = "2000"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "WaitToKillAppTimeout"; Value = "2000"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "LowLevelHooksTimeout"; Value = "1000"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Sound";   Name = "Beep"; Value = "no"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Desktop"; Name = "JPEGImportQuality"; Value = 100 }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Desktop"; Name = "ActiveWndTrkTimeout"; Value = 10 }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Desktop"; Name = "AutoEndTasks";    Value = "1"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Desktop"; Name = "HungAppTimeout";  Value = "2000"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Desktop"; Name = "WaitToKillAppTimeout"; Value = "2000"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Desktop"; Name = "LowLevelHooksTimeout"; Value = "1000"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Desktop"; Name = "MenuShowDelay";   Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Sound";   Name = "Beep"; Value = "no"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "AllowOnlineTips"; Value = 0 }

    # ── sound schemes ─────────────────────────────────────────────────────────
    "Apps\.Default\.Default\.Current","Apps\.Default\CriticalBatteryAlarm\.Current",
    "Apps\.Default\DeviceConnect\.Current","Apps\.Default\DeviceDisconnect\.Current",
    "Apps\.Default\DeviceFail\.Current","Apps\.Default\FaxBeep\.Current",
    "Apps\.Default\LowBatteryAlarm\.Current","Apps\.Default\MailBeep\.Current",
    "Apps\.Default\MessageNudge\.Current","Apps\.Default\Notification.Default\.Current",
    "Apps\.Default\Notification.IM\.Current","Apps\.Default\Notification.Mail\.Current",
    "Apps\.Default\Notification.Proximity\.Current","Apps\.Default\Notification.Reminder\.Current",
    "Apps\.Default\Notification.SMS\.Current","Apps\.Default\ProximityConnection\.Current",
    "Apps\.Default\SystemAsterisk\.Current","Apps\.Default\SystemExclamation\.Current",
    "Apps\.Default\SystemHand\.Current","Apps\.Default\SystemNotification\.Current",
    "Apps\.Default\WindowsUAC\.Current",
    "Apps\sapisvr\DisNumbersSound\.current","Apps\sapisvr\HubOffSound\.current",
    "Apps\sapisvr\HubOnSound\.current","Apps\sapisvr\HubSleepSound\.current",
    "Apps\sapisvr\MisrecoSound\.current","Apps\sapisvr\PanelSound\.current" | ForEach-Object {
        @{ Path = "HKCU:\AppEvents\Schemes\$_"; Name = ""; Value = ""; Type = "String" }
    }

    # ── security and smartscreen ──────────────────────────────────────────────
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Edge\SmartScreenEnabled"; Name = ""; Value = 0 }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost"; Name = "EnableWebContentEvaluation"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Windows Security Health\State";  Name = "AccountProtection_MicrosoftAccount_Disconnected"; Value = 0 }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows Security Health\State"; Name = "AccountProtection_MicrosoftAccount_Disconnected"; Value = 0 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows Defender\Reporting"; Name = "DisableGenericRePorts"; Value = 1 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows Defender\Signature Updates"; Name = "DisableScheduledSignatureUpdateOnBattery"; Value = 1 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows Defender\SmartScreen"; Name = "ConfigureAppInstallControlEnabled"; Value = 1 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows Defender\SmartScreen"; Name = "ConfigureAppInstallControl"; Value = "Anywhere"; Type = "String" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\MicrosoftEdge\PhishingFilter"; Name = "EnabledV9"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Systray"; Name = "HideSystray"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"; Name = "SecurityHealth"; Value = ""; Type = "String" }

    # ── windows update and pause ──────────────────────────────────────────────
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"; Name = "PauseUpdatesExpiryTime";        Value = $pauseStr; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"; Name = "PauseFeatureUpdatesEndTime";    Value = $pauseStr; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"; Name = "PauseFeatureUpdatesStartTime";  Value = $todayStr; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"; Name = "PauseQualityUpdatesEndTime";    Value = $pauseStr; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"; Name = "PauseQualityUpdatesStartTime";  Value = $todayStr; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"; Name = "PauseUpdatesStartTime";         Value = $todayStr; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"; Name = "TrayIconVisibility";            Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"; Name = "HideMCTLink";                   Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"; Name = "RestartNotificationsAllowed2";  Value = 0 }

    # ── driver blocks ─────────────────────────────────────────────────────────
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\Device Metadata"; Name = "PreventDeviceMetadataFromNetwork"; Value = 1 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\DeviceInstall\Settings"; Name = "DisableSendGenericDriverNotFoundToWER";      Value = 1 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\DeviceInstall\Settings"; Name = "DisableSendRequestAdditionalSoftwareToWER"; Value = 1 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\DriverSearching"; Name = "SearchOrderConfig"; Value = 0 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate"; Name = "SetAllowOptionalContent";              Value = 0 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate"; Name = "AllowTemporaryEnterpriseFeatureControl"; Value = 0 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate"; Name = "ExcludeWUDriversInQualityUpdate";       Value = 1 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate\AU"; Name = "IncludeRecommendedUpdates"; Value = 0 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate\AU"; Name = "EnableFeaturedSoftware";    Value = 0 }

    # ── system and stability ──────────────────────────────────────────────────
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"; Name = "DisplayParameters"; Value = 1 }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\CrashControl"; Name = "AutoReboot";       Value = 0 }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\CrashControl"; Name = "CrashDumpEnabled"; Value = 3 }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"; Name = "DisableWpbtExecution"; Value = 1 }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\Session Manager";     Name = "DisableWpbtExecution"; Value = 1 }
    @{ Path = "HKCU:\Console\%SystemRoot%_System32_WindowsPowerShell_v1.0_powershell.exe"; Name = "ScreenColors"; Value = 15 }

    # ── ui colors ─────────────────────────────────────────────────────────────
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Accents\0\Theme0"; Name = "Color"; Value = 4279374354 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Accents\0\Theme1"; Name = "Color"; Value = 4278190294 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Accents\1\Theme0"; Name = "Color"; Value = 4294926889 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Accents\1\Theme1"; Name = "Color"; Value = 4282117119 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Accents\2\Theme0"; Name = "Color"; Value = 4278229247 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Accents\2\Theme1"; Name = "Color"; Value = 4283680768 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Accents\3\Theme0"; Name = "Color"; Value = 4294901930 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Accents\3\Theme1"; Name = "Color"; Value = 4294967064 }

    # ── wifi sense ────────────────────────────────────────────────────────────
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\config"; Name = "AutoConnectAllowedOEM"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\features"; Name = "PaidWifi";      Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\features"; Name = "WiFiSenseOpen"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowWiFiHotSpotReporting";           Name = "value"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowAutoConnectToWiFiSenseHotspots"; Name = "value"; Value = 0 }

    # ── app deprovisioning ────────────────────────────────────────────────────
    "Microsoft.549981C3F5F10_8wekyb3d8bbwe","Microsoft.BingNews_8wekyb3d8bbwe",
    "Microsoft.BingWeather_8wekyb3d8bbwe","Microsoft.ECApp_8wekyb3d8bbwe",
    "Microsoft.GetHelp_8wekyb3d8bbwe","Microsoft.Getstarted_8wekyb3d8bbwe",
    "Microsoft.MicrosoftEdge.Stable_8wekyb3d8bbwe","Microsoft.MicrosoftEdge_8wekyb3d8bbwe",
    "Microsoft.MicrosoftEdgeDevToolsClient_8wekyb3d8bbwe","Microsoft.MicrosoftSolitaireCollection_8wekyb3d8bbwe",
    "Microsoft.MicrosoftStickyNotes_8wekyb3d8bbwe","Microsoft.People_8wekyb3d8bbwe",
    "Microsoft.PowerAutomateDesktop_8wekyb3d8bbwe","Microsoft.Todos_8wekyb3d8bbwe",
    "Microsoft.Windows.Apprep.ChxApp_cw5n1h2txyewy","Microsoft.Windows.ContentDeliveryManager_cw5n1h2txyewy",
    "Microsoft.Windows.PeopleExperienceHost_cw5n1h2txyewy","Microsoft.Windows.Photos_8wekyb3d8bbwe",
    "Microsoft.Windows.SecureAssessmentBrowser_cw5n1h2txyewy","Microsoft.WindowsAlarms_8wekyb3d8bbwe",
    "Microsoft.WindowsCamera_8wekyb3d8bbwe","Microsoft.WindowsFeedbackHub_8wekyb3d8bbwe",
    "Microsoft.WindowsMaps_8wekyb3d8bbwe","Microsoft.WindowsSoundRecorder_8wekyb3d8bbwe",
    "Microsoft.ZuneMusic_8wekyb3d8bbwe","Microsoft.ZuneVideo_8wekyb3d8bbwe",
    "MicrosoftWindows.Client.WebExperience_cw5n1h2txyewy","microsoft.windowscommunicationsapps_8wekyb3d8bbwe",
    "Microsoft.Advertising.Xaml_8wekyb3d8bbwe","Microsoft.Microsoft3DViewer_8wekyb3d8bbwe",
    "Microsoft.MixedReality.Portal_8wekyb3d8bbwe","Microsoft.MSPaint_8wekyb3d8bbwe",
    "Microsoft.Paint_8wekyb3d8bbwe","Microsoft.WindowsNotepad_8wekyb3d8bbwe",
    "clipchamp.clipchamp_yxz26nhyzhsrt","Microsoft.SecHealthUI_8wekyb3d8bbwe",
    "Microsoft.WindowsCalculator_8wekyb3d8bbwe","MicrosoftCorporationII.QuickAssist_8wekyb3d8bbwe",
    "MicrosoftCorporationII.MicrosoftFamily_8wekyb3d8bbwe","Microsoft.Whiteboard_8wekyb3d8bbwe",
    "microsoft.microsoftskydrive_8wekyb3d8bbwe","Microsoft.MicrosoftTeamsforSurfaceHub_8wekyb3d8bbwe",
    "MicrosoftCorporationII.MailforSurfaceHub_8wekyb3d8bbwe","Microsoft.MicrosoftPowerBIForWindows_8wekyb3d8bbwe",
    "Microsoft.SkypeApp_kzf8qxf38zg5c","Microsoft.MicrosoftOfficeHub_8wekyb3d8bbwe",
    "Microsoft.Office.OneNote_8wekyb3d8bbwe","Microsoft.Office.Excel_8wekyb3d8bbwe",
    "Microsoft.Office.PowerPoint_8wekyb3d8bbwe","Microsoft.Office.Word_8wekyb3d8bbwe",
    "Microsoft.Windows.DevHome_8wekyb3d8bbwe","Microsoft.OutlookForWindows_8wekyb3d8bbwe",
    "MSTeams_8wekyb3d8bbwe" | ForEach-Object {
        @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\$_"; Name = ""; Value = "" }
    }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\EdgeUpdate"; Name = "DoNotUpdateToEdgeWithChromium"; Value = 1 }

    # ── logging and system fixes ──────────────────────────────────────────────
    @{ Path = "HKLM:\SOFTWARE\Microsoft\ClickToRun\OverRide"; Name = "DisableLogManagement"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration"; Name = "TimerInterval"; Value = "900000"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SPP\Clients"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore"; Name = "RPSessionInterval"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore\cfg"; Name = "DiskPercent"; Value = 0 }
    @{ Path = "HKLM:\System\CurrentControlSet\Control\TimeZoneInformation"; Name = "RealTimeIsUniversal"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; Name = "EnableLinkedConnections"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate"; Name = "InstallDefault"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate"; Name = "Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate"; Name = "Install{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"; Value = 1 }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\SafeBoot\Minimal\MSIServer"; Name = ""; Value = "Service"; Type = "String" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\SafeBoot\Network\MSIServer"; Name = ""; Value = "Service"; Type = "String" }

    # ── oem and edition branding ──────────────────────────────────────────────
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"; Name = "EditionSubManufacturer"; Value = "Albus"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"; Name = "EditionSubstring";       Value = "Albus"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"; Name = "EditionSubVersion";      Value = "Albus"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation"; Name = "HelpCustomized";  Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation"; Name = "Manufacturer";    Value = "Albus"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation"; Name = "SupportProvider"; Value = "Albus Support"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation"; Name = "SupportAppURL";   Value = "albus-support"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation"; Name = "SupportURL";      Value = "https://github.com/oqullcan/albuswin"; Type = "String" }

    # ── app compatibility ─────────────────────────────────────────────────────
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\AppCompat"; Name = "DisableEngine";    Value = 1 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\AppCompat"; Name = "AITEnable";        Value = 0 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\AppCompat"; Name = "DisableUAR";       Value = 1 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\AppCompat"; Name = "DisablePCA";       Value = 1 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\AppCompat"; Name = "DisableInventory"; Value = 1 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\AppCompat"; Name = "SbEnable";         Value = 1 }

    # ── ceip ─────────────────────────────────────────────────────────────────
    @{ Path = "HKLM:\Software\Policies\Microsoft\SQMClient\Windows";         Name = "CEIPEnable";                       Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\AppV\CEIP";                 Name = "CEIPEnable";                       Value = 0 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Internet Explorer\SQM";     Name = "DisableCustomerImprovementProgram"; Value = 1 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Messenger\Client";          Name = "CEIP";                             Value = 2 }
    @{ Path = "HKLM:\Software\Microsoft\Windows NT\CurrentVersion\UnattendSettings\SQMClient"; Name = "CEIPEnabled";    Value = 0 }

    # ── cloud content ─────────────────────────────────────────────────────────
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableSoftLanding"; Value = 1 }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\CloudContent"; Name = "ConfigureWindowsSpotlight";               Value = 2 }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\CloudContent"; Name = "IncludeEnterpriseSpotlight";               Value = 0 }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableThirdPartySuggestions";            Value = 1 }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableTailoredExperiencesWithDiagnosticData"; Value = 1 }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableWindowsSpotlightFeatures";         Value = 1 }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableWindowsSpotlightWindowsWelcomeExperience"; Value = 1 }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableWindowsSpotlightOnActionCenter";   Value = 1 }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableWindowsSpotlightOnSettings";       Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; Name = "DisableTailoredExperiencesWithDiagnosticData"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; Name = "DisableCloudOptimizedContent";            Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; Name = "DisableWindowsSpotlightFeatures";         Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; Name = "DisableWindowsConsumerFeatures";          Value = 1 }

    # ── internet restrictions ─────────────────────────────────────────────────
    @{ Path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System"; Name = "MSAOptional"; Value = 1 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\Messaging"; Name = "AllowMessageSync"; Value = 0 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\EdgeUI"; Name = "DisableHelpSticker"; Value = 1 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoPublishingWizard";  Value = 1 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoWebServices";       Value = 1 }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows NT\CurrentVersion\Software Protection Platform"; Name = "NoGenTicket"; Value = 1 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoOnlinePrintsWizard"; Value = 1 }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoInternetOpenWith";   Value = 1 }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows NT\Printers"; Name = "DisableHTTPPrinting";    Value = 1 }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows NT\Printers"; Name = "DisableWebPnPDownload";  Value = 1 }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\HandwritingErrorReports"; Name = "PreventHandwritingErrorReports"; Value = 1 }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\TabletPC"; Name = "PreventHandwritingDataSharing"; Value = 1 }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Assistance\Client\1.0"; Name = "NoOnlineAssist";       Value = 1 }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Assistance\Client\1.0"; Name = "NoExplicitFeedback";   Value = 1 }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Assistance\Client\1.0"; Name = "NoImplicitFeedback";   Value = 1 }
    @{ Path = "HKCU:\Software\Policies\Microsoft\WindowsMovieMaker"; Name = "WebHelp";      Value = 1 }
    @{ Path = "HKCU:\Software\Policies\Microsoft\WindowsMovieMaker"; Name = "CodecDownload"; Value = 1 }
    @{ Path = "HKCU:\Software\Policies\Microsoft\WindowsMovieMaker"; Name = "WebPublish";   Value = 1 }
    @{ Path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoPublishingWizard";  Value = 1 }
    @{ Path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoOnlinePrintsWizard"; Value = 1 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows NT\CurrentVersion\Software Protection Platform"; Name = "NoGenTicket"; Value = 1 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\PCHealth\HelpSvc"; Name = "Headlines";       Value = 0 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\PCHealth\HelpSvc"; Name = "MicrosoftKBSearch"; Value = 0 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\PCHealth\ErrorReporting"; Name = "DoReport"; Value = 0 }
    @{ Path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoInternetOpenWith"; Value = 1 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\Internet Connection Wizard"; Name = "ExitOnMSICW"; Value = 1 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\EventViewer"; Name = "MicrosoftEventVwrDisableLinks"; Value = 1 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\Registration Wizard Control"; Name = "NoRegistration"; Value = 1 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\SearchCompanion"; Name = "DisableContentFileUpdates"; Value = 1 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows NT\Printers"; Name = "DisableHTTPPrinting";   Value = 1 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows NT\Printers"; Name = "DisableWebPnPDownload"; Value = 1 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\HandwritingErrorReports"; Name = "PreventHandwritingErrorReports"; Value = 1 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\TabletPC"; Name = "PreventHandwritingDataSharing"; Value = 1 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\WindowsMovieMaker"; Name = "WebHelp";       Value = 1 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\WindowsMovieMaker"; Name = "CodecDownload";  Value = 1 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\WindowsMovieMaker"; Name = "WebPublish";     Value = 1 }

    # ── telemetry firewall blocks ─────────────────────────────────────────────
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules"; Name = "Block-Unified-Telemetry-Client"; Value = "v2.31|Action=Block|Active=TRUE|Dir=Out|RA42=IntErnet|RA62=IntErnet|App=%SystemRoot%\system32\svchost.exe|Svc=DiagTrack|Name=Block-Unified-Telemetry-Client|Desc=Block-Unified-Telemetry-Client|EmbedCtxt=DiagTrack|"; Type = "String" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules"; Name = "Block-Windows-Error-Reporting";   Value = "v2.31|Action=Block|Active=TRUE|Dir=Out|RA42=IntErnet|RA62=IntErnet|App=%SystemRoot%\system32\svchost.exe|Svc=WerSvc|Name=Block-Unified-Telemetry-Client|Desc=Block-Windows-Error-Reporting|EmbedCtxt=WerSvc|"; Type = "String" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Services\SharedAccess\Defaults\FirewallPolicy\FirewallRules"; Name = "Block-Unified-Telemetry-Client"; Value = "v2.31|Action=Block|Active=TRUE|Dir=Out|RA42=IntErnet|RA62=IntErnet|App=%SystemRoot%\system32\svchost.exe|Svc=DiagTrack|Name=Block-Unified-Telemetry-Client|Desc=Block-Unified-Telemetry-Client|EmbedCtxt=DiagTrack|"; Type = "String" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Services\SharedAccess\Defaults\FirewallPolicy\FirewallRules"; Name = "Block-Windows-Error-Reporting";   Value = "v2.31|Action=Block|Active=TRUE|Dir=Out|RA42=IntErnet|RA62=IntErnet|App=%SystemRoot%\system32\svchost.exe|Svc=WerSvc|Name=Block-Unified-Telemetry-Client|Desc=Block-Windows-Error-Reporting|EmbedCtxt=WerSvc|"; Type = "String" }

    # ── data collection ───────────────────────────────────────────────────────
    @{ Path = "HKCU:\SOFTWARE\Policies\Microsoft\Windows\DataCollection";     Name = "AllowTelemetry"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection";     Name = "AllowTelemetry"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection"; Name = "AllowTelemetry"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection"; Name = "MaxTelemetryAllowed"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Policies\DataCollection"; Name = "AllowTelemetry"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\System\AllowTelemetry"; Name = "value"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CPSS\DevicePolicy\AllowTelemetry"; Name = "DefaultValue"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CPSS\Store\AllowTelemetry"; Name = "Value"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "AllowCommercialDataPipeline";          Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "AllowDeviceNameInTelemetry";           Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "DisableEnterpriseAuthProxy";           Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "MicrosoftEdgeDataOptIn";               Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "DisableTelemetryOptInChangeNotification"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "DisableTelemetryOptInSettingsUx";      Value = 1 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\PreviewBuilds";  Name = "EnableConfigFlighting";                Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "DoNotShowFeedbackNotifications";       Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "LimitEnhancedDiagnosticDataWindowsAnalytics"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "AllowBuildPreview";                   Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "LimitDiagnosticLogCollection";        Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "LimitDumpCollection";                 Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "AllowDesktopAnalyticsProcessing";     Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "AllowWUfBCloudProcessing";            Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "AllowUpdateComplianceProcessing";     Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "DisableOneSettingsDownloads";         Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\System"; Name = "AllowExperimentation"; Value = 0 }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\WMI\Autologger\Diagtrack-Listener"; Name = "Start"; Value = 0 }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\WMI\Autologger\SQMLogger";          Name = "Start"; Value = 0 }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\WMI\Autologger\SetupPlatformTel";   Name = "Start"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection"; Name = "DoNotShowFeedbackNotifications"; Value = 1 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows NT\CurrentVersion\Software Protection Platform"; Name = "NoGenTicket"; Value = 1 }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Personalization\Settings"; Name = "AcceptedPrivacyPolicy"; Value = 0 }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Siuf\Rules"; Name = "NumberOfSIUFInPeriod"; Value = 0 }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Siuf\Rules"; Name = "PeriodInNanoSeconds";  Value = ""; Type = "String" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\InputPersonalization\TrainedDataStore"; Name = "HarvestContacts"; Value = 0 }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\InputPersonalization"; Name = "RestrictImplicitInkCollection";  Value = 1 }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\InputPersonalization"; Name = "RestrictImplicitTextCollection"; Value = 1 }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy"; Name = "TailoredExperiencesWithDiagnosticDataEnabled"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; Name = "DisableTailoredExperiencesWithDiagnosticData"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\MdmCommon\SettingValues"; Name = "LocationSyncEnabled"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\FindMyDevice"; Name = "AllowFindMyDevice"; Value = 0 }
    @{ Path = "HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy"; Name = "HasAccepted"; Value = 0 }

    # ── windows error reporting ───────────────────────────────────────────────
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"; Name = "AutoApproveOSDumps"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"; Name = "LoggingDisabled";    Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"; Name = "Disabled";           Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"; Name = "DontSendAdditionalData"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"; Name = "DontShowUI";         Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"; Name = "DisableArchive";     Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"; Name = "DisableWerUpload";   Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting"; Name = "Disabled";            Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting"; Name = "DontSendAdditionalData"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting"; Name = "LoggingDisabled";     Value = 1 }
    @{ Path = "HKLM:\Software\Microsoft\Windows\Windows Error Reporting\Consent"; Name = "DefaultConsent";         Value = 1 }
    @{ Path = "HKLM:\Software\Microsoft\Windows\Windows Error Reporting\Consent"; Name = "DefaultOverrideBehavior"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting\Consent"; Name = "0"; Value = ""; Type = "String" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\BitLocker"; Name = "PreventDeviceEncryption"; Value = 1 }

    # ── security and logon ────────────────────────────────────────────────────
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsSelfHost\UI\Visibility"; Name = "HideInsiderPage"; Value = 1 }
    @{ Path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System"; Name = "EnableFirstLogonAnimation";    Value = 0 }
    @{ Path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System"; Name = "DisableStartupSound";          Value = 1 }
    @{ Path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System"; Name = "DisableAutomaticRestartSignOn"; Value = 1 }
    @{ Path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System"; Name = "MSAOptional"; Value = 1 }

    # ── multimedia ────────────────────────────────────────────────────────────
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"; Name = "NetworkThrottlingIndex"; Value = 10 }

    # ── network settings ──────────────────────────────────────────────────────
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters"; Name = "EnableNetbios"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp"; Name = "DisableWpad";         Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp"; Name = "EnableDefaultHttp2";  Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient"; Name = "MaxNegativeCacheTtl"; Value = 5 }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Services\BFE\Parameters\Policy\Options"; Name = "CollectConnections"; Value = 0 }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Services\BFE\Parameters\Policy\Options"; Name = "CollectNetEvents";    Value = 0 }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Services\Dhcp"; Name = "PdcActivationDisabled"; Value = 1 }
    @{ Path = "HKLM:\System\CurrentControlSet\Services\Dnscache\Parameters"; Name = "DisableCoalescing"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WcmSvc\Local";       Name = "fDisablePowerManagement"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WcmSvc\GroupPolicy"; Name = "fDisablePowerManagement"; Value = 1 }

    # ── graphics drivers ──────────────────────────────────────────────────────
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"; Name = "MiracastForceDisable";          Value = 1 }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"; Name = "TdrDelay";                      Value = 12 }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"; Name = "WarpSupportsResourceResidency"; Value = 1 }

    # ── oobe ──────────────────────────────────────────────────────────────────
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "HideOnlineAccountScreens";  Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE";       Name = "HideOnlineAccountScreens";  Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "HideEULAPage";              Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE";       Name = "HideEULAPage";              Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "SkipMachineOOBE";           Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "SkipUserOOBE";              Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "HideWirelessSetupInOOBE";   Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE";       Name = "HideWirelessSetupInOOBE";   Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "NetworkLocation"; Value = "Home"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "ProtectYourPC"; Value = 3 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "HideLocalAccountScreen"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "DisablePrivacyExperience"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE";       Name = "DisablePrivacyExperience"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "HideOEMRegistrationScreen"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "EnableCortanaVoice"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "DisableVoice";        Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "BypassNRO";           Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE\AppSettings"; Name = "Skype-UserConsentAccepted"; Value = 0 }

    # ── updates ───────────────────────────────────────────────────────────────
    @{ Path = "HKLM:\Software\Policies\Microsoft\WindowsStore"; Name = "AutoDownload";    Value = 4 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\WindowsStore"; Name = "DisableOSUpgrade"; Value = 1 }
    @{ Path = "HKLM:\SYSTEM\Setup\UpgradeNotification"; Name = "UpgradeAvailable"; Value = 0 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\MRT"; Name = "DontReportInfectionInformation"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"; Name = "DODownloadMode"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PreviewBuilds"; Name = "AllowBuildPreview"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager"; Name = "ShippedWithReserves"; Value = 0 }
    @{ Path = "HKLM:\Software\Policies\Microsoft\WindowsMediaPlayer"; Name = "DisableAutoUpdate"; Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate";  Name = "workCompleted"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate";  Name = "workCompleted"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe"; Name = "BlockedOobeUpdaters"; Value = '["MS_Outlook"]'; Type = "String" }

    # ── bypass requirements ───────────────────────────────────────────────────
    @{ Path = "HKLM:\SYSTEM\Setup\LabConfig"; Name = "BypassSecureBootCheck"; Value = 1 }
    @{ Path = "HKLM:\SYSTEM\Setup\LabConfig"; Name = "BypassTPMCheck";        Value = 1 }
    @{ Path = "HKLM:\SYSTEM\Setup\LabConfig"; Name = "BypassCPUCheck";        Value = 1 }
    @{ Path = "HKLM:\SYSTEM\Setup\LabConfig"; Name = "BypassRAMCheck";        Value = 1 }
    @{ Path = "HKLM:\SYSTEM\Setup\LabConfig"; Name = "BypassStorageCheck";    Value = 1 }
    @{ Path = "HKLM:\SYSTEM\Setup\MoSetup"; Name = "AllowUpgradesWithUnsupportedTPMOrCPU"; Value = 1 }
    @{ Path = "HKCU:\Control Panel\UnsupportedHardwareNotificationCache"; Name = "SV1"; Value = 0 }
    @{ Path = "HKCU:\Control Panel\UnsupportedHardwareNotificationCache"; Name = "SV2"; Value = 0 }
    @{ Path = "HKU:\.DEFAULT\Control Panel\UnsupportedHardwareNotificationCache"; Name = "SV1"; Value = 0 }
    @{ Path = "HKU:\.DEFAULT\Control Panel\UnsupportedHardwareNotificationCache"; Name = "SV2"; Value = 0 }

    # ── configure boot ────────────────────────────────────────────────────────
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\Session Manager"; Name = "BootExecute"; Value = "autocheck autochk /k:C*"; Type = "MultiString" }

    # ── ifeo: telemetry executables and cpu priorities ────────────────────────
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\CompatTelRunner.exe"; Name = "Debugger"; Value = "%windir%\System32\taskkill.exe"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\AggregatorHost.exe";  Name = "Debugger"; Value = "%windir%\System32\taskkill.exe"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\DeviceCensus.exe";    Name = "Debugger"; Value = "%windir%\System32\taskkill.exe"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\FeatureLoader.exe";   Name = "Debugger"; Value = "%windir%\System32\taskkill.exe"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\BingChatInstaller.exe"; Name = "Debugger"; Value = "%windir%\System32\taskkill.exe"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\BGAUpsell.exe";        Name = "Debugger"; Value = "%windir%\System32\taskkill.exe"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\BCILauncher.exe";      Name = "Debugger"; Value = "%windir%\System32\taskkill.exe"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\SearchIndexer.exe\PerfOptions"; Name = "CpuPriorityClass"; Value = 5 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\ctfmon.exe\PerfOptions"; Name = "CpuPriorityClass"; Value = 5 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\fontdrvhost.exe\PerfOptions"; Name = "CpuPriorityClass"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\fontdrvhost.exe\PerfOptions"; Name = "IoPriority";      Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\lsass.exe\PerfOptions"; Name = "CpuPriorityClass"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\sihost.exe\PerfOptions"; Name = "CpuPriorityClass"; Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\sihost.exe\PerfOptions"; Name = "IoPriority";      Value = 0 }
    # game mitigation exemptions
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\vgc.exe";   Name = "MitigationOptions";     Value = ([byte[]](0x00,0x00,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\vgc.exe";   Name = "MitigationAuditOptions"; Value = ([byte[]](0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\vgc.exe";   Name = "EAFModules"; Value = ""; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\osu!.exe";  Name = "MitigationOptions";     Value = ([byte[]](0x00,0x00,0x21,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\osu!.exe";  Name = "MitigationAuditOptions"; Value = ([byte[]](0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\osu!.exe";  Name = "EAFModules"; Value = ""; Type = "String" }

    # ── monitor color management ──────────────────────────────────────────────
    # (applied per-monitor below, seeded here for reference)
    # ── kernel timer ─────────────────────────────────────────────────────────
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel"; Name = "GlobalTimerResolutionRequests"; Value = 1 }
)

foreach ($t in $tweaks) {
    if ($t) { Set-Reg -Path $t.Path -Name $t.Name -Value $t.Value -Type $(if ($t.Type) { $t.Type } else { "DWord" }) }
}

status "registry optimization complete." "done"

# ─────────────────────────────────────────────────────────────────────────────
# extended execution hooks
# ─────────────────────────────────────────────────────────────────────────────

# remove scheduled oobe updaters
try {
    Remove-Item "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate"  -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate"  -Recurse -Force -ErrorAction SilentlyContinue
} catch { }

# disable group-by in downloads folder
try {
    $dlKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FolderTypes\{885a186e-a440-4ada-812b-db871b942259}'
    Get-ChildItem $dlKey -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($p -and $p.GroupBy) { Set-ItemProperty $_.PSPath -Name GroupBy -Value '' -ErrorAction SilentlyContinue }
    }
} catch { }

# clear explorer bags for downloads
try {
    $bags = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags'
    if (Test-Path $bags) {
        Get-ChildItem $bags -ErrorAction SilentlyContinue | ForEach-Object {
            $sub = Join-Path $_.PSPath 'Shell\{885A186E-A440-4ADA-812B-DB871B942259}'
            if (Test-Path $sub) { Remove-Item $sub -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
} catch { }

# ─────────────────────────────────────────────────────────────────────────────
# services
# ─────────────────────────────────────────────────────────────────────────────

status "optimizing svchost split threshold..." "step"
Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Control" "SvcHostSplitThresholdInKB" 0xffffffff

status "disabling svchost process splitting..." "step"
Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services" -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        $img = (Get-ItemProperty $_.PSPath -Name "ImagePath" -ErrorAction SilentlyContinue).ImagePath
        if ($img -match "svchost\.exe") { Set-Reg $_.PSPath "SvcHostSplitDisable" 1 }
    } catch { }
}

status "configuring service startup types..." "step"
@(
    # telemetry and sync
    @{ Name = "DiagTrack"; Start = 4 }, @{ Name = "dmwappushservice"; Start = 4 },
    @{ Name = "Telemetry"; Start = 4 }, @{ Name = "diagnosticshub.standardcollector.service"; Start = 4 },
    @{ Name = "InventorySvc"; Start = 4 }, @{ Name = "CDPUserSvc"; Start = 4 },
    # diagnostics and error reporting
    @{ Name = "WerSvc"; Start = 4 }, @{ Name = "wercplsupport"; Start = 4 },
    @{ Name = "DPS"; Start = 4 }, @{ Name = "WdiServiceHost"; Start = 4 },
    @{ Name = "WdiSystemHost"; Start = 4 }, @{ Name = "troubleshootingsvc"; Start = 4 },
    @{ Name = "diagsvc"; Start = 4 }, @{ Name = "PcaSvc"; Start = 4 },
    # cloud and retail
    @{ Name = "RetailDemo"; Start = 4 }, @{ Name = "MapsBroker"; Start = 4 },
    @{ Name = "edgeupdate"; Start = 4 }, @{ Name = "Wecsvc"; Start = 4 },
    # system components
    @{ Name = "SysMain"; Start = 4 }, @{ Name = "wisvc"; Start = 4 },
    @{ Name = "svsvc"; Start = 4 }, @{ Name = "UCPD"; Start = 4 },
    @{ Name = "GraphicsPerfSvc"; Start = 4 }, @{ Name = "Ndu"; Start = 4 },
    @{ Name = "dusmsvc"; Start = 4 }, @{ Name = "DSSvc"; Start = 4 },
    @{ Name = "WSAIFabricSvc"; Start = 4 },
    # printing
    @{ Name = "Spooler"; Start = 4 }, @{ Name = "printworkflowusersvc"; Start = 4 },
    @{ Name = "stisvc"; Start = 4 }, @{ Name = "PrintNotify"; Start = 4 },
    @{ Name = "usbprint"; Start = 4 }, @{ Name = "PrintScanBrokerService"; Start = 4 },
    @{ Name = "PrintDeviceConfigurationService"; Start = 4 },
    # remote desktop
    @{ Name = "TermService"; Start = 4 }, @{ Name = "UmRdpService"; Start = 4 },
    @{ Name = "SessionEnv"; Start = 4 },
    # networking and energy
    @{ Name = "NetBT"; Start = 4 }, @{ Name = "tcpipreg"; Start = 4 },
    @{ Name = "GpuEnergyDrv"; Start = 4 },
    # hyper-v and virtualization
    @{ Name = "McpManagementService"; Start = 4 }, @{ Name = "bttflt"; Start = 4 },
    @{ Name = "gencounter"; Start = 4 }, @{ Name = "hyperkbd"; Start = 4 },
    @{ Name = "hypervideo"; Start = 4 }, @{ Name = "spaceparser"; Start = 4 },
    @{ Name = "storflt"; Start = 4 }, @{ Name = "vmgid"; Start = 4 },
    @{ Name = "vpci"; Start = 4 }, @{ Name = "vid"; Start = 4 },
    # miscellaneous
    @{ Name = "dam"; Start = 4 }, @{ Name = "CSC"; Start = 4 },
    @{ Name = "CSCSERVICE"; Start = 4 }, @{ Name = "condrv"; Start = 2 },
    @{ Name = "OneSyncSvc"; Start = 4 }, @{ Name = "TrkWks"; Start = 4 }
) | ForEach-Object {
    if (Get-Service $_.Name -ErrorAction SilentlyContinue) {
        $type = switch ($_.Start) { 2 { "Automatic" } 3 { "Manual" } 4 { "Disabled" } }
        Set-Service $_.Name -StartupType $type -ErrorAction SilentlyContinue
        Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Services\$($_.Name)" "Start" $_.Start
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# scheduled tasks
# ─────────────────────────────────────────────────────────────────────────────

status "disabling background system tasks..." "step"
@(
    "Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
    "Microsoft\Windows\Application Experience\ProgramDataUpdater",
    "Microsoft\Windows\Application Experience\StartupAppTask",
    "Microsoft\Windows\Application Experience\PcaPatchDbTask",
    "Microsoft\Windows\AppxDeploymentClient\UCPD Velocity",
    "Microsoft\Windows\Autochk\Proxy",
    "Microsoft\Windows\Customer Experience Improvement Program\Consolidator",
    "Microsoft\Windows\Customer Experience Improvement Program\UsbCeip",
    "Microsoft\Windows\Customer Experience Improvement Program\BthSQM",
    "Microsoft\Windows\Customer Experience Improvement Program\Uploader",
    "Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector",
    "Microsoft\Windows\ExploitGuard\ExploitGuard MDM Policy Refresh",
    "Microsoft\Windows\Windows Defender\Windows Defender Cache Maintenance",
    "Microsoft\Windows\Windows Defender\Windows Defender Cleanup",
    "Microsoft\Windows\Windows Defender\Windows Defender Scheduled Scan",
    "Microsoft\Windows\Windows Defender\Windows Defender Verification",
    "Microsoft\Windows\Flighting\FeatureConfig\UsageDataReporting",
    "Microsoft\Windows\Defrag\ScheduledDefrag",
    "Microsoft\Windows\Power Efficiency Diagnostics\AnalyzeSystem",
    "Microsoft\Windows\Feedback\Siuf\DmClient",
    "Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload"
) | ForEach-Object {
    Disable-ScheduledTask -TaskName ($_ -split "\\")[-1] -ErrorAction SilentlyContinue | Out-Null
}

# ─────────────────────────────────────────────────────────────────────────────
# post-optimization tweaks
# ─────────────────────────────────────────────────────────────────────────────

status "resetting capability consent storage..." "step"
Stop-Service 'camsvc' -Force -ErrorAction SilentlyContinue
Remove-Item "$env:ProgramData\Microsoft\Windows\CapabilityAccessManager\CapabilityConsentStorage.db*" -Force -ErrorAction SilentlyContinue

status "disabling memory compression and bitlocker..." "step"
Disable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue | Out-Null
Get-BitLockerVolume -ErrorAction SilentlyContinue | Where-Object { $_.ProtectionStatus -eq "On" } | Disable-BitLocker -ErrorAction SilentlyContinue | Out-Null

# ─────────────────────────────────────────────────────────────────────────────
# network optimization
# ─────────────────────────────────────────────────────────────────────────────

status "optimizing network stack..." "step"

& netsh int tcp set global autotuninglevel=restricted   2>&1 | Out-Null
& netsh int tcp set global ecncapability=disabled       2>&1 | Out-Null
& netsh int tcp set global timestamps=disabled          2>&1 | Out-Null
& netsh int tcp set global initialRto=2000              2>&1 | Out-Null
& netsh int tcp set global rss=enabled                  2>&1 | Out-Null
& netsh int tcp set global rsc=disabled                 2>&1 | Out-Null
& netsh int tcp set global nonsackrttresiliency=disabled 2>&1 | Out-Null

Disable-NetAdapterLso -Name "*" -IPv4 -ErrorAction SilentlyContinue | Out-Null
Set-NetAdapterAdvancedProperty -Name "*" -DisplayName "Interrupt Moderation" -DisplayValue "Disabled" -ErrorAction SilentlyContinue | Out-Null

'ms_lldp','ms_lltdio','ms_implat','ms_rspndr','ms_tcpip6','ms_server','ms_msclient','ms_pacer' | ForEach-Object {
    Disable-NetAdapterBinding -Name "*" -ComponentID $_ -ErrorAction SilentlyContinue | Out-Null
}

# nagle's algorithm — disabled per interface
Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces" -ErrorAction SilentlyContinue | ForEach-Object {
    Set-Reg $_.PSPath "TcpAckFrequency" 1
    Set-Reg $_.PSPath "TCPNoDelay"      1
}

# adapter power saving — disabled for all ethernet adapters
Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}" -ErrorAction SilentlyContinue | ForEach-Object {
    $p = $_.PSPath
    $hasDuplex = Get-ItemProperty $p -Name "*SpeedDuplex" -ErrorAction SilentlyContinue
    if ($hasDuplex -and -not (Get-ItemProperty $p -Name "*PhyType" -ErrorAction SilentlyContinue)) {
        "EnablePME","*DeviceSleepOnDisconnect","*EEE","AdvancedEEE","*SipsEnabled","EnableAspm","ASPM",
        "*ModernStandbyWoLMagicPacket","*SelectiveSuspend","EnableGigaLite","GigaLite",
        "*WakeOnMagicPacket","*WakeOnPattern","AutoPowerSaveModeEnabled","EEELinkAdvertisement",
        "EeePhyEnable","EnableGreenEthernet","EnableModernStandby","PowerDownPll","PowerSavingMode",
        "ReduceSpeedOnPowerDown","S5WakeOnLan","SavePowerNowEnabled","ULPMode","WakeOnLink",
        "WakeOnSlot","WakeOnLinkChg","WakeOnLinkUp","WakeUpModeCap","*NicAutoPowerSaver",
        "PowerSaveEnable","EnablePowerManagement","ForceWakeFromMagicPacketOnModernStandby",
        "WakeFromS5","WakeOn","EnableSavePowerNow","*EnableDynamicPowerGating","DynamicPowerGating",
        "EnableD3ColdInS0","WakeFromPowerOff","LogLinkStateEvent" | ForEach-Object {
            if (Get-ItemProperty $p -Name $_ -ErrorAction SilentlyContinue) { Set-Reg $p $_ "0" "String" }
        }
        if (Get-ItemProperty $p -Name "PnPCapabilities"        -ErrorAction SilentlyContinue) { Set-Reg $p "PnPCapabilities" 24 }
        if (Get-ItemProperty $p -Name "WakeOnMagicPacketFromS5" -ErrorAction SilentlyContinue) { Set-Reg $p "WakeOnMagicPacketFromS5" "2" "String" }
        if (Get-ItemProperty $p -Name "WolShutdownLinkSpeed"   -ErrorAction SilentlyContinue) { Set-Reg $p "WolShutdownLinkSpeed" "2" "String" }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# focus assist — priority-only blob injection
# ─────────────────────────────────────────────────────────────────────────────

status "injecting focus assist priority-only profile..." "step"
$priorityBlob = [byte[]](0x43,0x42,0x01,0x00,0x0A,0x02,0x01,0x00,0x2A,0x06,0xDF,0xB8,0xB4,0xCC,0x06,0x2A,0x2B,0x0E,0xD0,0x03,0x43,0x42,0x01,0x00,0xC2,0x0A,0x01,0xCD,0x14,0x06,0x02,0x05,0x00,0x00,0x01,0x01,0x02,0x00,0x03,0x01,0x04,0x00,0xCC,0x32,0x12,0x05,0x28,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x53,0x00,0x63,0x00,0x72,0x00,0x65,0x00,0x65,0x00,0x6E,0x00,0x53,0x00,0x6B,0x00,0x65,0x00,0x74,0x00,0x63,0x00,0x68,0x00,0x5F,0x00,0x38,0x00,0x77,0x00,0x65,0x00,0x6B,0x00,0x79,0x00,0x62,0x00,0x33,0x00,0x64,0x00,0x38,0x00,0x62,0x00,0x62,0x00,0x77,0x00,0x65,0x00,0x21,0x00,0x41,0x00,0x70,0x00,0x70,0x00,0x29,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x57,0x00,0x69,0x00,0x6E,0x00,0x64,0x00,0x6F,0x00,0x77,0x00,0x73,0x00,0x41,0x00,0x6C,0x00,0x61,0x00,0x72,0x00,0x6D,0x00,0x73,0x00,0x5F,0x00,0x38,0x00,0x77,0x00,0x65,0x00,0x6B,0x00,0x79,0x00,0x62,0x00,0x33,0x00,0x64,0x00,0x38,0x00,0x62,0x00,0x62,0x00,0x77,0x00,0x65,0x00,0x21,0x00,0x41,0x00,0x70,0x00,0x70,0x00,0x31,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x58,0x00,0x62,0x00,0x6F,0x00,0x78,0x00,0x41,0x00,0x70,0x00,0x70,0x00,0x5F,0x00,0x38,0x00,0x77,0x00,0x65,0x00,0x6B,0x00,0x79,0x00,0x62,0x00,0x33,0x00,0x64,0x00,0x38,0x00,0x62,0x00,0x62,0x00,0x77,0x00,0x65,0x00,0x21,0x00,0x41,0x00,0x70,0x00,0x70,0x00,0x2D,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x58,0x00,0x62,0x00,0x6F,0x00,0x78,0x00,0x47,0x00,0x61,0x00,0x6D,0x00,0x69,0x00,0x6E,0x00,0x67,0x00,0x4F,0x00,0x76,0x00,0x65,0x00,0x72,0x00,0x6C,0x00,0x61,0x00,0x79,0x00,0x5F,0x00,0x38,0x00,0x77,0x00,0x65,0x00,0x6B,0x00,0x79,0x00,0x62,0x00,0x33,0x00,0x64,0x00,0x38,0x00,0x62,0x00,0x62,0x00,0x77,0x00,0x65,0x00,0x21,0x00,0x41,0x00,0x70,0x00,0x70,0x00,0x29,0x57,0x00,0x69,0x00,0x6E,0x00,0x64,0x00,0x6F,0x00,0x77,0x00,0x73,0x00,0x2E,0x00,0x53,0x00,0x79,0x00,0x73,0x00,0x74,0x00,0x65,0x00,0x6D,0x00,0x2E,0x00,0x4E,0x00,0x65,0x00,0x61,0x00,0x72,0x00,0x53,0x00,0x68,0x00,0x61,0x00,0x72,0x00,0x65,0x00,0x45,0x00,0x78,0x00,0x70,0x00,0x65,0x00,0x72,0x00,0x69,0x00,0x65,0x00,0x6E,0x00,0x63,0x00,0x65,0x00,0x52,0x00,0x65,0x00,0x63,0x00,0x65,0x00,0x69,0x00,0x76,0x00,0x65,0x00,0x00,0x00,0x00,0x00)

Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current" -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match '^\{[a-f0-9-]+\}\$' } | ForEach-Object {
        $guid = ($_.PSChildName -split '\$')[0]
        $targ = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\$guid`$windows.data.donotdisturb.quiethoursprofile`$quiethoursprofilelist\windows.data.donotdisturb.quiethoursprofile`$microsoft.quiethoursprofile.priorityonly"
        Set-Reg $targ "Data" $priorityBlob "Binary"
    }

# ─────────────────────────────────────────────────────────────────────────────
# windows client hive optimization
# ─────────────────────────────────────────────────────────────────────────────

status "optimizing windows client session apps..." "step"
"AppActions","CrossDeviceResume","DesktopStickerEditorWin32Exe","DiscoveryHubApp","FESearchHost",
"SearchHost","SoftLandingTask","TextInputHost","VisualAssistExe","WebExperienceHostApp",
"WindowsBackupClient","WindowsMigration","ShellExperienceHost","StartMenuExperienceHost",
"Widgets","WidgetService","MiniSearchHost" | ForEach-Object { Stop-Process $_ -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1

$settingsDat = "$env:LOCALAPPDATA\Packages\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\Settings\settings.dat"
if (Test-Path $settingsDat) {
    cmd /c "reg load `"HKLM\Settings`" `"$settingsDat`" 2>nul"
    if ($LASTEXITCODE -eq 0) {
        $state = "HKLM:\Settings\LocalState"
        $ts    = [byte[]](0x01,0x61,0xed,0x11,0x34,0xf7,0x9f,0xdc,0x01)
        Set-Reg "$state\DisabledApps" "Microsoft.Paint_8wekyb3d8bbwe"            $ts "Binary"
        Set-Reg "$state\DisabledApps" "Microsoft.Windows.Photos_8wekyb3d8bbwe"   $ts "Binary"
        Set-Reg "$state\DisabledApps" "MicrosoftWindows.Client.CBS_cw5n1h2txyewy" $ts "Binary"
        Set-Reg $state "VideoAutoplay"              ([byte[]](0x00,0x96,0x9d,0x69,0x8d,0xcd,0x93,0xdc,0x01)) "Binary"
        Set-Reg $state "EnableAppInstallNotifications" ([byte[]](0x00,0x36,0xd0,0x88,0x8e,0xcd,0x93,0xdc,0x01)) "Binary"
        Set-Reg "$state\PersistentSettings" "PersonalizationEnabled" ([byte[]](0x00,0x0d,0x56,0xa1,0x8a,0xcd,0x93,0xdc,0x01)) "Binary"
        [GC]::Collect(); Start-Sleep -Seconds 1
        reg unload "HKLM\Settings" 2>$null | Out-Null
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# power plan — albus
# ─────────────────────────────────────────────────────────────────────────────

status "deploying albus power plan..." "step"

$saverGuid = "a1841308-3541-4fab-bc81-f71556f20b4a"
& powercfg -restoredefaultschemes 2>&1 | Out-Null
& powercfg /SETACTIVE $saverGuid     2>&1 | Out-Null

$out = & powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61
$albusGuid = if ($out -match '([0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})') { $Matches[1] } else {
    $g = "99999999-9999-9999-9999-999999999999"
    & powercfg /delete $g 2>&1 | Out-Null
    & powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 $g 2>&1 | Out-Null
    $g
}
& powercfg /changename $albusGuid "Albus" "optimized for minimal latency, deep unparking, and peak hardware throughput." 2>&1 | Out-Null

# delete other plans
(& powercfg /l 2>$null | Out-String) -split "`r?`n" | ForEach-Object {
    if ($_ -match ':') {
        $parts = $_ -split ':'
        if ($parts.Count -gt 1) {
            $idx  = $parts[1].Trim().IndexOf('(')
            if ($idx -gt 0) {
                $guid = $parts[1].Trim().Substring(0, $idx).Trim()
                if ($guid -ne $albusGuid -and $guid -ne $saverGuid -and $guid.Length -ge 36) {
                    & powercfg /delete $guid 2>&1 | Out-Null
                }
            }
        }
    }
}

# power settings
@(
    "0012ee47-9041-4b5d-9b77-535fba8b1442 6738e2c4-e8a5-4a42-b16a-e040e769756e 0",
    "0d7dbae2-4294-402a-ba8e-26777e8488cd 309dce9b-bef4-4119-9921-a851fb12f0f4 1",
    "19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0",
    "238c9fa8-0aad-41ed-83f4-97be242c8f20 29f6c1db-86da-48c5-9fdb-f2b67b1f44da 0",
    "238c9fa8-0aad-41ed-83f4-97be242c8f20 94ac6d29-73ce-41a6-809f-6363ba21b47e 0",
    "238c9fa8-0aad-41ed-83f4-97be242c8f20 9d7815a6-7ee4-497e-8888-515a05f02364 0",
    "238c9fa8-0aad-41ed-83f4-97be242c8f20 bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d 0",
    "2a737441-1930-4402-8d77-b2bebba308a3 0853a681-27c8-4100-a2fd-82013e970683 0",
    "2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0",
    "2a737441-1930-4402-8d77-b2bebba308a3 d4e98f31-5ffe-4ce1-be31-1b38b384c009 0",
    "4f971e89-eebd-4455-a8de-9e59040e7347 a7066653-8d6c-40a8-910e-a1f54b84c7e5 2",
    "501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0",
    "54533251-82be-4824-96c1-47b60b740d00 893dee8e-2bef-41e0-89c6-b55d0929964c 100",
    "54533251-82be-4824-96c1-47b60b740d00 94d3a615-a899-4ac5-ae2b-e4d8f634367f 1",
    "54533251-82be-4824-96c1-47b60b740d00 bc5038f7-23e0-4960-96da-33abaf5935ec 100",
    "54533251-82be-4824-96c1-47b60b740d00 0cc5b647-c1df-4637-891a-dec35c318583 100",
    "54533251-82be-4824-96c1-47b60b740d00 ea062031-0e34-4ff1-9b6d-eb1059334028 100",
    "54533251-82be-4824-96c1-47b60b740d00 36687f9e-e3a5-4dbf-b1dc-15eb381c6863 0",
    "54533251-82be-4824-96c1-47b60b740d00 93b8b6dc-0698-4d1c-9ee4-0644e900c85d 0",
    "54533251-82be-4824-96c1-47b60b740d00 75b0ae3f-bce0-45a7-8c89-c9611c25e100 0",
    "7516b95f-f776-4464-8c53-06167f40cc99 3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e 600",
    "7516b95f-f776-4464-8c53-06167f40cc99 aded5e82-b909-4619-9949-f5d71dac0bcb 100",
    "7516b95f-f776-4464-8c53-06167f40cc99 f1fbfde2-a960-4165-9f88-50667911ce96 100",
    "7516b95f-f776-4464-8c53-06167f40cc99 fbd9aa66-9553-4097-ba44-ed6e9d65eab8 0",
    "9596fb26-9850-41fd-ac3e-f7c3c00afd4b 10778347-1370-4ee0-8bbd-33bdacaade49 1",
    "9596fb26-9850-41fd-ac3e-f7c3c00afd4b 34c7b99f-9a6d-4b3c-8dc7-b6693b78cef4 0",
    "e276e160-7cb0-43c6-b20b-73f5dce39954 a1662ab2-9d34-4e53-ba8b-2639b9e20857 3",
    "e73a048d-bf27-4f12-9731-8b2076e8891f 5dbb7c9f-38e9-40d2-9749-4f8a0e9f640f 0",
    "e73a048d-bf27-4f12-9731-8b2076e8891f 637ea02f-bbcb-4015-8e2c-a1c7b9c0b546 0",
    "e73a048d-bf27-4f12-9731-8b2076e8891f 8183ba9a-e910-48da-8769-14ae6dc1170a 0",
    "e73a048d-bf27-4f12-9731-8b2076e8891f 9a66d8d7-4ff7-4ef9-b5a2-5a326ca2a469 0",
    "e73a048d-bf27-4f12-9731-8b2076e8891f bcded951-187b-4d05-bccc-f7e51960c258 0",
    "e73a048d-bf27-4f12-9731-8b2076e8891f d8742dcb-3e6a-4b3c-b3fe-374623cdcf06 0",
    "e73a048d-bf27-4f12-9731-8b2076e8891f f3c5027d-cd16-4930-aa6b-90db844a8f00 0",
    "de830923-a562-41af-a086-e3a2c6bad2da 13d09884-f74e-474a-a852-b6bde8ad03a8 100",
    "de830923-a562-41af-a086-e3a2c6bad2da e69653ca-cf7f-4f05-aa73-cb833fa90ad4 0"
) | ForEach-Object {
    if ($_ -match '(?<s>[a-f0-9-]+)\s+(?<i>[a-f0-9-]+)\s+(?<v>\d+)') {
        $s = $Matches.s; $i = $Matches.i; $v = $Matches.v
        & powercfg /attributes $s $i -ATTRIB_HIDE 2>$null | Out-Null
        & { trap { continue }
            powercfg /setacvalueindex $albusGuid $s $i $v 2>$null | Out-Null
            powercfg /setdcvalueindex $albusGuid $s $i $v 2>$null | Out-Null
        }
    }
}

& powercfg /SETACTIVE $albusGuid 2>&1 | Out-Null

# hibernate and throttling
& powercfg /hibernate off 2>$null | Out-Null
@(
    "HKLM:\SYSTEM\CurrentControlSet\Control\Power|HibernateEnabled|0",
    "HKLM:\SYSTEM\CurrentControlSet\Control\Power|HibernateEnabledDefault|0",
    "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power|HiberbootEnabled|0",
    "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling|PowerThrottlingOff|1",
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings|ShowLockOption|0",
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings|ShowSleepOption|0"
) | ForEach-Object { $p = $_ -split '\|'; Set-Reg $p[0] $p[1] $p[2] }

# auto color management per monitor
Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\MonitorDataStore" -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    Set-Reg $_.PSPath "AutoColorManagementEnabled" 0
}

# ─────────────────────────────────────────────────────────────────────────────
# albusx native service
# ─────────────────────────────────────────────────────────────────────────────

status "deploying albusx core engine..." "step"

$svcName = "AlbusXSvc"
$exePath = "$env:SystemRoot\AlbusX.exe"
$csPath  = "$env:SystemRoot\AlbusX.cs"
$csc     = "$env:windir\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$csUrl   = "https://raw.githubusercontent.com/oqullcan/albuswin/refs/heads/main/albus/AlbusX.cs"

# clean previous deployment
if (Get-Service $svcName -ErrorAction SilentlyContinue) {
    Stop-Service $svcName -Force -ErrorAction SilentlyContinue
    sc.exe delete $svcName >$null 2>&1
}
if (Test-Path $exePath) { Remove-Item $exePath -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1

# fetch and compile
try { Invoke-WebRequest $csUrl -OutFile $csPath -UseBasicParsing -ErrorAction Stop } catch { }

if ((Test-Path $csPath) -and (Test-Path $csc)) {
    & $csc -r:System.ServiceProcess.dll -r:System.Configuration.Install.dll -r:System.Management.dll -out:"$exePath" "$csPath" >$null 2>&1
    Remove-Item $csPath -Force -ErrorAction SilentlyContinue
}

# install and start
if (Test-Path $exePath) {
    New-Service -Name $svcName -BinaryPathName $exePath -DisplayName "AlbusX" `
        -Description "albus core engine — timer resolution, audio latency, memory management, interrupt affinity, game profiles" `
        -StartupType Automatic -ErrorAction SilentlyContinue | Out-Null
    sc.exe failure $svcName reset= 60 actions= restart/5000/restart/10000/restart/30000 >$null 2>&1
    Start-Service $svcName -ErrorAction SilentlyContinue | Out-Null
    status "albusx service active." "done"
} else {
    status "albusx compilation failed — engine not deployed." "warn"
}

# ─────────────────────────────────────────────────────────────────────────────
# exploit guard mitigations
# ─────────────────────────────────────────────────────────────────────────────

status "disabling system-wide exploit guard mitigations..." "step"
(Get-Command 'Set-ProcessMitigation' -ErrorAction SilentlyContinue)?.Parameters['Disable']?.Attributes?.ValidValues | ForEach-Object {
    Set-ProcessMitigation -SYSTEM -Disable $_.ToString() -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
}

# inject mitigation bypass payload to core processes
status "applying mitigation bypass to core processes..." "step"
$kernelPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Kernel"
$auditVal   = Get-ItemProperty $kernelPath -Name "MitigationAuditOptions" -ErrorAction SilentlyContinue
$len        = if ($auditVal?.MitigationAuditOptions) { $auditVal.MitigationAuditOptions.Length } else { 38 }
[byte[]]$payload = [System.Linq.Enumerable]::Repeat([byte]34, $len)

"fontdrvhost.exe","dwm.exe","lsass.exe","svchost.exe","WmiPrvSE.exe","winlogon.exe",
"csrss.exe","audiodg.exe","ntoskrnl.exe","services.exe","explorer.exe","taskhostw.exe","sihost.exe" | ForEach-Object {
    $p = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$_"
    Set-Reg $p "MitigationOptions"     $payload "Binary"
    Set-Reg $p "MitigationAuditOptions" $payload "Binary"
}
Set-Reg $kernelPath "MitigationOptions"     $payload "Binary"
Set-Reg $kernelPath "MitigationAuditOptions" $payload "Binary"

# intel tsx
status "optimizing intel tsx..." "step"
if ((Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue).Manufacturer -eq 'GenuineIntel') {
    Set-Reg $kernelPath "DisableTSX" 0
} else {
    Remove-ItemProperty $kernelPath -Name "DisableTSX" -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────────────────
# hardware cleanup and optimization
# ─────────────────────────────────────────────────────────────────────────────

# ghost device cleanup
status "removing ghost pnp devices..." "step"
Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { -not $_.Present -and $_.InstanceId -notmatch '^(ROOT|SWD|HTREE|DISPLAY|BTHENUM)\\' } | ForEach-Object {
    pnputil /remove-device $_.InstanceId /quiet >$null 2>&1
}

# disk write cache
status "optimizing disk write cache..." "step"
Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceType -ne "USB" -and $_.PNPDeviceID } | ForEach-Object {
    $p = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($_.PNPDeviceID)\Device Parameters\Disk"
    Set-Reg $p "UserWriteCacheSetting" 1
    Set-Reg $p "CacheIsPowerProtected" 1
}

# device power saving
status "disabling device power saving..." "step"
Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.Status -match 'OK|Unknown' } | ForEach-Object {
    $inst = $_.InstanceId
    $dp   = "HKLM:\SYSTEM\CurrentControlSet\Enum\$inst\Device Parameters"
    Set-Reg "$dp\WDF" "IdleInWorkingState" 0
    "SelectiveSuspendEnabled","SelectiveSuspendOn","EnhancedPowerManagementEnabled","WaitWakeEnabled" | ForEach-Object {
        Set-Reg $dp $_ 0
    }
    Get-WmiObject -Class MSPower_DeviceEnable -Namespace root\wmi -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceName -like "*$($inst.Replace('\','\\'))*" } | ForEach-Object {
            $_.Enable = $false; $_.Put() | Out-Null
        }
}

# dma remapping
status "optimizing dma remapping..." "step"
Set-Reg "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\DmaGuard\DeviceEnumerationPolicy" "value" 2
Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services" -ErrorAction SilentlyContinue | ForEach-Object {
    $p = "$($_.Name.Replace('HKEY_LOCAL_MACHINE','HKLM'))\Parameters"
    if (Get-ItemProperty $p -Name "DmaRemappingCompatible" -ErrorAction SilentlyContinue) {
        Set-Reg $p "DmaRemappingCompatible" 0
    }
}

# msi mode for pci devices
status "enabling msi mode for pci devices..." "step"
Get-PnpDevice -InstanceId "PCI\*" -ErrorAction SilentlyContinue | Where-Object { $_.Status -match 'OK|Unknown' } | ForEach-Object {
    if ($_.InstanceId) {
        $p = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($_.InstanceId)\Device Parameters\Interrupt Management"
        Set-Reg "$p\MessageSignaledInterruptProperties" "MSISupported" 1
        if (Test-Path "$p\Affinity Policy") { Remove-ItemProperty "$p\Affinity Policy" -Name "DevicePriority" -ErrorAction SilentlyContinue }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# winevt — disable diagnostic channels
# ─────────────────────────────────────────────────────────────────────────────

status "disabling winevt diagnostic channels..." "step"
try {
    Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WINEVT\Channels' -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $ep = Get-ItemProperty $_.PSPath -Name 'Enabled' -ErrorAction SilentlyContinue
            if ($ep -and $ep.Enabled -eq 1) { Set-ItemProperty $_.PSPath -Name 'Enabled' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue }
        } catch { }
    }
} catch { }

# ─────────────────────────────────────────────────────────────────────────────
# ntfs and bcdedit
# ─────────────────────────────────────────────────────────────────────────────

status "optimizing ntfs behaviors..." "step"
& fsutil behavior set disable8dot3     1 2>&1 | Out-Null
& fsutil behavior set disabledeletenotify 0 2>&1 | Out-Null
& fsutil behavior set disablelastaccess  1 2>&1 | Out-Null
& fsutil behavior set encryptpagingfile  0 2>&1 | Out-Null

status "applying bcdedit optimizations..." "step"
& bcdedit /deletevalue useplatformclock 2>&1 | Out-Null
& bcdedit /deletevalue useplatformtick  2>&1 | Out-Null
& bcdedit /set bootmenupolicy legacy    2>&1 | Out-Null
& bcdedit /timeout 10                   2>&1 | Out-Null
& label C: Albus                        2>&1 | Out-Null
& bcdedit /set "{current}" description "Albus Playbook v2" 2>&1 | Out-Null

# ─────────────────────────────────────────────────────────────────────────────
# ui and shell — true black theme
# ─────────────────────────────────────────────────────────────────────────────

status "applying true black ui and shell settings..." "step"

# black wallpaper and lock screen
Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction SilentlyContinue
$sw = [System.Windows.Forms.SystemInformation]::PrimaryMonitorSize.Width
$sh = [System.Windows.Forms.SystemInformation]::PrimaryMonitorSize.Height
$wallpaperFile = "C:\Windows\Wallpaper.jpg"
if (-not (Test-Path $wallpaperFile)) {
    try {
        $bmp = New-Object System.Drawing.Bitmap $sw, $sh
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        $gfx.FillRectangle([System.Drawing.Brushes]::Black, 0, 0, $sw, $sh)
        $gfx.Dispose(); $bmp.Save($wallpaperFile); $bmp.Dispose()
    } catch { }
}
Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers" "BackgroundType" 1
Set-Reg "HKCU:\Control Panel\Colors"  "Background" "0 0 0" "String"
Set-Reg "HKCU:\Control Panel\Desktop" "WallPaper"  ""      "String"

# dark mode
Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" "AppsUseLightTheme"     0
Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" "SystemUsesLightTheme"  0
Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" "EnableTransparency"    0
Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" "ColorPrevalence"       1

# accent color — black
Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Accent" "AccentColorMenu" 0
Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Accent" "StartColorMenu"  0
Set-Reg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Accent" "AccentPalette" ([byte[]](0x64,0x64,0x64,0x00,0x6b,0x6b,0x6b,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00)) "Binary"
Set-Reg "HKCU:\Software\Microsoft\Windows\DWM" "AccentColor"          -15132391
Set-Reg "HKCU:\Software\Microsoft\Windows\DWM" "ColorizationAfterglow" -1004988135
Set-Reg "HKCU:\Software\Microsoft\Windows\DWM" "ColorizationColor"     -1004988135
Set-Reg "HKCU:\Software\Microsoft\Windows\DWM" "EnableWindowColorization" 1

# lock screen
Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP" "LockScreenImagePath"   $wallpaperFile "String"
Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP" "LockScreenImageStatus" 1

rundll32.exe user32.dll, UpdatePerUserSystemParameters

# force all tray icons visible
Get-ChildItem 'HKCU:\Control Panel\NotifyIconSettings' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    Set-ItemProperty $_.PSPath -Name 'IsPromoted' -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
}

# blackout account pictures
$picPaths = @("$env:SystemDrive\ProgramData\Microsoft\User Account Pictures", "$env:AppData\Microsoft\Windows\AccountPictures")
foreach ($path in $picPaths) {
    if (-not (Test-Path $path)) { continue }
    if ($path -match "ProgramData") {
        $backup = "$env:SystemDrive\ProgramData\User_Account_Pictures_Backup"
        if (-not (Test-Path $backup)) { Copy-Item $path $backup -Recurse -Force -ErrorAction SilentlyContinue | Out-Null }
    }
    Get-ChildItem $path -Include *.png,*.bmp,*.jpg -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $img = [System.Drawing.Bitmap]::FromFile($_.FullName)
            $w = $img.Width; $h = $img.Height; $img.Dispose()
            $new = New-Object System.Drawing.Bitmap $w, $h
            $g   = [System.Drawing.Graphics]::FromImage($new)
            $g.Clear([System.Drawing.Color]::Black); $g.Dispose()
            $fmt = switch ($_.Extension.ToLower()) {
                ".png" { [System.Drawing.Imaging.ImageFormat]::Png }
                ".bmp" { [System.Drawing.Imaging.ImageFormat]::Bmp }
                default { [System.Drawing.Imaging.ImageFormat]::Jpeg }
            }
            $new.Save($_.FullName, $fmt); $new.Dispose()
        } catch { }
    }
}

# unpin taskbar
Set-Reg "-HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband" "" ""
Remove-Item "$env:USERPROFILE\AppData\Roaming\Microsoft\Internet Explorer\Quick Launch" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null

# context menu debloat
@(
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoCustomizeThisFolder"; Value = 1 },
    @{ Path = "-HKCR:\Folder\shell\pintohome"; Name = ""; Value = "" },
    @{ Path = "-HKCR:\*\shell\pintohomefile"; Name = ""; Value = "" },
    @{ Path = "-HKCR:\exefile\shellex\ContextMenuHandlers\Compatibility"; Name = ""; Value = "" },
    @{ Path = "-HKCR:\Folder\ShellEx\ContextMenuHandlers\Library Location"; Name = ""; Value = "" },
    @{ Path = "-HKCR:\AllFilesystemObjects\shellex\ContextMenuHandlers\ModernSharing"; Name = ""; Value = "" },
    @{ Path = "-HKCR:\AllFilesystemObjects\shellex\ContextMenuHandlers\SendTo"; Name = ""; Value = "" },
    @{ Path = "-HKCR:\UserLibraryFolder\shellex\ContextMenuHandlers\SendTo"; Name = ""; Value = "" },
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer"; Name = "NoPreviousVersionsPage"; Value = 1 },
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked"; Name = "{9F156763-7844-4DC4-B2B1-901F640F5155}"; Value = ""; Type = "String" },
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked"; Name = "{09A47860-11B0-4DA5-AFA5-26D86198A780}"; Value = ""; Type = "String" },
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked"; Name = "{f81e9010-6ea4-11ce-a7ff-00aa003ca9f6}"; Value = ""; Type = "String" }
) | ForEach-Object { Set-Reg $_.Path $_.Name $_.Value $(if ($_.Type) { $_.Type } else { "DWord" }) }

# start menu reset
if ([Environment]::OSVersion.Version.Build -lt 22000) {
    # windows 10
    $layoutXml = 'C:\Windows\StartMenuLayout.xml'
    @"
<LayoutModificationTemplate xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" Version="1" xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification">
    <LayoutOptions StartTileGroupCellWidth="6" />
    <DefaultLayoutOverride><StartLayoutCollection><defaultlayout:StartLayout GroupCellWidth="6" /></StartLayoutCollection></DefaultLayoutOverride>
</LayoutModificationTemplate>
"@ | Set-Content $layoutXml -Force -Encoding ASCII
    foreach ($hive in @("HKLM","HKCU")) {
        $p = "${hive}:\SOFTWARE\Policies\Microsoft\Windows\Explorer"
        if (-not (Test-Path $p)) { New-Item $p -Force | Out-Null }
        Set-ItemProperty $p "LockedStartLayout" 1 -Force
        Set-ItemProperty $p "StartLayoutFile"   $layoutXml -Force
    }
    Stop-Process -Force -Name explorer -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    foreach ($hive in @("HKLM","HKCU")) { Set-ItemProperty "${hive}:\SOFTWARE\Policies\Microsoft\Windows\Explorer" "LockedStartLayout" 0 -Force }
    Remove-Item $layoutXml -Force -ErrorAction SilentlyContinue
} else {
    # windows 11
    $start2 = "$env:USERPROFILE\AppData\Local\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState\start2.bin"
    Remove-Item $start2 -Force -ErrorAction SilentlyContinue | Out-Null
    [System.IO.File]::WriteAllBytes($start2, [Convert]::FromBase64String("AgAAABAAAAD9////AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="))
    Stop-Process -Force -Name explorer -ErrorAction SilentlyContinue
}

# recycle bin start menu shortcut
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut("$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Recycle Bin.lnk")
$sc.TargetPath = '::{645ff040-5081-101b-9f08-00aa002f954e}'
$sc.Save()

# hide accessibility folders
@("$env:UserProfile\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Accessibility",
  "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Accessibility",
  "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Accessories") | ForEach-Object {
    if (Test-Path $_) { attrib +h "$_" /s /d >$null 2>&1 }
}

# ─────────────────────────────────────────────────────────────────────────────
# debloat — uwp, capabilities, features
# ─────────────────────────────────────────────────────────────────────────────

status "removing system bloat..." "step"

$keepUwp = @('*CBS*','*AV1VideoExtension*','*AVCEncoderVideoExtension*','*HEIFImageExtension*',
    '*HEVCVideoExtension*','*MPEG2VideoExtension*','*Paint*','*RawImageExtension*',
    '*SecHealthUI*','*VP9VideoExtensions*','*WebMediaExtensions*','*WebpImageExtension*',
    '*Windows.Photos*','*ShellExperienceHost*','*StartMenuExperienceHost*',
    '*WindowsNotepad*','*WindowsStore*','*immersivecontrolpanel*')

Get-AppxPackage -AllUsers | Where-Object {
    $n = $_.Name
    -not ($keepUwp | Where-Object { $n -like $_ })
} | ForEach-Object {
    try { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop | Out-Null } catch { }
}

try {
    Get-WindowsCapability -Online -ErrorAction Stop | Where-Object {
        $_.State -eq 'Installed' -and
        $_.Name -notmatch 'Ethernet|MSPaint|Notepad|Wifi|NetFX3|VBSCRIPT|WMIC|ShellComponents'
    } | ForEach-Object { try { Remove-WindowsCapability -Online -Name $_.Name -ErrorAction SilentlyContinue | Out-Null } catch { } }
} catch { }

try {
    Get-WindowsOptionalFeature -Online -ErrorAction Stop | Where-Object {
        $_.State -eq 'Enabled' -and
        $_.FeatureName -notmatch 'DirectPlay|LegacyComponents|NetFx|SearchEngine-Client|Server-Shell|Windows-Defender|Drivers-General|Server-Gui-Mgmt|WirelessNetworking'
    } | ForEach-Object { try { Disable-WindowsOptionalFeature -Online -FeatureName $_.FeatureName -NoRestart -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Out-Null } catch { } }
} catch { }

# ─────────────────────────────────────────────────────────────────────────────
# edge, onedrive, health tools, legacy apps
# ─────────────────────────────────────────────────────────────────────────────

status "uninstalling edge, onedrive, and legacy apps..." "step"

# region spoof (us) to bypass install restrictions
$oldRegion = Get-ItemPropertyValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Control Panel\DeviceRegion' -Name DeviceRegion -ErrorAction SilentlyContinue
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Control Panel\DeviceRegion' -Name DeviceRegion -Value 244 -Force -ErrorAction SilentlyContinue

# kill edge processes
"backgroundTaskHost","Copilot","CrossDeviceResume","GameBar","MicrosoftEdgeUpdate",
"msedge","msedgewebview2","OneDrive","OneDrive.Sync.Service","OneDriveStandaloneUpdater",
"Resume","RuntimeBroker","Search","SearchHost","Setup","StoreDesktopExtension",
"WidgetService","Widgets" | ForEach-Object { Stop-Process $_ -Force -ErrorAction SilentlyContinue }
Get-Process | Where-Object { $_.ProcessName -like "*edge*" } | Stop-Process -Force -ErrorAction SilentlyContinue

# registry cleanup
"HKCU:\SOFTWARE","HKLM:\SOFTWARE","HKCU:\SOFTWARE\Policies","HKLM:\SOFTWARE\Policies",
"HKCU:\SOFTWARE\WOW6432Node","HKLM:\SOFTWARE\WOW6432Node",
"HKCU:\SOFTWARE\WOW6432Node\Policies","HKLM:\SOFTWARE\WOW6432Node\Policies" | ForEach-Object {
    Remove-Item "$_\Microsoft\EdgeUpdate" -Recurse -Force -ErrorAction SilentlyContinue
}

# uninstall edge update services
"LocalApplicationData","ProgramFilesX86","ProgramFiles" | ForEach-Object {
    Get-ChildItem "$([Environment]::GetFolderPath($_))\Microsoft\EdgeUpdate\*.*.*.*\MicrosoftEdgeUpdate.exe" -Recurse -ErrorAction SilentlyContinue
} | ForEach-Object {
    if (Test-Path $_) {
        Start-Process -Wait $_ -ArgumentList "/unregsvc" -WindowStyle Hidden
        Start-Process -Wait $_ -ArgumentList "/uninstall" -WindowStyle Hidden
    }
}

# force uninstall via registry
try {
    $key = Get-Item "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge" -ErrorAction SilentlyContinue
    if ($key) { Start-Process cmd.exe -ArgumentList "/c $($key.GetValue('UninstallString')) --force-uninstall" -WindowStyle Hidden -Wait }
} catch { }

# leftover cleanup
@("$env:SystemRoot\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe",
  "$env:ProgramFiles (x86)\Microsoft",
  "$env:SystemDrive\Windows\System32\config\systemprofile\AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\Microsoft Edge.lnk") | ForEach-Object {
    if (Test-Path $_) { Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue }
}
Get-Service | Where-Object { $_.Name -match 'Edge' } | ForEach-Object {
    sc.exe stop $_.Name >$null 2>&1; sc.exe delete $_.Name >$null 2>&1
}

# windows 10 legacy edge (dism)
$legacyEdge = (Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages" -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -like "*Microsoft-Windows-Internet-Browser-Package*~~*" }).PSChildName
if ($legacyEdge) {
    $lp = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages\$legacyEdge"
    Set-Reg $lp "Visibility" 1
    $op = "$lp\Owners"
    if (Test-Path $op) { Remove-Item $op -Recurse -Force -ErrorAction SilentlyContinue | Out-Null }
    dism.exe /online /Remove-Package /PackageName:$legacyEdge /quiet /norestart >$null 2>&1
}

# revert region
if ($oldRegion) { Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Control Panel\DeviceRegion' -Name DeviceRegion -Value $oldRegion -Force -ErrorAction SilentlyContinue }
