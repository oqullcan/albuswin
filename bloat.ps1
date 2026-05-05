$keepList = @(
    '*CBS*'
    '*Microsoft.AV1VideoExtension*'
    '*Microsoft.AVCEncoderVideoExtension*'
    '*Microsoft.HEIFImageExtension*'
    '*Microsoft.HEVCVideoExtension*'
    '*Microsoft.MPEG2VideoExtension*'
    '*Microsoft.Paint*'
    '*Microsoft.RawImageExtension*'
    '*Microsoft.SecHealthUI*'
    '*Microsoft.VP9VideoExtensions*'
    '*Microsoft.WebMediaExtensions*'
    '*Microsoft.WebpImageExtension*'
    '*Microsoft.Windows.Photos*'
    '*Microsoft.Windows.ShellExperienceHost*'
    '*Microsoft.Windows.StartMenuExperienceHost*'
    '*Microsoft.WindowsNotepad*'
    '*Microsoft.WindowsStore*'
    '*Microsoft.ImmersiveControlPanel*'
    '*windows.immersivecontrolpanel*'
    '*Microsoft.WindowsCalculator*'
)

function Test-ShouldKeep {
    param([string]$Name)
    foreach ($p in $keepList) {
        if ($Name -like $p) { return $true }
    }
    return $false
}

$baseRegistryPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore"
$windowsAppsPath = "$env:ProgramFiles\WindowsApps"

$packagesToRemove = Get-AppxPackage -AllUsers | Where-Object { 
    -not (Test-ShouldKeep $_.PackageFullName) -and 
    -not (Test-ShouldKeep $_.PackageFamilyName) 
}

foreach ($pkg in $packagesToRemove) {
    $fullPackageName = $pkg.PackageFullName
    $packageFamilyName = $pkg.PackageFamilyName

    Write-Host "Siliniyor: $($fullPackageName)"

    # 1. Standart Kaldırma
    Remove-AppxPackage -Package $fullPackageName -AllUsers -ErrorAction SilentlyContinue | Out-Null
    Remove-AppxProvisionedPackage -Online -PackageName $fullPackageName -NoRestart -ErrorAction SilentlyContinue | Out-Null

    # 2. Doğrudan Fiziksel İmha (TrustedInstaller yetkisiyle)
    $packageFolderPath = Join-Path -Path $windowsAppsPath -ChildPath $fullPackageName
    if (Test-Path $packageFolderPath) {
        Remove-Item -Path $packageFolderPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 3. Registry Temizliği
    $deprovisionedPath = "$baseRegistryPath\Deprovisioned\$packageFamilyName"
    if (-not (Test-Path -Path $deprovisionedPath)) {
        New-Item -Path $deprovisionedPath -Force -ErrorAction SilentlyContinue | Out-Null
    }

    $inboxAppsPath = "$baseRegistryPath\InboxApplications\$fullPackageName"
    if (Test-Path $inboxAppsPath) {
        Remove-Item -Path $inboxAppsPath -Force -ErrorAction SilentlyContinue | Out-Null
    }

    if ($null -ne $pkg.PackageUserInformation) {
        foreach ($userInfo in $pkg.PackageUserInformation) {
            $userSid = $userInfo.UserSecurityID.SID
            $endOfLifePath = "$baseRegistryPath\EndOfLife\$userSid\$fullPackageName"
            New-Item -Path $endOfLifePath -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

pause
