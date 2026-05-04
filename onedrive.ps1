# ── onedrive ──────────────────────────────────────────────
Write-Step 'removing onedrive'

function Remove-OneDrive {

    # HKU mount et
    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS | Out-Null
    }

    $exePaths = New-Object System.Collections.Generic.List[string]

    # fallback exe'ler (en güvenilir)
    $fallbackPaths = @(
        "$env:SystemRoot\System32\OneDriveSetup.exe",
        "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
    )

    # registry'den uninstall path çek
    Get-ChildItem 'HKU:\' -ErrorAction SilentlyContinue | ForEach-Object {

        $sid = $_.PSChildName

        # sadece gerçek user hive'ları targetla
        if ($sid -notmatch '^S-1-5-21-') { return }

        $regPath = "HKU:\$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe"

        try {
            $uninstallStr = (Get-ItemProperty -Path $regPath -ErrorAction Stop).UninstallString
        } catch {
            $uninstallStr = $null
        }

        if ($uninstallStr) {

            # --- SAFE PARSE ---
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

        # autorun temizle
        Remove-ItemProperty `
            -Path "HKU:\$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" `
            -Name 'OneDrive' `
            -ErrorAction SilentlyContinue

        # uninstall key temizle
        Remove-Item -Path $regPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    # fallback ekle
    foreach ($f in $fallbackPaths) {
        if (Test-Path $f) {
            $exePaths.Add($f) | Out-Null
        }
    }

    # unique
    $exePaths = $exePaths | Select-Object -Unique

    # uninstall çalıştır
    foreach ($exe in $exePaths) {
        try {
            Write-Step "uninstalling onedrive → $exe"
            Start-Process -FilePath $exe -ArgumentList '/uninstall' -Wait -NoNewWindow | Out-Null
        } catch {}
    }

    # ── provisioned package remove (çok önemli) ──
    try {
        Get-AppxProvisionedPackage -Online | Where-Object {
            $_.DisplayName -like '*OneDrive*'
        } | ForEach-Object {
            Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue
        }
    } catch {}

    # ── appx remove (user scope) ──
    try {
        Get-AppxPackage -AllUsers *OneDrive* | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    } catch {}

    # ── user kalıntıları ──
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

    # ── explorer sidebar kaldır ──
    $clsid = '{018D5C66-4533-4307-9B53-224DE2ED1FE6}'

    try {
        New-Item -Path "HKCR:\CLSID\$clsid" -Force | Out-Null
        Set-ItemProperty -Path "HKCR:\CLSID\$clsid" -Name 'System.IsPinnedToNameSpaceTree' -Value 0 -Type DWord
    } catch {}

    # ── wow64 da temizle ──
    try {
        New-Item -Path "HKCR:\Wow6432Node\CLSID\$clsid" -Force | Out-Null
        Set-ItemProperty -Path "HKCR:\Wow6432Node\CLSID\$clsid" -Name 'System.IsPinnedToNameSpaceTree' -Value 0 -Type DWord
    } catch {}

    Write-Step 'onedrive removal complete'
}

Remove-OneDrive
