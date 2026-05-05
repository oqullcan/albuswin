Write-Host "Albus-Playbook: Derin Sistem Temizliği Başlatılıyor..." -ForegroundColor Cyan

# ==========================================
# 1. BEYAZ LİSTE (Korunacak UWP Paketleri)
# Not: UWP Photos listeden çıkarıldı, yerine Klasik Görüntüleyici kurulacak.
# ==========================================
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

# ==========================================
# 2. UWP NÜKLEER TEMİZLİK (Copilot, Edge, Teams, Xbox vb. zaten burada silinecek)
# ==========================================
$baseRegistryPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore"
$windowsAppsPath = "$env:ProgramFiles\WindowsApps"

$packagesToRemove = Get-AppxPackage -AllUsers | Where-Object { 
    $_.IsFramework -eq $false -and
    -not (Test-ShouldKeep $_.PackageFullName) -and 
    -not (Test-ShouldKeep $_.PackageFamilyName) 
}

foreach ($pkg in $packagesToRemove) {
    $fullPackageName = $pkg.PackageFullName
    $packageFamilyName = $pkg.PackageFamilyName
    
    Write-Host "Kaldırılıyor (UWP): $($packageFamilyName)" -ForegroundColor Yellow

    try { Remove-AppxPackage -Package $fullPackageName -AllUsers -ErrorAction SilentlyContinue | Out-Null } catch {}
    try { Remove-AppxProvisionedPackage -Online -PackageName $fullPackageName -ErrorAction SilentlyContinue | Out-Null } catch {}

    # Fiziksel Klasör İmhası
    $packageFolderPath = Join-Path -Path $windowsAppsPath -ChildPath $fullPackageName
    if (Test-Path $packageFolderPath) {
        try { Remove-Item -Path $packageFolderPath -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }

    # Registry Bloklama
    $deprovisionedPath = "$baseRegistryPath\Deprovisioned\$packageFamilyName"
    if (-not (Test-Path -Path $deprovisionedPath)) {
        try { New-Item -Path $deprovisionedPath -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
    }
    $inboxAppsPath = "$baseRegistryPath\InboxApplications\$fullPackageName"
    if (Test-Path $inboxAppsPath) {
        try { Remove-Item -Path $inboxAppsPath -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
    }
}

# ==========================================
# 3. WINX MENÜ DÜZENLEMESİ (Terminal ve PowerShell)
# ==========================================
Write-Host "WinX Menüsü düzenleniyor..." -ForegroundColor Cyan
foreach ($g3 in (Get-Item 'C:\Users\*\AppData\Local\Microsoft\Windows\WinX\Group3','C:\Users\Default\AppData\Local\Microsoft\Windows\WinX\Group3' -ErrorAction SilentlyContinue)) {
    Get-ChildItem $g3.FullName -Filter '*Terminal*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    $d = $g3.FullName; $ps = $env:windir + '\System32\WindowsPowerShell\v1.0\powershell.exe'; $cmd = $env:windir + '\System32\cmd.exe'; $wsh = New-Object -ComObject WScript.Shell
    $lnk = $wsh.CreateShortcut($d + '\01 - Windows PowerShell.lnk'); $lnk.TargetPath = $ps; $lnk.Save()
    $lnk = $wsh.CreateShortcut($d + '\01b - Windows PowerShell.lnk'); $lnk.TargetPath = $ps; $lnk.Save()
    $p = $d + '\01b - Windows PowerShell.lnk'; $b = [IO.File]::ReadAllBytes($p); $b[0x15] = $b[0x15] -bor 0x20; [IO.File]::WriteAllBytes($p, $b)
    $lnk = $wsh.CreateShortcut($d + '\02 - Command Prompt.lnk'); $lnk.TargetPath = $cmd; $lnk.Save()
    $lnk = $wsh.CreateShortcut($d + '\02b - Command Prompt.lnk'); $lnk.TargetPath = $cmd; $lnk.Save()
    $p = $d + '\02b - Command Prompt.lnk'; $b = [IO.File]::ReadAllBytes($p); $b[0x15] = $b[0x15] -bor 0x20; [IO.File]::WriteAllBytes($p, $b)
}

# ==========================================
# 4. WSL (Windows Subsystem for Linux) İMHASI
# ==========================================
Write-Host "WSL Bileşenleri siliniyor..." -ForegroundColor Cyan
try { Stop-Service -Name "WslService" -Force -ErrorAction SilentlyContinue } catch {}
taskkill /f /im wslservice.exe > $null 2>&1
taskkill /f /im wsl.exe > $null 2>&1
Set-Service -Name "WslService" -StartupType Disabled -ErrorAction SilentlyContinue

@('wsl.exe','wslconfig.exe','wslg.exe','wslhost.exe', 'lxss\LxssManager.dll') | ForEach-Object { 
    $p = Join-Path $env:windir ("System32\" + $_)
    Remove-Item $p -Force -ErrorAction SilentlyContinue 
}

$k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{B2B4A4D1-2754-4140-A2EB-9A76D9D7CDC6}'
if ((Get-ItemProperty -Path $k -ErrorAction SilentlyContinue).'(Default)' -eq 'Linux') { Remove-Item -Path $k -Force -ErrorAction SilentlyContinue }

Remove-Item ($env:ProgramData + '\Microsoft\Windows\Start Menu\Programs\WSL') -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem ($env:ProgramData + '\Microsoft\Windows\Start Menu\Programs') -Filter '*Linux*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem ($env:ProgramData + '\Microsoft\Windows\Start Menu\Programs') -Filter '*WSL*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem 'C:\Users\*\AppData\Roaming\Microsoft\Windows\Start Menu\Programs' -Filter '*Linux*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem 'C:\Users\*\AppData\Roaming\Microsoft\Windows\Start Menu\Programs' -Filter '*WSL*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

# ==========================================
# 5. DENETİM MASASI ARTIKLARI (Copilot, Edge, Teams)
# ==========================================
Write-Host "Kalıntı Kayıt Defteri girişleri temizleniyor..." -ForegroundColor Cyan
$paths = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
foreach ($p in $paths) {
    Get-ChildItem $p -ErrorAction SilentlyContinue | ForEach-Object {
        $dn = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DisplayName
        if ($dn -match '(?i)^copilot$' -or $dn -match '(?i)teams meeting add-in') {
            Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ==========================================
# 6. GEREKSİZ KISAYOLLAR (Outlook vb.)
# ==========================================
Write-Host "İstenmeyen Başlat Menüsü kısayolları temizleniyor..." -ForegroundColor Cyan
Remove-Item "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Outlook (new).lnk" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Outlook.lnk" -Force -ErrorAction SilentlyContinue
Get-ChildItem 'C:\Users\*\AppData\Roaming\Microsoft\Windows\Start Menu\Programs' -Filter 'Outlook*' -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.lnk' } | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem 'C:\Users\Default\AppData\Roaming\Microsoft\Windows\Start Menu\Programs' -Filter 'Outlook*' -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.lnk' } | Remove-Item -Force -ErrorAction SilentlyContinue

# ==========================================
# 7. KLASİK FOTOĞRAF GÖRÜNTÜLEYİCİSİ AKTİVASYONU
# ==========================================
Write-Host "Klasik Windows Fotoğraf Görüntüleyicisi aktifleştiriliyor..." -ForegroundColor Cyan
$base='HKLM:\SOFTWARE\Classes\Applications\photoviewer.dll'
try {
    New-Item "$base\shell\open\command" -Force -ErrorAction SilentlyContinue | Out-Null
    New-Item "$base\shell\open\DropTarget" -Force -ErrorAction SilentlyContinue | Out-Null
    New-Item "$base\shell\print\command" -Force -ErrorAction SilentlyContinue | Out-Null
    New-Item "$base\shell\print\DropTarget" -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty "$base\shell\open" -Name 'MuiVerb' -Value '@photoviewer.dll,-3043' -ErrorAction SilentlyContinue
    $cmd='%SystemRoot%\System32\rundll32.exe "%ProgramFiles%\Windows Photo Viewer\PhotoViewer.dll", ImageView_Fullscreen %1'
    reg add "HKLM\SOFTWARE\Classes\Applications\photoviewer.dll\shell\open\command" /ve /t REG_EXPAND_SZ /d $cmd /f > $null 2>&1
    Set-ItemProperty "$base\shell\open\DropTarget" -Name 'Clsid' -Value '{FFE2A43C-56B9-4bf5-9A79-CC6D4285608A}' -ErrorAction SilentlyContinue
    reg add "HKLM\SOFTWARE\Classes\Applications\photoviewer.dll\shell\print\command" /ve /t REG_EXPAND_SZ /d $cmd /f > $null 2>&1
    Set-ItemProperty "$base\shell\print\DropTarget" -Name 'Clsid' -Value '{60fd46de-f830-4894-a628-6fa81bc0190d}' -ErrorAction SilentlyContinue
} catch {}

Write-Host "Albus-Playbook Temizlik Modülü Tamamlandı!" -ForegroundColor Green
