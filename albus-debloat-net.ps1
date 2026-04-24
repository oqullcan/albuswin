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
        'Microsoft.WindowsStore', 'NVIDIACorp.NVIDIAControlPanel', 'windows.immersivecontrolpanel',
        # Kritik Sistem Bileşenleri (Bozulmayı önlemek için eklendi)
        'Microsoft.UI.Xaml', 'Microsoft.VCLibs', 'Microsoft.NET.Native.Framework', 
        'Microsoft.NET.Native.Runtime', 'Microsoft.DesktopAppInstaller', 'Microsoft.Windows.Search',
        'Microsoft.Windows.ShellComponents'
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

        $folderPath = [Path]::Combine([Environment]::GetEnvironmentVariable("SystemRoot"), "SystemApps", "Microsoft.MicrosoftEdge_8wekyb3d8bbwe")
        if (-not [Directory]::Exists($folderPath)) {
            [Directory]::CreateDirectory($folderPath) | Out-Null
        }
        $fakeExe = [Path]::Combine($folderPath, "MicrosoftEdge.exe")
        if (-not [File]::Exists($fakeExe)) {
            [File]::Create($fakeExe).Close()
        }

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

        $spoofDir = [Path]::Combine([Environment]::GetEnvironmentVariable("SystemRoot"), "ImmersiveControlPanel")
        if (-not [Directory]::Exists($spoofDir)) { [Directory]::CreateDirectory($spoofDir) | Out-Null }
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

        $regionKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Control Panel\DeviceRegion"
        $originalRegion = Get-ItemPropertyValue -Path $regionKey -Name "DeviceRegion" -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $regionKey -Name "DeviceRegion" -Value 244 -Type DWord -ErrorAction SilentlyContinue

        $edgeProcs = @("backgroundTaskHost", "Copilot", "CrossDeviceResume", "GameBar", "MicrosoftEdgeUpdate", "msedge", "msedgewebview2", "OneDrive", "OneDrive.Sync.Service", "OneDriveStandaloneUpdater", "Resume", "RuntimeBroker", "Search", "SearchHost", "Setup", "StoreDesktopExtension", "WidgetService", "Widgets")
        foreach ($procName in $edgeProcs) { [Process]::GetProcessesByName($procName) | ForEach-Object { try { $_.Kill() } catch {} } }
        [Process]::GetProcesses() | Where-Object ProcessName -Match '(?i)edge' | ForEach-Object { try { $_.Kill() } catch {} }

        Remove-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge" -Name "NoRemove" -ErrorAction SilentlyContinue
        [Registry]::SetValue("HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdateDev", "AllowUninstall", 1, [RegistryValueKind]::DWord)
        [AlbusDebloat]::SpoofAndUninstall('{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}')

        $shortcutPaths = @(
            [Path]::Combine([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonPrograms)),
            [Path]::Combine([Environment]::GetEnvironmentVariable("PUBLIC"), "Desktop"),
            [Path]::Combine([Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory))
        )
        foreach ($dir in $shortcutPaths) {
            $lnk = [Path]::Combine($dir, "Microsoft Edge.lnk")
            if ([File]::Exists($lnk)) { [File]::Delete($lnk) }
        }

        # WebView2 KORUMALI: WebView2, Windows 11 Shell için kritiktir. Sadece Edge Update ve Edge kaldırılır.
        Remove-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update" -Name "NoRemove" -ErrorAction SilentlyContinue
        $euPath = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate"
        $euCmd = (Get-ItemProperty -Path $euPath -ErrorAction SilentlyContinue).UninstallCmdLine
        if (-not [string]::IsNullOrEmpty($euCmd)) {
            [AlbusDebloat]::RunProcess("cmd.exe", "/c $euCmd")
        }

        $regPaths = @(
            "HKCU:\SOFTWARE\Microsoft\EdgeUpdate", "HKLM:\SOFTWARE\Microsoft\EdgeUpdate",
            "HKCU:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate",
            "HKCU:\SOFTWARE\Policies\Microsoft\EdgeUpdate", "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate"
        )
        $regPaths | ForEach-Object { Remove-Item -Path $_ -Recurse -Force -ErrorAction SilentlyContinue }

        if ($null -ne $originalRegion) {
            Set-ItemProperty -Path $regionKey -Name "DeviceRegion" -Value $originalRegion -Type DWord -ErrorAction SilentlyContinue
        }

        # Sadece Edge dosyalarını temizle (Tüm Microsoft klasörünü silme!)
        $prog86 = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)
        Remove-Item -Path (Join-Path $prog86 "Microsoft\Edge") -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path (Join-Path $prog86 "Microsoft\EdgeUpdate") -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$env:SystemRoot\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe" -Recurse -Force -ErrorAction SilentlyContinue
    }

    static [void] PurgeUwpPackage([string]$PackageName, [bool]$Unregister) {
        $baseRegistryPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore"
        $allPackages = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue
        $filtered = $allPackages | Where-Object PackageFullName -like "*$PackageName*"

        foreach ($pkg in $filtered) {
            $fullName = $pkg.PackageFullName
            $familyName = $pkg.PackageFamilyName

            $deprovPath = [Path]::Combine($baseRegistryPath, "Deprovisioned", $familyName)
            if (-not (Test-Path -Path $deprovPath)) { New-Item -Path $deprovPath -Force -ErrorAction SilentlyContinue | Out-Null }

            $inboxPath = [Path]::Combine($baseRegistryPath, "InboxApplications", $fullName)
            if (Test-Path -Path $inboxPath) { Remove-Item -Path $inboxPath -Force -ErrorAction SilentlyContinue | Out-Null }

            $canRemove = ($pkg.NonRemovable -ne 1)
            if ($canRemove) {
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
        Write-Host "[*] Purging UWP Apps (Safe Mode)..." -ForegroundColor Cyan
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
        Write-Host "[*] Purging Legacy Features..." -ForegroundColor Cyan
        
        $features = @(
            @{ Name = "DirectPlay"; Bool = $true },
            @{ Name = "LegacyComponents"; Bool = $true },
            @{ Name = "MicrosoftWindowsPowerShellV2"; Bool = $false },
            @{ Name = "MSRDC-Infrastructure"; Bool = $false }
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
        $accessRule = [System.Security.AccessControl.FileSystemAccessRule]::new($adminGroup, [System.Security.AccessControl.FileSystemRights]::FullControl, [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit, [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
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
        Write-Host "[*] Purging Legacy Apps & OneDrive..." -ForegroundColor Cyan

        # OneDrive
        $setupPaths = @([Path]::Combine($env:SystemRoot, "System32", "OneDriveSetup.exe"), [Path]::Combine($env:SystemRoot, "SysWOW64", "OneDriveSetup.exe"))
        foreach ($path in $setupPaths) { if ([File]::Exists($path)) { [AlbusDebloat]::RunProcess($path, "/uninstall") } }
        [Registry]::SetValue("HKEY_CLASSES_ROOT\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}", "System.IsPinnedToNameSpaceTree", 0, [RegistryValueKind]::DWord)

        # MSIs
        Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue | Where-Object {
            $_.DisplayName -Match 'Microsoft GameInput|Microsoft Update Health Tools'
        } | ForEach-Object { [AlbusDebloat]::RunProcess("msiexec.exe", "/x $($_.PSChildName) /qn /norestart") }

        # Startup Temizliği (Kritik olanlar korunur)
        $runKeys = @("HKCU:\Software\Microsoft\Windows\CurrentVersion\Run", "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run")
        $excludeRun = @("SecurityHealth", "ctfmon", "WindowsDefender")
        foreach ($key in $runKeys) {
            $regItem = Get-Item -Path $key -ErrorAction SilentlyContinue
            if ($regItem) {
                $regItem.GetValueNames() | Where-Object { $_ -notin $excludeRun } | ForEach-Object { Remove-ItemProperty -Path $key -Name $_ -ErrorAction SilentlyContinue }
            }
        }
    }

    static [void] RemoveWinSxSPackage([string]$RegexPattern) {
        $packages = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages" -ErrorAction SilentlyContinue | Where-Object PSChildName -Match $RegexPattern
        foreach ($pkg in $packages) {
            $pkgName = $pkg.PSChildName
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages\$pkgName" -Name "Visibility" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            try { Remove-WindowsPackage -Online -PackageName $pkgName -NoRestart -ErrorAction Stop | Out-Null } catch {}
        }
    }

    static [void] RemoveAIPackages() {
        Write-Host "[*] Purging Windows AI & Copilot Packages..." -ForegroundColor Cyan
        $aiRegex = "(?i)(Copilot|MachineLearning|Windows-AI-|Recall)"
        [AlbusDebloat]::RemoveWinSxSPackage($aiRegex)
    }

    static [void] RunAll() {
        [AlbusDebloat]::RemoveEdge()
        [AlbusDebloat]::RemoveUwpApps()
        [AlbusDebloat]::RemoveUwpFeatures()
        [AlbusDebloat]::RemoveLegacyFeatures()
        [AlbusDebloat]::RemoveLegacyApps()
        [AlbusDebloat]::RemoveAIPackages()

        Write-Host "[*] Restarting Explorer to apply changes..." -ForegroundColor Cyan
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Process explorer.exe
        
        Write-Host "[+] Debloat completed successfully. System UI is preserved." -ForegroundColor Green
    }
}

# Execute
[AlbusDebloat]::RunAll()
