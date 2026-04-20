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

pause
