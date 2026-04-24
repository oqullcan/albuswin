#Requires -RunAsAdministrator

using namespace System
using namespace System.IO
using namespace System.Diagnostics
using namespace System.Text.RegularExpressions
using namespace Microsoft.Win32

class AlbusDebloat {
    static [string[]] $UwpAppExclusions = @(
        'CBS', 'Microsoft.AV1VideoExtension', 'Microsoft.AVCEncoderVideoExtension',
        'Microsoft.HEIFImageExtension', 'Microsoft.HEVCVideoExtension', 'Microsoft.MPEG2VideoExtension',
        'Microsoft.Paint', 'Microsoft.RawImageExtension', 'Microsoft.SecHealthUI',
        'Microsoft.VP9VideoExtensions', 'Microsoft.WebMediaExtensions', 'Microsoft.WebpImageExtension',
        'Microsoft.Windows.Photos', 'Microsoft.Windows.ShellExperienceHost',
        'Microsoft.Windows.StartMenuExperienceHost', 'Microsoft.WindowsNotepad',
        'Microsoft.WindowsStore', 'NVIDIACorp.NVIDIAControlPanel', 'windows.immersivecontrolpanel'
    )

    static [string[]] $UwpFeatureExclusions = @(
        'Microsoft.Windows.Ethernet', 'Microsoft.Windows.MSPaint', 'Microsoft.Windows.Notepad',
        'Microsoft.Windows.Notepad.System', 'Microsoft.Windows.Wifi', 'NetFX3', 'VBSCRIPT',
        'WMIC', 'Windows.Client.ShellComponents'
    )

    static [string[]] $LegacyFeatureExclusions = @(
        'DirectPlay', 'LegacyComponents', 'NetFx3', 'NetFx4', 'NetFx4-AdvSrvs', 'NetFx4ServerFeatures',
        'SearchEngine-Client-Package', 'Server-Shell', 'Windows-Defender', 'Server-Drivers-General',
        'ServerCore-Drivers-General', 'ServerCore-Drivers-General-WOW64', 'Server-Gui-Mgmt',
        'WirelessNetworking'
    )

    static [void] RunProcess([string]$FileName, [string]$Arguments) {
        $psi = [ProcessStartInfo]::new()
        $psi.FileName = $FileName
        $psi.Arguments = $Arguments
        $psi.WindowStyle = [ProcessWindowStyle]::Hidden
        $psi.CreateNoWindow = $true
        $proc = [Process]::Start($psi)
        if ($null -ne $proc) {
            $proc.WaitForExit()
        }
    }

