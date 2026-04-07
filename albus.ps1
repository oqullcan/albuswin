# =============================================================================================================================================================================

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$Privilege = $Identity.Split('\')[-1]
[Console]::Title = "Albus Playbook - $Privilege"

function Status ($Msg, $Type = "info") {
    $P, $C = switch ($Type) {
        "info"    { "info", "Cyan" }
        "done"    { "done", "Green" }
        "warn"    { "warn", "Yellow" }
        "fail"    { "fail", "Red" }
        "step"    { "step", "Magenta" }
        Default   { "albus", "Gray" }
    }
    Write-Host "$P - " -NoNewline -ForegroundColor $C
    Write-Host $Msg
}

function Set-Registry {
    param (
        [string]$Path,
        [string]$Name,
        $Value,
        [string]$Type = "DWord"
    )
    try {
        if ($Path.StartsWith("-")) {
            $RealPath = $Path.Substring(1)
            if (Test-Path $RealPath) { Remove-Item -Path $RealPath -Recurse -Force | Out-Null }
            return
        }

        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        if ($Value -eq "-") {
            Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue | Out-Null
        } elseif ($Name -eq "") {
            Set-Item -Path $Path -Value $Value -Force | Out-Null
        } else {
            $FinalType = if ($Type -eq "QWord") { "QWord" } else { $Type }
            try {
                New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $FinalType -Force -ErrorAction Stop | Out-Null
            } catch {
                $RegType = switch ($Type) {
                    "DWord"  { "REG_DWORD" }
                    "String" { "REG_SZ" }
                    "Binary" { "REG_BINARY" }
                    "QWord"  { "REG_QWORD" }
                    "ExpandString" { "REG_EXPAND_SZ" }
                    Default { "REG_DWORD" }
                }
                $CleanPath = $Path.Replace("HKLM:", "HKEY_LOCAL_MACHINE").Replace("HKCU:", "HKEY_CURRENT_USER").Replace("HKCR:", "HKEY_CLASSES_ROOT").Replace("HKU:", "HKEY_USERS")
                $FinalValue = if ($Type -eq "Binary") { ($Value | ForEach-Object { "{0:X2}" -f $_ }) -join "" } else { $Value }
                reg add "$CleanPath" /v "$Name" /t $RegType /d $FinalValue /f | Out-Null
            }
        }
    } catch {
        Status "failed to set registry: $Path\$Name" "fail"
    }
}

$dest = "C:\Albus"
if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest | Out-Null }

if (Test-Connection -ComputerName "8.8.8.8" -Count 1 -Quiet -ErrorAction SilentlyContinue) {
    Status "initializing dynamic payload retrieval..." "done"

    try {
        $braveRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/brave/brave-browser/releases/latest" -ErrorAction Stop
        $braveVer = $braveRelease.tag_name
        $braveUrl = "https://github.com/brave/brave-browser/releases/latest/download/BraveBrowserStandaloneSetup.exe"
        
        Status "fetching brave browser ($braveVer)" "info"
        Invoke-WebRequest -Uri $braveUrl -OutFile "$dest\BraveSetup.exe" -UseBasicParsing -ErrorAction Stop
        
        Status "installing brave browser..." "info"
        Start-Process -Wait "$dest\BraveSetup.exe" -ArgumentList "/silent /install" -WindowStyle Hidden
        
        Status "applying browser hardening..." "info"
        reg.exe add "HKLM\SOFTWARE\Policies\BraveSoftware\Brave" /v "HardwareAccelerationModeEnabled" /t REG_DWORD /d "0" /f | Out-Null
        reg.exe add "HKLM\SOFTWARE\Policies\BraveSoftware\Brave" /v "BackgroundModeEnabled" /t REG_DWORD /d "0" /f | Out-Null
        reg.exe add "HKLM\SOFTWARE\Policies\BraveSoftware\Brave" /v "HighEfficiencyModeEnabled" /t REG_DWORD /d "1" /f | Out-Null
    } catch {
        Status "failed to retrieve brave browser package." "fail"
    }

    try {
        $7zRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/ip7z/7zip/releases/latest" -ErrorAction Stop
        $7zVer = $7zRelease.name
        $7zUrl = ($7zRelease.assets | Where-Object { $_.name -match "7z.*-x64\.exe" }).browser_download_url
        if ($7zUrl) {
            Status "fetching 7-zip ($7zVer)" "info"
            Invoke-WebRequest -Uri $7zUrl -OutFile "$dest\7zip.exe" -UseBasicParsing
            
            Status "extracting and installing 7-zip..." "info"
            Start-Process -Wait "$dest\7zip.exe" -ArgumentList "/S"
            reg.exe add "HKEY_CURRENT_USER\Software\7-Zip\Options" /v "ContextMenu" /t REG_DWORD /d "259" /f | Out-Null
            reg.exe add "HKEY_CURRENT_USER\Software\7-Zip\Options" /v "CascadedMenu" /t REG_DWORD /d "0" /f | Out-Null
            
            Move-Item -Path "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\7-Zip\7-Zip File Manager.lnk" -Destination "$env:ProgramData\Microsoft\Windows\Start Menu\Programs" -Force -ErrorAction SilentlyContinue | Out-Null
            Remove-Item "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\7-Zip" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
    } catch {
        Status "failed to retrieve 7-zip package." "fail"
    }

    try {
        Status "fetching visual c++ runtimes (latest)" "info"
        $vcLinks = @(
            "https://aka.ms/vs/17/release/vc_redist.x64.exe"
            # "https://aka.ms/vs/17/release/vc_redist.x86.exe"
        )
        foreach ($vcLink in $vcLinks) {
            $arch = if ($vcLink -match "x64") { "x64" } else { "x86" }
            Status "downloading vc++ $arch..." "info"
            Invoke-WebRequest -Uri $vcLink -OutFile "$dest\vc_redist.$arch.exe" -UseBasicParsing
            
            Status "installing vc++ $arch..." "info"
            Start-Process -Wait "$dest\vc_redist.$arch.exe" -ArgumentList "/quiet /norestart" -WindowStyle Hidden
        }
    } catch {
        Status "failed to retrieve visual c++ packages." "fail"
    }

    try {
        Status "fetching directx end-user runtime (latest)" "info"
        $dxUrl = "https://download.microsoft.com/download/1/7/1/1718CCC4-6315-4D8E-9543-8E28A4E18C4C/dxwebsetup.exe"
        Status "downloading directx updater..." "info"
        Invoke-WebRequest -Uri $dxUrl -OutFile "$dest\dxwebsetup.exe" -UseBasicParsing -ErrorAction Stop
        
        Status "installing graphics api runtimes..." "info"
        Start-Process -Wait "$dest\dxwebsetup.exe" -ArgumentList "/Q" -WindowStyle Hidden
    } catch {
        Status "failed to retrieve directx." "fail"
    }

} else {
    Status "network interface unresponsive. bypassing payload retrieval." "fail"
}

Status "executing registry optimization..." "step"

if (-not (Get-PSDrive -Name HKCR -ErrorAction SilentlyContinue)) { New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT | Out-Null }
if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) { New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS | Out-Null }