    static [void] SpoofAndUninstall([string]$RegistryKeyId) {
        $baseKey = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\ClientState\' + $RegistryKeyId
        if (-not (Test-Path -Path $baseKey)) { return }

        Remove-ItemProperty -Path $baseKey -Name "experiment_control_labels" -ErrorAction SilentlyContinue

        # BrowserReplacement Fake Exe
        $folderPath = [Path]::Combine([Environment]::GetEnvironmentVariable("SystemRoot"), "SystemApps", "Microsoft.MicrosoftEdge_8wekyb3d8bbwe")
        if (-not [Directory]::Exists($folderPath)) {
            [Directory]::CreateDirectory($folderPath) | Out-Null
        }
        $fakeExe = [Path]::Combine($folderPath, "MicrosoftEdge.exe")
        if (-not [File]::Exists($fakeExe)) {
            [File]::Create($fakeExe).Close()
        }

        # Bypass OS check
        $oldWinDir = [Environment]::GetEnvironmentVariable("windir")
        [Environment]::SetEnvironmentVariable("windir", "")

        $props = Get-ItemProperty -Path $baseKey -ErrorAction SilentlyContinue
        $uninstallStr = $props.UninstallString
        $uninstallArgs = $props.UninstallArguments

        if ([string]::IsNullOrEmpty($uninstallStr) -or [string]::IsNullOrEmpty($uninstallArgs)) {
            [Environment]::SetEnvironmentVariable("windir", $oldWinDir)
            return
        }

        $uninstallArgs += " --force-uninstall --delete-profile"

        if (-not [File]::Exists($uninstallStr)) {
            [Environment]::SetEnvironmentVariable("windir", $oldWinDir)
            return
        }

        # Process spoofing (ImmersiveControlPanel\sihost.exe)
        $spoofDir = [Path]::Combine([Environment]::GetEnvironmentVariable("SystemRoot"), "ImmersiveControlPanel")
        $spoofPath = [Path]::Combine($spoofDir, "sihost.exe")

        try {
            [File]::Copy([Path]::Combine([Environment]::GetEnvironmentVariable("SystemRoot"), "System32", "cmd.exe"), $spoofPath, $true)
            
            $cmdArgs = "/c `"$uninstallStr`" $uninstallArgs"
            $psi = [ProcessStartInfo]::new()
            $psi.FileName = $spoofPath
            $psi.Arguments = $cmdArgs
            $psi.WindowStyle = [ProcessWindowStyle]::Hidden
            $psi.CreateNoWindow = $true
            
            $process = [Process]::Start($psi)
            $process.WaitForExit()
        }
        finally {
            if ([File]::Exists($spoofPath)) {
                [File]::Delete($spoofPath)
            }
            [Environment]::SetEnvironmentVariable("windir", $oldWinDir)
        }
    }

    static [void] RemoveEdge() {
        Write-Host "[*] Purging Microsoft Edge (Advanced Mode)..." -ForegroundColor Cyan

        # Region Bypass
        $regionKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Control Panel\DeviceRegion"
        $originalRegion = Get-ItemPropertyValue -Path $regionKey -Name "DeviceRegion" -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $regionKey -Name "DeviceRegion" -Value 244 -Type DWord -ErrorAction SilentlyContinue

        # Kill Processes
        $edgeProcs = @("backgroundTaskHost", "Copilot", "CrossDeviceResume", "GameBar", "MicrosoftEdgeUpdate", "msedge", "msedgewebview2", "OneDrive", "OneDrive.Sync.Service", "OneDriveStandaloneUpdater", "Resume", "RuntimeBroker", "Search", "SearchHost", "Setup", "StoreDesktopExtension", "WidgetService", "Widgets")
        foreach ($procName in $edgeProcs) { [Process]::GetProcessesByName($procName) | ForEach-Object { $_.Kill() } }
        [Process]::GetProcesses() | Where-Object ProcessName -Match '(?i)edge' | ForEach-Object { $_.Kill() }

        # Edge Stable
        Remove-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge" -Name "NoRemove" -ErrorAction SilentlyContinue
        [Registry]::SetValue("HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdateDev", "AllowUninstall", 1, [RegistryValueKind]::DWord)
        [AlbusDebloat]::SpoofAndUninstall('{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}')

        # Shortcuts
        $shortcutPaths = @(
            [Path]::Combine([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonPrograms)),
            [Path]::Combine([Environment]::GetEnvironmentVariable("PUBLIC"), "Desktop"),
            [Path]::Combine([Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory))
        )
        foreach ($dir in $shortcutPaths) {
            $lnk = [Path]::Combine($dir, "Microsoft Edge.lnk")
            if ([File]::Exists($lnk)) { [File]::Delete($lnk) }
        }

        # WebView
        Remove-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft EdgeWebView" -Name "NoRemove" -ErrorAction SilentlyContinue
        [AlbusDebloat]::SpoofAndUninstall('{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}')

        # EdgeUpdate
        Remove-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update" -Name "NoRemove" -ErrorAction SilentlyContinue
        $euPath = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate"
        $euCmd = (Get-ItemProperty -Path $euPath -ErrorAction SilentlyContinue).UninstallCmdLine
        if (-not [string]::IsNullOrEmpty($euCmd)) {
            [AlbusDebloat]::RunProcess("cmd.exe", "/c $euCmd")
        }

        # Registry Cleanup
        $regPaths = @(
            "HKCU:\SOFTWARE\Microsoft\EdgeUpdate", "HKLM:\SOFTWARE\Microsoft\EdgeUpdate",
            "HKCU:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate",
            "HKCU:\SOFTWARE\Policies\Microsoft\EdgeUpdate", "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate",
            "HKCU:\SOFTWARE\WOW6432Node\Policies\Microsoft\EdgeUpdate", "HKLM:\SOFTWARE\WOW6432Node\Policies\Microsoft\EdgeUpdate"
        )
        $regPaths | ForEach-Object { Remove-Item -Path $_ -Recurse -Force -ErrorAction SilentlyContinue }

        # Legacy Packages
        [AlbusDebloat]::RemoveWinSxSPackage("Microsoft-Windows-Internet-Browser-Package.*~~")

        # Restore Region
        if ($null -ne $originalRegion) {
            Set-ItemProperty -Path $regionKey -Name "DeviceRegion" -Value $originalRegion -Type DWord -ErrorAction SilentlyContinue
        }

        # Clean Dirs
        Remove-Item -Path ([Path]::Combine([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86), "Microsoft")) -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$env:SystemRoot\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$env:SystemDrive\Windows\System32\config\systemprofile\AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\Microsoft Edge.lnk" -Recurse -Force -ErrorAction SilentlyContinue
    }

    static [void] PurgeUwpPackage([string]$PackageName, [bool]$Unregister) {
        $baseRegistryPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore"
        $allPackages = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue
        $filtered = $allPackages | Where-Object PackageFullName -like "*$PackageName*"

        foreach ($pkg in $filtered) {
            $fullName = $pkg.PackageFullName
            $familyName = $pkg.PackageFamilyName

            # Deprovisioned
            $deprovPath = [Path]::Combine($baseRegistryPath, "Deprovisioned", $familyName)
            if (-not (Test-Path -Path $deprovPath)) { New-Item -Path $deprovPath -Force -ErrorAction SilentlyContinue | Out-Null }

            # InboxApps
            $inboxPath = [Path]::Combine($baseRegistryPath, "InboxApplications", $fullName)
            if (Test-Path -Path $inboxPath) { Remove-Item -Path $inboxPath -Force -ErrorAction SilentlyContinue | Out-Null }

            $canRemove = ($pkg.NonRemovable -ne 1)
            if (-not $canRemove) {
                if (Get-Command Set-NonRemovableAppsPolicy -ErrorAction SilentlyContinue) {
                    Set-NonRemovableAppsPolicy -Online -PackageFamilyName $familyName -NonRemovable 0
                    $canRemove = $true
                }
            }

            if ($canRemove) {
                # EndOfLife per user
                if ($null -ne $pkg.PackageUserInformation) {
                    foreach ($userInfo in $pkg.PackageUserInformation) {
                        $userSid = $userInfo.UserSecurityID.SID
                        $eolPath = [Path]::Combine($baseRegistryPath, "EndOfLife", $userSid, $fullName)
                        if (-not (Test-Path -Path $eolPath)) { New-Item -Path $eolPath -Force -ErrorAction SilentlyContinue | Out-Null }

                        try { Remove-AppxPackage -Package $fullName -User $userSid -ErrorAction Stop } catch {}
                    }
                }

                try { Remove-AppxPackage -Package $fullName -AllUsers -ErrorAction Stop } catch {}
            }
        }
    }

    static [void] RemoveUwpApps() {
        Write-Host "[*] Purging UWP Apps (Advanced Mode)..." -ForegroundColor Cyan
        $regex = ([AlbusDebloat]::UwpAppExclusions | ForEach-Object { [Regex]::Escape($_) }) -join '|'
        
        $packagesToRemove = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object Name -NotMatch $regex | Select-Object -ExpandProperty Name -Unique
        foreach ($pkgName in $packagesToRemove) {
            [AlbusDebloat]::PurgeUwpPackage($pkgName, $true)
        }
    }

    static [void] RemoveUwpFeatures() {
        Write-Host "[*] Purging UWP Features..." -ForegroundColor Cyan
        $regex = ([AlbusDebloat]::UwpFeatureExclusions | ForEach-Object { [Regex]::Escape($_) }) -join '|'
        
        $capabilities = Get-WindowsCapability -Online -ErrorAction SilentlyContinue | Where-Object State -eq 'Installed' | Where-Object Name -NotMatch $regex
        foreach ($cap in $capabilities) {
            try { Remove-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null } catch {}
        }
    }

    static [void] UpdateFeature([string]$FeatureName, [bool]$Enable) {
        $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Notifications\OptionalFeatures\$FeatureName"
        $regKey = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
        
        $shouldExecute = ($null -eq $regKey) -or ($regKey.Selection -eq 0 -and $Enable) -or ($regKey.Selection -eq 1 -and -not $Enable)
        
        if ($shouldExecute) {
            if ($Enable) {
                Enable-WindowsOptionalFeature -Online -FeatureName $FeatureName -NoRestart -All -ErrorAction SilentlyContinue | Out-Null
            } else {
                Disable-WindowsOptionalFeature -Online -FeatureName $FeatureName -NoRestart -ErrorAction SilentlyContinue | Out-Null
            }
        }
    }

    static [void] RemoveLegacyFeatures() {
        Write-Host "[*] Purging Legacy Features (Advanced Mode)..." -ForegroundColor Cyan
        
        $features = @(
            @{ Name = "DirectPlay"; Bool = $true },
            @{ Name = "LegacyComponents"; Bool = $true },
            @{ Name = "MicrosoftWindowsPowerShellV2"; Bool = $false },
            @{ Name = "MicrosoftWindowsPowerShellV2Root"; Bool = $false },
            @{ Name = "MSRDC-Infrastructure"; Bool = $false },
            @{ Name = "Printing-Foundation-Features"; Bool = $false },
            @{ Name = "Printing-Foundation-InternetPrinting-Client"; Bool = $false },
            @{ Name = "WorkFolders-Client"; Bool = $false }
        )
        
        foreach ($f in $features) { [AlbusDebloat]::UpdateFeature($f.Name, $f.Bool) }

        $regex = ([AlbusDebloat]::LegacyFeatureExclusions | ForEach-Object { [Regex]::Escape($_) }) -join '|'
        Get-WindowsOptionalFeature -Online -ErrorAction SilentlyContinue | Where-Object State -eq 'Enabled' | Where-Object FeatureName -NotMatch $regex | ForEach-Object {
            [AlbusDebloat]::UpdateFeature($_.FeatureName, $false)
        }
    }

    static [void] TakeOwnershipAndGrantAccess([string]$Path) {
        if (-not (Test-Path $Path)) { return }
        
        $adminGroup = [System.Security.Principal.SecurityIdentifier]::new("S-1-5-32-544")
        $accessRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $adminGroup, 
            [System.Security.AccessControl.FileSystemRights]::FullControl, 
            [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit, 
            [System.Security.AccessControl.PropagationFlags]::None, 
            [System.Security.AccessControl.AccessControlType]::Allow
        )

        $items = @(Get-Item -Path $Path -Force -ErrorAction SilentlyContinue)
        $items += Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue

        foreach ($item in $items) {
            try {
                $acl = $item.GetAccessControl()
                $acl.SetOwner($adminGroup)
                $item.SetAccessControl($acl)

                $acl = $item.GetAccessControl()
                $acl.AddAccessRule($accessRule)
                $item.SetAccessControl($acl)
            } catch {}
        }
    }

    static [void] RemoveLegacyApps() {
        Write-Host "[*] Purging Legacy Apps & OneDrive (Advanced Mode)..." -ForegroundColor Cyan

        # brltty
        $brlDir = [Path]::Combine([Environment]::GetEnvironmentVariable("SystemRoot"), "brltty")
        if ([Directory]::Exists($brlDir)) {
            Stop-Service -Name "brlapi" -Force -ErrorAction SilentlyContinue
            $brlSvc = Get-WmiObject -Class Win32_Service -Filter "Name='brlapi'" -ErrorAction SilentlyContinue
            if ($brlSvc) { $brlSvc.Delete() | Out-Null }
            
            [AlbusDebloat]::TakeOwnershipAndGrantAccess($brlDir)
            Remove-Item -Path $brlDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        # Advanced OneDrive Uninstall
        $setupPaths = [System.Collections.Generic.List[string]]::new()
        $setupPaths.Add([Path]::Combine([Environment]::GetEnvironmentVariable("SystemRoot"), "System32", "OneDriveSetup.exe"))
        $setupPaths.Add([Path]::Combine([Environment]::GetEnvironmentVariable("SystemRoot"), "SysWOW64", "OneDriveSetup.exe"))

        if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
            New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS | Out-Null
        }

        $users = Get-ChildItem 'HKU:\' -ErrorAction SilentlyContinue
        foreach ($user in $users) {
            $userKey = $user.PSChildName
            if (Test-Path "HKU:\$userKey\Volatile Environment") {
                $regPath = "HKU:\$userKey\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe"
                $uninstallStr = (Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue).UninstallString
                if (-not [string]::IsNullOrEmpty($uninstallStr)) {
                    $exePath = $uninstallStr -replace '"', ''
                    if ($exePath -match "OneDriveSetup.exe" -and -not $setupPaths.Contains($exePath)) {
                        $setupPaths.Insert(0, $exePath)
                    }
                }
                Remove-ItemProperty -Path "HKU:\$userKey\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name "OneDrive" -ErrorAction SilentlyContinue
                Remove-Item -Path $regPath -Force -ErrorAction SilentlyContinue
            }
        }

        foreach ($path in $setupPaths) {
            if ([File]::Exists($path)) {
                [AlbusDebloat]::RunProcess($path, "/uninstall")
            }
        }

        $usersDir = [Path]::Combine([Environment]::GetEnvironmentVariable("SystemDrive"), "Users")
        if ([Directory]::Exists($usersDir)) {
            [Directory]::GetDirectories($usersDir) | ForEach-Object {
                $oneDriveLocal = [Path]::Combine($_, "AppData\Local\Microsoft\OneDrive")
                if ([Directory]::Exists($oneDriveLocal)) { [Directory]::Delete($oneDriveLocal, $true) }
                $oneDriveLnk = [Path]::Combine($_, "AppData\Roaming\Microsoft\Windows\Start Menu\Programs\OneDrive.lnk")
                if ([File]::Exists($oneDriveLnk)) { [File]::Delete($oneDriveLnk) }
            }
        }

        # Remove from Explorer Sidebar
        [Registry]::SetValue("HKEY_CLASSES_ROOT\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}", "System.IsPinnedToNameSpaceTree", 0, [RegistryValueKind]::DWord)
        Get-ScheduledTask | Where-Object TaskName -Match 'OneDrive' | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue

        # MSIs (GameInput, Health Tools)
        $uninstallKeys = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
        Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue | Where-Object {
            $_.DisplayName -Match 'Microsoft GameInput|Microsoft Update Health Tools|Update for x64-based Windows Systems'
        } | ForEach-Object {
            [AlbusDebloat]::RunProcess("msiexec.exe", "/x $($_.PSChildName) /qn /norestart")
        }

        # Legacy mstsc & snipping tool triggers
        try { Start-Process "mstsc.exe" -ArgumentList "/Uninstall" -ErrorAction SilentlyContinue } catch {}
        try { Start-Process "SnippingTool.exe" -ArgumentList "/Uninstall" -ErrorAction SilentlyContinue } catch {}
        Start-Sleep -Seconds 1
        [Process]::GetProcessesByName("mstsc") | ForEach-Object { $_.Kill() }
        [Process]::GetProcessesByName("SnippingTool") | ForEach-Object { $_.Kill() }

        # Clear Third-Party Startups (Registry)
        $runKeys = @(
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run",
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce",
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunNotification",
            "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run",
            "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce"
        )
        foreach ($key in $runKeys) {
            $regItem = Get-Item -Path $key -ErrorAction SilentlyContinue
            if ($regItem) {
                $regItem.GetValueNames() | ForEach-Object { Remove-ItemProperty -Path $key -Name $_ -ErrorAction SilentlyContinue }
            }
        }

        # Clear Third-Party Startups (Folders)
        $startupFolders = @(
            [Path]::Combine([Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData), "Microsoft\Windows\Start Menu\Programs\Startup"),
            [Path]::Combine([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData), "Microsoft\Windows\Start Menu\Programs\StartUp")
        )
        foreach ($folder in $startupFolders) {
            if ([Directory]::Exists($folder)) {
                [Directory]::GetFiles($folder) | ForEach-Object { [File]::Delete($_) }
            }
        }

        # Remove Third-Party Tasks
        Get-ScheduledTask | Where-Object TaskPath -NotMatch "\\Microsoft\\" | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
    }

    static [void] RemoveWinSxSPackage([string]$RegexPattern) {
        $packages = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages" -ErrorAction SilentlyContinue | Where-Object PSChildName -Match $RegexPattern

        foreach ($pkg in $packages) {
            $pkgName = $pkg.PSChildName
            $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages\$pkgName"
            
            Set-ItemProperty -Path $regPath -Name "Visibility" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            
            $ownersPath = "$regPath\Owners"
            $ownersKey = Get-Item -Path $ownersPath -ErrorAction SilentlyContinue
            if ($ownersKey) {
                $ownersKey.GetValueNames() | ForEach-Object {
                    Remove-ItemProperty -Path $ownersPath -Name $_ -Force -ErrorAction SilentlyContinue
                }
            }
            
            try { Remove-WindowsPackage -Online -PackageName $pkgName -NoRestart -ErrorAction Stop | Out-Null } catch {}
        }
    }

    static [void] RemoveAIPackages() {
        Write-Host "[*] Purging Windows AI & Copilot Packages (WinSxS)..." -ForegroundColor Cyan
        $aiRegex = "(?i)(Copilot|MachineLearning|Windows-AI-|Recall|Holographic)"
        [AlbusDebloat]::RemoveWinSxSPackage($aiRegex)
    }

    static [void] RunAll() {
        [AlbusDebloat]::RemoveEdge()
        [AlbusDebloat]::RemoveUwpApps()
        [AlbusDebloat]::RemoveUwpFeatures()
        [AlbusDebloat]::RemoveLegacyFeatures()
        [AlbusDebloat]::RemoveLegacyApps()
        [AlbusDebloat]::RemoveAIPackages()
        Write-Host "[+] Telemetry, AI Bloatware and Unwanted Features removed successfully." -ForegroundColor Green
    }
}

# Execute
[AlbusDebloat]::RunAll()