$Tweaks = @(
    # --- EASE OF ACCESS ---
    @{ Path = "HKCU:\Software\Microsoft\Narrator\NoRoam"; Name = "DuckAudio"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator\NoRoam"; Name = "WinEnterLaunchEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator\NoRoam"; Name = "ScriptingEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator\NoRoam"; Name = "OnlineServicesEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator"; Name = "NarratorCursorHighlight"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator"; Name = "CoupleNarratorCursorKeyboard"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Ease of Access"; Name = "selfvoice"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Ease of Access"; Name = "selfscan"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Accessibility"; Name = "Sound on Activation"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Accessibility"; Name = "Warning Sounds"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Accessibility\HighContrast"; Name = "Flags"; Value = "4194"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\Keyboard Response"; Name = "Flags"; Value = "2"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\Keyboard Response"; Name = "AutoRepeatRate"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\Keyboard Response"; Name = "AutoRepeatDelay"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\MouseKeys"; Name = "Flags"; Value = "130"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\MouseKeys"; Name = "MaximumSpeed"; Value = "39"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\MouseKeys"; Name = "TimeToMaximumSpeed"; Value = "3000"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\StickyKeys"; Name = "Flags"; Value = "2"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\ToggleKeys"; Name = "Flags"; Value = "34"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\SoundSentry"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\SoundSentry"; Name = "FSTextEffect"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\SoundSentry"; Name = "TextEffect"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\SoundSentry"; Name = "WindowsEffect"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\SlateLaunch"; Name = "ATapp"; Value = ""; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\SlateLaunch"; Name = "LaunchAT"; Value = 0; Type = "DWord" }

    # --- CLOCK AND REGION ---
    @{ Path = "HKCU:\Control Panel\TimeDate"; Name = "DstNotification"; Value = 0; Type = "DWord" }

    # --- APPEARANCE AND PERSONALIZATION ---
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer"; Name = "ShowFrequent"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "LaunchTo"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "HideFileExt"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "FolderContentsInfoTip"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ShowInfoTip"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ShowPreviewHandlers"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ShowStatusBar"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ShowSyncProviderNotifications"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "SharingWizardOn"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarSmallIcons"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "UseCompactMode"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState"; Name = "FullPath"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings"; Name = "IsDeviceSearchHistoryEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer"; Name = "ShowCloudFilesInQuickAccess"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Classes\CLSID\{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}"; Name = "System.IsPinnedToNameSpaceTree"; Value = 0; Type = "DWord" }

    # --- HARDWARE AND SOUND ---
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings"; Name = "ShowLockOption"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings"; Name = "ShowSleepOption"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Multimedia\Audio"; Name = "UserDuckingPreference"; Value = 3; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\BootAnimation"; Name = "DisableStartupSound"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\EditionOverrides"; Name = "UserSetting_DisableStartupSound"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\AppEvents\Schemes"; Name = ""; Value = ".None"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers"; Name = "DisableAutoplay"; Value = 1; Type = "DWord" }

    # --- MOUSE AND CURSORS ---
    @{ Path = "HKCU:\Control Panel\Mouse"; Name = "MouseSpeed"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Mouse"; Name = "MouseThreshold1"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Mouse"; Name = "MouseThreshold2"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "ContactVisualization"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "GestureVisualization"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "Scheme Source"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = ""; Value = ""; Type = "String" }

    # --- HARDWARE AND DEVICE MANAGEMENT ---
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata"; Name = "PreventDeviceMetadataFromNetwork"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\Network\SharedAccessConnection"; Name = "EnableControl"; Value = 0; Type = "DWord" }

    # --- SYSTEM PERFORMANCE AND MAINTENANCE ---
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Dfrg\TaskSettings"; Name = "fAllVolumes"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Dfrg\TaskSettings"; Name = "fDeadlineEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Dfrg\TaskSettings"; Name = "fExclude"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Dfrg\TaskSettings"; Name = "fTaskEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Dfrg\TaskSettings"; Name = "fUpgradeRestored"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Dfrg\TaskSettings"; Name = "TaskFrequency"; Value = 4; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Dfrg\TaskSettings"; Name = "Volumes"; Value = " "; Type = "String" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl"; Name = "Win32PrioritySeparation"; Value = 38; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance"; Name = "fAllowToGetHelp"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance"; Name = "MaintenanceDisabled"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"; Name = "Disabled"; Value = 1; Type = "DWord" }

    # --- VISUAL EFFECTS AND DWM ---
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects"; Name = "VisualFXSetting"; Value = 3; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "UserPreferencesMask"; Value = ([byte[]](0x90,0x12,0x03,0x80,0x12,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKCU:\Control Panel\Desktop\WindowMetrics"; Name = "MinAnimate"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarAnimations"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\DWM"; Name = "EnableAeroPeek"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\DWM"; Name = "AlwaysHibernateThumbnails"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "IconsOnly"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ListviewAlphaSelect"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "DragFullWindows"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "FontSmoothing"; Value = "2"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ListviewShadow"; Value = 0; Type = "DWord" }

    # --- WINDOWS UPDATE & DELIVERY OPTIMIZATION ---
    @{ Path = "HKU:\S-1-5-20\Software\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Settings"; Name = "DownloadMode"; Value = 0; Type = "DWord" }

    # --- PRIVACY & TRACKING ---
    @{ Path = "HKLM:\SOFTWARE\Microsoft\MdmCommon\SettingValues"; Name = "LocationSyncEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications"; Name = "EnableAccountNotifications"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CPSS\Store\TailoredExperiencesWithDiagnosticDataEnabled"; Name = "Value"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy"; Name = "TailoredExperiencesWithDiagnosticDataEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CPSS\Store\UserLocationOverridePrivacySetting"; Name = "Value"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location"; Name = "ShowGlobalPrompts"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam"; Name = "Value"; Value = "Allow"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone"; Name = "Value"; Value = "Allow"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Speech_OneCore\Settings\VoiceActivation\UserPreferenceForAllApps"; Name = "AgentActivationEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Speech_OneCore\Settings\VoiceActivation\UserPreferenceForAllApps"; Name = "AgentActivationLastUsed"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userNotificationListener"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userAccountInformation"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\contacts"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\appointments"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\phoneCall"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\phoneCallHistory"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\email"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userDataTasks"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\chat"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\radios"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\bluetoothSync"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\appDiagnostics"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\documentsLibrary"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\downloadsFolder"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\musicLibrary"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\picturesLibrary"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\videosLibrary"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\broadFileSystemAccess"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\systemAIModels"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\passkeys"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\passkeysEnumeration"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\International\User Profile"; Name = "HttpAcceptLanguageOptOut"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\EdgeUI"; Name = "DisableMFUTracking"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI"; Name = "DisableMFUTracking"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\InputPersonalization"; Name = "RestrictImplicitInkCollection"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\InputPersonalization"; Name = "RestrictImplicitTextCollection"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\InputPersonalization\TrainedDataStore"; Name = "HarvestContacts"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Personalization\Settings"; Name = "AcceptedPrivacyPolicy"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "AllowTelemetry"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Siuf\Rules"; Name = "NumberOfSIUFInPeriod"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Siuf\Rules"; Name = "PeriodInNanoSeconds"; Value = "-"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; Name = "PublishUserActivities"; Value = 0; Type = "DWord" }

    # --- SEARCH & CLOUD ---
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings"; Name = "IsDynamicSearchBoxEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings"; Name = "SafeSearchMode"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings"; Name = "IsAADCloudSearchEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings"; Name = "IsMSACloudSearchEnabled"; Value = 0; Type = "DWord" }

    # --- ADVANCED EASE OF ACCESS ---
    @{ Path = "HKCU:\Software\Microsoft\ScreenMagnifier"; Name = "FollowCaret"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\ScreenMagnifier"; Name = "FollowNarrator"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\ScreenMagnifier"; Name = "FollowMouse"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\ScreenMagnifier"; Name = "FollowFocus"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator"; Name = "IntonationPause"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator"; Name = "ReadHints"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator"; Name = "ErrorNotificationType"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator"; Name = "EchoChars"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator"; Name = "EchoWords"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator\NarratorHome"; Name = "MinimizeType"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator\NarratorHome"; Name = "AutoStart"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator\NoRoam"; Name = "EchoToggleKeys"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Keyboard"; Name = "PrintScreenKeyForSnippingEnabled"; Value = 0; Type = "DWord" }

    # --- GAMING & PERFORMANCE ---
    @{ Path = "HKCU:\System\GameConfigStore"; Name = "GameDVR_Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "AppCaptureEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\GameBar"; Name = "UseNexusForGameBarEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\GameBar"; Name = "GamepadNexusChordEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\GameBar"; Name = "AutoGameModeEnabled"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "AudioEncodingBitrate"; Value = 128000; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "AudioCaptureEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "CustomVideoEncodingBitrate"; Value = 4000000; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "CustomVideoEncodingHeight"; Value = 720; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "CustomVideoEncodingWidth"; Value = 1280; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "HistoricalBufferLength"; Value = 30; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "HistoricalBufferLengthUnit"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "HistoricalCaptureEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "HistoricalCaptureOnBatteryAllowed"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "HistoricalCaptureOnWirelessDisplayAllowed"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "MaximumRecordLength"; Value = 720000000000; Type = "QWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VideoEncodingBitrateMode"; Value = 2; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VideoEncodingResolutionMode"; Value = 2; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VideoEncodingFrameRateMode"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "EchoCancellationEnabled"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "CursorCaptureEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKToggleGameBar"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKMToggleGameBar"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKSaveHistoricalVideo"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKMSaveHistoricalVideo"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKToggleRecording"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKMToggleRecording"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKTakeScreenshot"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKMTakeScreenshot"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKToggleRecordingIndicator"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKMToggleRecordingIndicator"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKToggleMicrophoneCapture"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKMToggleMicrophoneCapture"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKToggleCameraCapture"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKMToggleCameraCapture"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKToggleBroadcast"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKMToggleBroadcast"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "MicrophoneCaptureEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "SystemAudioGain"; Value = 10000; Type = "QWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "MicrophoneGain"; Value = 10000; Type = "QWord" }

    # --- TIME, LANGUAGE & INPUT ---
    @{ Path = "HKCU:\Software\Microsoft\input\Settings"; Name = "IsVoiceTypingKeyEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\TabletTip\1.7"; Name = "EnableAutoShiftEngage"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\TabletTip\1.7"; Name = "EnableKeyAudioFeedback"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\TabletTip\1.7"; Name = "EnableDoubleTapSpace"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\input\Settings"; Name = "InsightsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\TabletTip\1.7"; Name = "TouchKeyboardTapInvoke"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\CTF\LangBar"; Name = "ExtraIconsOnMinimized"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\CTF\LangBar"; Name = "Label"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\CTF\LangBar"; Name = "ShowStatus"; Value = 3; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\CTF\LangBar"; Name = "Transparency"; Value = 255; Type = "DWord" }
    @{ Path = "HKCU:\Keyboard Layout\Toggle"; Name = "Language Hotkey"; Value = "3"; Type = "String" }
    @{ Path = "HKCU:\Keyboard Layout\Toggle"; Name = "Hotkey"; Value = "3"; Type = "String" }
    @{ Path = "HKCU:\Keyboard Layout\Toggle"; Name = "Layout Hotkey"; Value = "3"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "GleamEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "WeatherEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "HolidayEnabled"; Value = 0; Type = "DWord" }

    # --- ACCOUNTS & SYNC ---
    @{ Path = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon"; Name = "EnableGoodbye"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; Name = "DisableAutomaticRestartSignOn"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device"; Name = "DevicePasswordLessBuildVersion"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device"; Name = "DevicePasswordLessUpdateType"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableAccessibilitySettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableAccessibilitySettingSyncUserOverride"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableAppSyncSettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableAppSyncSettingSyncUserOverride"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableApplicationSettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableApplicationSettingSyncUserOverride"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableCredentialsSettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableCredentialsSettingSyncUserOverride"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableDesktopThemeSettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableDesktopThemeSettingSyncUserOverride"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableLanguageSettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableLanguageSettingSyncUserOverride"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisablePersonalizationSettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisablePersonalizationSettingSyncUserOverride"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableSettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableSettingSyncUserOverride"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableStartLayoutSettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableStartLayoutSettingSyncUserOverride"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableSyncOnPaidNetwork"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableWebBrowserSettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableWebBrowserSettingSyncUserOverride"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableWindowsSettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableWindowsSettingSyncUserOverride"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "EnableWindowsBackup"; Value = 0; Type = "DWord" }

    # --- APPS & MAPS ---
    @{ Path = "HKLM:\SYSTEM\Maps"; Name = "AutoUpdateEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Appx"; Name = "AllowAutomaticAppArchiving"; Value = 0; Type = "DWord" }

    # --- PERSONALIZATION & THEMES ---
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "Wallpaper"; Value = ""; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers"; Name = "BackgroundType"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"; Name = "AppsUseLightTheme"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"; Name = "ColorPrevalence"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"; Name = "EnableTransparency"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"; Name = "SystemUsesLightTheme"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize"; Name = "AppsUseLightTheme"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent"; Name = "AccentPalette"; Value = ([byte[]](0x64,0x64,0x64,0x00,0x6b,0x6b,0x6b,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent"; Name = "StartColorMenu"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent"; Name = "AccentColorMenu"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\DWM"; Name = "EnableWindowColorization"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\DWM"; Name = "AccentColor"; Value = 0xff191919; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\DWM"; Name = "ColorizationColor"; Value = 0xc4191919; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\DWM"; Name = "ColorizationAfterglow"; Value = 0xc4191919; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Colors"; Name = "Background"; Value = "0 0 0"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\ClassicStartMenu"; Name = "{645FF040-5081-101B-9F08-00AA002F954E}"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"; Name = "{645FF040-5081-101B-9F08-00AA002F954E}"; Value = 1; Type = "DWord" }

    # --- START MENU & TASKBAR ---
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"; Name = "ShowOrHideMostUsedApps"; Value = 2; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\Explorer"; Name = "ShowOrHideMostUsedApps"; Value = "-"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoStartMenuMFUprogramsList"; Value = "-"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoInstrumentation"; Value = "-"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoStartMenuMFUprogramsList"; Value = "-"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoInstrumentation"; Value = "-"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "HideRecommendedSection"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Education"; Name = "IsEducationEnvironment"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"; Name = "HideRecommendedSection"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "Start_Layout"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"; Name = "HideRecentlyAddedApps"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "HideRecentlyAddedApps"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "Start_AccountNotifications"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "Start_RecoPersonalizedSites"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "Start_TrackDocs"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\TabletTip\1.7"; Name = "TipbandDesiredVisibility"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "IconSizePreference"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarAl"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarSd"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarMn"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ShowTaskViewButton"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "SearchboxTaskbarMode"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Dsh"; Name = "AllowNewsAndInterests"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ShowCopilotButton"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "IsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "HideSCAMeetNow"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds"; Name = "EnableFeeds"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer"; Name = "EnableAutoTray"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"; Name = "SecurityHealth"; Value = ([byte[]](0x07,0x00,0x00,0x00,0x05,0xDB,0x8A,0x69,0x8A,0x49,0xD9,0x01)); Type = "Binary" }
    @{ Path = "HKCU:\Software\Microsoft\Lighting"; Name = "AmbientLightingEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Lighting"; Name = "ControlledByForegroundApp"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Lighting"; Name = "UseSystemAccentColor"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\TabletTip\1.7"; Name = "IsKeyBackgroundEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "Start_IrisRecommendations"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Start"; Name = "ShowRecentList"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarSn"; Value = 0; Type = "DWord" }

    # --- CLOUD EXPERIENCE HOST INTENT ---
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\developer"; Name = "Intent"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\developer"; Name = "Priority"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\gaming"; Name = "Intent"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\gaming"; Name = "Priority"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\family"; Name = "Intent"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\family"; Name = "Priority"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\creative"; Name = "Intent"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\creative"; Name = "Priority"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\schoolwork"; Name = "Intent"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\schoolwork"; Name = "Priority"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\entertainment"; Name = "Intent"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\entertainment"; Name = "Priority"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\business"; Name = "Intent"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\business"; Name = "Priority"; Value = 0; Type = "DWord" }

    # --- DEVICES & HARDWARE ---
    @{ Path = "HKCU:\Software\Microsoft\Shell\USB"; Name = "NotifyOnUsbErrors"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows"; Name = "LegacyDefaultPrinterMode"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\TabletTip\EmbeddedInkControl"; Name = "EnableInkingWithTouch"; Value = 0; Type = "DWord" }

    # --- SYSTEM, GPU & DPI ---
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "LogPixels"; Value = 96; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "Win8DpiScaling"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\DWM"; Name = "UseDpiScaling"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "EnablePerProcessSystemDPI"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"; Name = "HwSchMode"; Value = 2; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"; Name = "DirectXUserGlobalSettings"; Value = "SwapEffectUpgradeEnable=1;VRROptimizeEnable=0;"; Type = "String" }

    # --- NOTIFICATIONS & TOASTS ---
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications"; Name = "ToastEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested"; Name = "Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings"; Name = "NOC_GLOBAL_SETTING_ALLOW_NOTIFICATION_SOUND"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings"; Name = "NOC_GLOBAL_SETTING_ALLOW_CRITICAL_TOASTS_ABOVE_LOCK"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings"; Name = "NOC_GLOBAL_SETTING_ALLOW_TOASTS_ABOVE_LOCK"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Microsoft.SkyDrive.Desktop"; Name = "Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.AutoPlay"; Name = "Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.SecurityAndMaintenance"; Name = "Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\windows.immersivecontrolpanel_cw5n1h2txyewy!microsoft.windows.immersivecontrolpanel"; Name = "Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.CapabilityAccess"; Name = "Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.StartupApp"; Name = "Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement"; Name = "ScoobeSystemSettingEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SmartActionPlatform\SmartClipboard"; Name = "Disabled"; Value = 1; Type = "DWord" }

    # --- FOCUS ASSIST & QUIET HOURS ---
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache\DefaultAccount\$$windows.data.notifications.quiethourssettings\Current"; Name = "Data"; Value = ([byte[]](0x02,0x00,0x00,0x00,0xB4,0x67,0x2B,0x68,0xF0,0x0B,0xD8,0x01,0x00,0x00,0x00,0x00,0x43,0x42,0x01,0x00,0xC2,0x0A,0x01,0xD2,0x14,0x28,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x51,0x00,0x75,0x00,0x69,0x00,0x65,0x00,0x74,0x00,0x48,0x00,0x6F,0x00,0x75,0x00,0x72,0x00,0x73,0x00,0x50,0x00,0x72,0x00,0x6F,0x00,0x66,0x00,0x69,0x00,0x6C,0x00,0x65,0x00,0x2E,0x00,0x55,0x00,0x6E,0x00,0x72,0x00,0x65,0x00,0x73,0x00,0x74,0x00,0x72,0x00,0x69,0x00,0x63,0x00,0x74,0x00,0x65,0x00,0x64,0x00,0xCA,0x28,0xD0,0x14,0x02,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache\DefaultAccount\$quietmomentfullscreen$windows.data.notifications.quietmoment\Current"; Name = "Data"; Value = ([byte[]](0x02,0x00,0x00,0x00,0x97,0x1D,0x2D,0x68,0xF0,0x0B,0xD8,0x01,0x00,0x00,0x00,0x00,0x43,0x42,0x01,0x00,0xC2,0x0A,0x01,0xD2,0x1E,0x26,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x51,0x00,0x75,0x00,0x69,0x00,0x65,0x00,0x74,0x00,0x48,0x00,0x6F,0x00,0x75,0x00,0x72,0x00,0x73,0x00,0x50,0x00,0x72,0x00,0x6F,0x00,0x66,0x00,0x69,0x00,0x6C,0x00,0x65,0x00,0x2E,0x00,0x41,0x00,0x6C,0x00,0x61,0x00,0x72,0x00,0x6D,0x00,0x73,0x00,0x4F,0x00,0x6E,0x00,0x6C,0x00,0x79,0x00,0xC2,0x28,0x01,0xCA,0x50,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache\DefaultAccount\$quietmomentgame$windows.data.notifications.quietmoment\Current"; Name = "Data"; Value = ([byte[]](0x02,0x00,0x00,0x00,0x6C,0x39,0x2D,0x68,0xF0,0x0B,0xD8,0x01,0x00,0x00,0x00,0x00,0x43,0x42,0x01,0x00,0xC2,0x0A,0x01,0xD2,0x1E,0x28,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x51,0x00,0x75,0x00,0x69,0x00,0x65,0x00,0x74,0x00,0x48,0x00,0x6F,0x00,0x75,0x00,0x72,0x00,0x73,0x00,0x50,0x00,0x72,0x00,0x6F,0x00,0x66,0x00,0x69,0x00,0x6C,0x00,0x65,0x00,0x2E,0x00,0x50,0x00,0x72,0x00,0x69,0x00,0x6F,0x00,0x72,0x00,0x69,0x00,0x74,0x00,0x79,0x00,0x4F,0x00,0x6E,0x00,0x6C,0x00,0x79,0x00,0xC2,0x28,0x01,0xCA,0x50,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache\DefaultAccount\$quietmomentpresentation$windows.data.notifications.quietmoment\Current"; Name = "Data"; Value = ([byte[]](0x02,0x00,0x00,0x00,0x83,0x6E,0x2D,0x68,0xF0,0x0B,0xD8,0x01,0x00,0x00,0x00,0x00,0x43,0x42,0x01,0x00,0xC2,0x0A,0x01,0xD2,0x1E,0x26,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x51,0x00,0x75,0x00,0x69,0x00,0x65,0x00,0x74,0x00,0x48,0x00,0x6F,0x00,0x75,0x00,0x72,0x00,0x73,0x00,0x50,0x00,0x72,0x00,0x6F,0x00,0x66,0x00,0x69,0x00,0x6C,0x00,0x65,0x00,0x2E,0x00,0x41,0x00,0x6C,0x00,0x61,0x00,0x72,0x00,0x6D,0x00,0x73,0x00,0x4F,0x00,0x6E,0x00,0x6C,0x00,0x79,0x00,0xC2,0x28,0x01,0xCA,0x50,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.donotdisturb.quietmoment$quietmomentlist\windows.data.donotdisturb.quietmoment$quietmomentpresentation"; Name = "Data"; Value = ([byte[]](0x43,0x42,0x01,0x00,0x0A,0x02,0x01,0x00,0x2A,0x06,0xE2,0xF3,0xAA,0xCC,0x06,0x2A,0x2B,0x0E,0x5A,0x43,0x42,0x01,0x00,0xC2,0x0A,0x01,0xD2,0x1E,0x26,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x51,0x00,0x75,0x00,0x69,0x00,0x65,0x00,0x74,0x00,0x48,0x00,0x6F,0x00,0x75,0x00,0x72,0x00,0x73,0x00,0x50,0x00,0x72,0x00,0x6F,0x00,0x66,0x00,0x69,0x00,0x6C,0x00,0x65,0x00,0x2E,0x00,0x41,0x00,0x6C,0x00,0x61,0x00,0x72,0x00,0x6D,0x00,0x73,0x00,0x4F,0x00,0x6E,0x00,0x6C,0x00,0x79,0x00,0xCA,0x50,0x00,0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.donotdisturb.quietmoment$quietmomentlist\windows.data.donotdisturb.quietmoment$quietmomentgame"; Name = "Data"; Value = ([byte[]](0x43,0x42,0x01,0x00,0x0A,0x02,0x01,0x00,0x2A,0x06,0xE1,0xF3,0xAA,0xCC,0x06,0x2A,0x2B,0x0E,0x5E,0x43,0x42,0x01,0x00,0xC2,0x0A,0x01,0xD2,0x1E,0x28,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x51,0x00,0x75,0x00,0x69,0x00,0x65,0x00,0x74,0x00,0x48,0x00,0x6F,0x00,0x75,0x00,0x72,0x00,0x73,0x00,0x50,0x00,0x72,0x00,0x6F,0x00,0x66,0x00,0x69,0x00,0x6C,0x00,0x65,0x00,0x2E,0x00,0x50,0x00,0x72,0x00,0x69,0x00,0x6F,0x00,0x72,0x00,0x69,0x00,0x74,0x00,0x79,0x00,0x4F,0x00,0x6E,0x00,0x6C,0x00,0x79,0x00,0xCA,0x50,0x00,0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.donotdisturb.quietmoment$quietmomentlist\windows.data.donotdisturb.quietmoment$quietmomentfullscreen"; Name = "Data"; Value = ([byte[]](0x43,0x42,0x01,0x00,0x0A,0x02,0x01,0x00,0x2A,0x06,0xE0,0xF3,0xAA,0xCC,0x06,0x2A,0x2B,0x0E,0x5A,0x43,0x42,0x01,0x00,0xC2,0x0A,0x01,0xD2,0x1E,0x26,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x51,0x00,0x75,0x00,0x69,0x00,0x65,0x00,0x74,0x00,0x48,0x00,0x6F,0x00,0x75,0x00,0x72,0x00,0x73,0x00,0x50,0x00,0x72,0x00,0x6F,0x00,0x66,0x00,0x69,0x00,0x6C,0x00,0x65,0x00,0x2E,0x00,0x41,0x00,0x6C,0x00,0x61,0x00,0x72,0x00,0x6D,0x00,0x73,0x00,0x4F,0x00,0x6E,0x00,0x6C,0x00,0x79,0x00,0xCA,0x50,0x00,0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.shell.focussessionactivetheme\windows.data.shell.focussessionactivetheme${1b019365-25a5-4ff1-b50a-c155229afc8f}"; Name = "Data"; Value = ([byte[]](0x43,0x42,0x01,0x00,0x0A,0x00,0x2A,0x06,0xF4,0xE2,0xAA,0xCC,0x06,0x2A,0x2B,0x0E,0x08,0x43,0x42,0x01,0x00,0xC2,0x0A,0x01,0x00,0x00,0x00,0x00)); Type = "Binary" }

    # --- STORAGE, POWER & SHELL ---
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\VideoSettings"; Name = "VideoQualityOnBattery"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense"; Name = "AllowStorageSenseGlobal"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"; Name = "04"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"; Name = "2048"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"; Name = "08"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"; Name = "256"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"; Name = "32"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"; Name = "StoragePoliciesChanged"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CDP"; Name = "DragTrayEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "SnapAssist"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "DITest"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "EnableSnapBar"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "EnableTaskGroups"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "EnableSnapAssistFlyout"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "SnapFill"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "JointResize"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings"; Name = "TaskbarEndTask"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"; Name = "LongPathsEnabled"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "MultiTaskingAltTabFilter"; Value = 3; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CDP"; Name = "RomeSdkChannelUserAuthzPolicy"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CDP"; Name = "CdpSessionUserAuthzPolicy"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsMitigation"; Name = "UserPreference"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate"; Name = "AutoDownload"; Value = 2; Type = "DWord" }

    # --- START MENU & FEATURES ---
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\14\2792562829"; Name = "EnabledState"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\14\3036241548"; Name = "EnabledState"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\14\734731404"; Name = "EnabledState"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\14\762256525"; Name = "EnabledState"; Value = 2; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Start"; Name = "AllAppsViewMode"; Value = 2; Type = "DWord" }

    # --- UWP, AI & COPILOT ---
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy"; Name = "LetAppsRunInBackground"; Value = 2; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\input"; Name = "IsInputAppPreloadEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Dsh"; Name = "IsPrelaunchEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\Explorer"; Name = "DisableSearchBoxSuggestions"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot"; Name = "TurnOffWindowsCopilot"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"; Name = "TurnOffWindowsCopilot"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI"; Name = "DisableAIDataAnalysis"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI"; Name = "AllowRecallEnablement"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI"; Name = "DisableClickToDo"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\Shell\Copilot\BingChat"; Name = "IsUserEligible"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint"; Name = "DisableGenerativeFill"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint"; Name = "DisableCocreator"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint"; Name = "DisableImageCreator"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\WindowsNotepad"; Name = "DisableAIFeatures"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\NewsAndInterests\AllowNewsAndInterests"; Name = "value"; Value = 0; Type = "DWord" }

    # --- ADVERTISING & CONTENT DELIVERY ---
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "ContentDeliveryAllowed"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "FeatureManagementEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "OemPreInstalledAppsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "PreInstalledAppsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "PreInstalledAppsEverEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "RotatingLockScreenEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "RotatingLockScreenOverlayEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SilentInstalledAppsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SlideshowEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SoftLandingEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-310093Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-314563Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-338388Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-338389Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-338393Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-353694Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-353696Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-353698Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContentEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SystemPaneSuggestionsEnabled"; Value = 0; Type = "DWord" }

    # --- GAMEBAR PROTOCOL REDIRECTION ---
    @{ Path = "HKCR:\ms-gamebar"; Name = ""; Value = "URL:ms-gamebar"; Type = "String" }
    @{ Path = "HKCR:\ms-gamebar"; Name = "URL Protocol"; Value = ""; Type = "String" }
    @{ Path = "HKCR:\ms-gamebar"; Name = "NoOpenWith"; Value = ""; Type = "String" }
    @{ Path = "HKCR:\ms-gamebar\shell\open\command"; Name = ""; Value = "$env:SystemRoot\System32\systray.exe"; Type = "String" }
    @{ Path = "HKCR:\ms-gamebarservices"; Name = ""; Value = "URL:ms-gamebarservices"; Type = "String" }
    @{ Path = "HKCR:\ms-gamebarservices"; Name = "URL Protocol"; Value = ""; Type = "String" }
    @{ Path = "HKCR:\ms-gamebarservices"; Name = "NoOpenWith"; Value = ""; Type = "String" }
    @{ Path = "HKCR:\ms-gamebarservices\shell\open\command"; Name = ""; Value = "$env:SystemRoot\System32\systray.exe"; Type = "String" }
    @{ Path = "HKCR:\ms-gamingoverlay"; Name = ""; Value = "URL:ms-gamingoverlay"; Type = "String" }
    @{ Path = "HKCR:\ms-gamingoverlay"; Name = "URL Protocol"; Value = ""; Type = "String" }
    @{ Path = "HKCR:\ms-gamingoverlay"; Name = "NoOpenWith"; Value = ""; Type = "String" }
    @{ Path = "HKCU:\ms-gamingoverlay\shell\open\command"; Name = ""; Value = "$env:SystemRoot\System32\systray.exe"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\Windows.Gaming.GameBar.PresenceServer.Internal.PresenceWriter"; Name = "ActivationType"; Value = 0; Type = "DWord" }

    # --- SHELL & EXPLORER CLEANUP ---
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{0DB7E03F-FC29-4DC6-9020-FF41B59E513A}"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{0DB7E03F-FC29-4DC6-9020-FF41B59E513A}"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer"; Name = "HubMode"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Classes\CLSID\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}"; Name = "System.IsPinnedToNameSpaceTree"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "MenuShowDelay"; Value = "0"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching"; Name = "SearchOrderConfig"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoWebServices"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "SettingsPageVisibility"; Value = "hide:home;"; Type = "String" }

    # --- NO ACCEL MOUSE FIX ---
    @{ Path = "HKCU:\Control Panel\Mouse"; Name = "RawMouseThrottleEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Mouse"; Name = "MouseSensitivity"; Value = "10"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Mouse"; Name = "SmoothMouseXCurve"; Value = ([byte[]](0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00, 0xC0,0xCC,0x0C,0x00,0x00,0x00,0x00,0x00, 0x80,0x99,0x19,0x00,0x00,0x00,0x00,0x00, 0x40,0x66,0x26,0x00,0x00,0x00,0x00,0x00, 0x00,0x33,0x33,0x00,0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKCU:\Control Panel\Mouse"; Name = "SmoothMouseYCurve"; Value = ([byte[]](0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00, 0x00,0x00,0x38,0x00,0x00,0x00,0x00,0x00, 0x00,0x00,0x70,0x00,0x00,0x00,0x00,0x00, 0x00,0x00,0xA8,0x00,0x00,0x00,0x00,0x00, 0x00,0x00,0xE0,0x00,0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Mouse"; Name = "MouseSpeed"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Mouse"; Name = "MouseThreshold1"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Mouse"; Name = "MouseThreshold2"; Value = "0"; Type = "String" }

    # --- SYSTEM & STABILITY ---
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Start"; Name = "RightCompanionToggledOpen"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Start\Companions\Microsoft.YourPhone_8wekyb3d8bbwe"; Name = "IsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Start\Companions\Microsoft.YourPhone_8wekyb3d8bbwe"; Name = "IsAvailable"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"; Name = "DisplayParameters"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"; Name = "DisableWpbtExecution"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CrossDeviceResume\Configuration"; Name = "IsResumeAllowed"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CrossDeviceResume\Configuration"; Name = "IsOneDriveResumeAllowed"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Connectivity\DisableCrossDeviceResume"; Name = "value"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\8\1387020943"; Name = "EnabledState"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\8\1694661260"; Name = "EnabledState"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Console\%SystemRoot%_System32_WindowsPowerShell_v1.0_powershell.exe"; Name = "ScreenColors"; Value = 15; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement"; Name = "ScoobeSystemSettingEnabled"; Value = 0; Type = "DWord" }
)

foreach ($Tweak in $Tweaks) {
    Set-Registry -Path $Tweak.Path -Name $Tweak.Name -Value $Tweak.Value -Type $Tweak.Type
}

# Sound Schemes
$SoundKeys = @(
    ".Default\.Default", "CriticalBatteryAlarm", "DeviceConnect", "DeviceDisconnect", "DeviceFail", "FaxBeep", 
    "LowBatteryAlarm", "MailBeep", "MessageNudge", "Notification.Default", "Notification.IM", "Notification.Mail", 
    "Notification.Proximity", "Notification.Reminder", "Notification.SMS", "ProximityConnection", "SystemAsterisk", 
    "SystemExclamation", "SystemHand", "SystemNotification", "WindowsUAC"
)
foreach ($s in $SoundKeys) {
    $p = if ($s -eq ".Default\.Default") { "HKCU:\AppEvents\Schemes\Apps\.Default\.Default\.Current" } else { "HKCU:\AppEvents\Schemes\Apps\.Default\$s\.Current" }
    Set-Registry -Path $p -Name "" -Value "" -Type "String"
}

# Speech Sound Schemes
$SpeechKeys = @("DisNumbersSound", "HubOffSound", "HubOnSound", "HubSleepSound", "MisrecoSound", "PanelSound")
foreach ($s in $SpeechKeys) {
    Set-Registry -Path "HKCU:\AppEvents\Schemes\Apps\sapisvr\$s\.current" -Name "" -Value "" -Type "String"
}

# Mouse Cursors
$CursorKeys = @(
    "AppStarting", "Arrow", "Crosshair", "Hand", "Help", "IBeam", "No", "NWPen", 
    "SizeAll", "SizeNESW", "SizeNS", "SizeNWSE", "SizeWE", "UpArrow", "Wait"
)
foreach ($c in $CursorKeys) {
    Set-Registry -Path "HKCU:\Control Panel\Cursors" -Name $c -Value "" -Type "ExpandString"
}

Status "registry optimization complete." "done"
pause

# =============================================================================================================================================================================
