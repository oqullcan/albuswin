$ErrorActionPreference = 'Stop'
Clear-Host
Write-Host "====================================" -ForegroundColor Cyan
Write-Host " ALBUS VENTOY USB AUTOMATIC BUILDER " -ForegroundColor Cyan
Write-Host "====================================" -ForegroundColor Cyan

# 1. USB Seçimi
$USBs = Get-Volume | Where-Object { $_.DriveType -eq 'Removable' -and $_.DriveLetter -ne $null }
if ($USBs.Count -eq 0) { 
    Write-Host "CRITICAL: No USB drive detected. Please plug in a USB and try again." -ForegroundColor Red
    Pause; Exit
}

Write-Host "`n--- Available USB Drives ---" -ForegroundColor Yellow
$USBs | Select-Object DriveLetter, FileSystemLabel, SizeRemaining, Size | Format-Table
$ans = Read-Host "Enter the Drive Letter of the USB you want to FORMAT (e.g. E)"
$DriveLetter = $ans.Trim().Replace(":", "").ToUpper()

if (-not ($USBs.DriveLetter -contains $DriveLetter)) {
    Write-Host "Invalid Drive Letter selected. Exiting." -ForegroundColor Red
    Pause; Exit
}

Write-Host "WARNING: ALL DATA ON DRIVE ${DriveLetter}:\ WILL BE ERASED!" -ForegroundColor Red
$confirm = Read-Host "Are you sure? Type 'YES' to continue"
if ($confirm -ne 'YES') { Exit }

# 2. Ventoy İndirme
Write-Host "`n[1/4] Fetching latest Ventoy release from GitHub..." -ForegroundColor Cyan
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Rel = Invoke-RestMethod "https://api.github.com/repos/ventoy/Ventoy/releases/latest" -UseBasicParsing
$Asset = $Rel.assets | Where-Object Name -match "windows.zip$"
$Zip = "$env:TEMP\ventoy.zip"
$Extract = "$env:TEMP\ventoy_extract"

Write-Host "[2/4] Downloading $($Asset.name)..." -ForegroundColor Cyan
Invoke-WebRequest $Asset.browser_download_url -OutFile $Zip -UseBasicParsing
if (Test-Path $Extract) { Remove-Item $Extract -Recurse -Force }
Expand-Archive -Path $Zip -DestinationPath $Extract -Force
$V2D = Get-ChildItem "$Extract\*\Ventoy2Disk.exe" | Select-Object -First 1

# 3. Ventoy Kurulumu
Write-Host "[3/4] Installing Ventoy to Drive ${DriveLetter}:\ (This may take a few moments)..." -ForegroundColor Cyan
$ArgList = "VTOYCLI /I /Drive:${DriveLetter}"
$Process = Start-Process -FilePath $V2D.FullName -ArgumentList $ArgList -NoNewWindow -Wait -PassThru

Write-Host "Waiting for Ventoy volume to initialize..." -ForegroundColor Yellow
Start-Sleep -Seconds 6

$VentoyVol = Get-Volume | Where-Object { $_.FileSystemLabel -match "Ventoy" } | Select-Object -First 1
if (-not $VentoyVol) {
    Write-Host "Ventoy installation volume not found! Creating config locally on Desktop as fallback." -ForegroundColor Red
    $BuildDir = "$PSScriptRoot\Ventoy-Albus-USB"
} else {
    $BuildDir = "$($VentoyVol.DriveLetter):\"
    Write-Host "Ventoy successfully installed! Config will be applied to $($BuildDir)" -ForegroundColor Green
}

# 4. Albus Config Yazılması
Write-Host "[4/4] Writing Albus USB Config..." -ForegroundColor Cyan

if (-not (Test-Path $BuildDir)) { New-Item -Path $BuildDir -ItemType Directory -Force | Out-Null }
New-Item -Path "$BuildDir\ventoy\albus" -ItemType Directory -Force | Out-Null
New-Item -Path "$BuildDir\ISOs" -ItemType Directory -Force | Out-Null

$VentoyJson = @'
{
  "auto_install": [
    {
      "parent": "/ISOs",
      "template": ["/ventoy/albus/autounattend.xml"],
      "autosel": 1
    }
  ]
}
'@
$VentoyJson | Set-Content -Path "$BuildDir\ventoy\ventoy.json" -Encoding UTF8

$AutoUnattendXml = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <Reseal>
                <Mode>OOBE</Mode>
            </Reseal>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Home</NetworkLocation>
                <ProtectYourPC>3</ProtectYourPC>
                <SkipMachineOOBE>true</SkipMachineOOBE>
                <SkipUserOOBE>true</SkipUserOOBE>
            </OOBE>
            <UserAccounts>
                <LocalAccounts>
                    <LocalAccount wcm:action="add">
                        <Group>Administrators</Group>
                        <Name>Albus</Name>
                        <Password>
                            <PlainText>true</PlainText>
                            <Value></Value>
                        </Password>
                    </LocalAccount>
                </LocalAccounts>
            </UserAccounts>
            <AutoLogon>
                <Enabled>true</Enabled>
                <LogonCount>9999999</LogonCount>
                <Username>Albus</Username>
                <Password>
                    <PlainText>true</PlainText>
                    <Value></Value>
                </Password>
            </AutoLogon>
            <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Description>Create Albus Playbook Shortcut on Desktop</Description>
                    <CommandLine>powershell -NoProfile -Command "$wshell = New-Object -ComObject WScript.Shell; $s = $wshell.CreateShortcut('C:\Users\Public\Desktop\Albus-PB.lnk'); $s.TargetPath = 'powershell.exe'; $s.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command &quot;irm https://raw.githubusercontent.com/oqullcan/blablabla/refs/heads/main/run.ps1 | iex&quot;'; $s.IconLocation = 'powershell.exe,0'; $s.Save()"</CommandLine>
                </SynchronousCommand>
            </FirstLogonCommands>
        </component>
    </settings>
    <settings pass="specialize">
        <component name="Microsoft-Windows-SQMApi" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <CEIPEnabled>0</CEIPEnabled>
        </component>
        <component name="Microsoft-Windows-ErrorReportingCore" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <DisableWER>1</DisableWER>
        </component>
        <component name="Microsoft-Windows-Security-SPP-UX" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <SkipAutoActivation>true</SkipAutoActivation>
        </component>
        <component name="Microsoft-Windows-UnattendedJoin" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <Identification>
                <JoinWorkgroup>WORKGROUP</JoinWorkgroup>
            </Identification>
        </component>
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>net accounts /maxpwage:unlimited</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>2</Order><Path>reg add "HKU\.DEFAULT\Software\Policies\Microsoft\Windows\DriverSearching" /v "DontPromptForWindowsUpdate" /t REG_DWORD /d "1" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>3</Order><Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" /v "DontPromptForWindowsUpdate" /t REG_DWORD /d "1" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>4</Order><Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" /v "SearchOrderConfig" /t REG_DWORD /d 0 /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>5</Order><Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v "ExcludeWUDriversInQualityUpdate" /t REG_DWORD /d "1" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>6</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata" /v "PreventDeviceMetadataFromNetwork" /t REG_DWORD /d "1" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>7</Order><Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" /v "PreventDeviceMetadataFromNetwork" /t REG_DWORD /d "1" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>8</Order><Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v "NoAutoUpdate" /t REG_DWORD /d "1" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>9</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" /v "FlightSettingsMaxPauseDays" /t REG_DWORD /d "5269" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>10</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" /v "PauseFeatureUpdatesStartTime" /t REG_SZ /d "2023-08-17T12:47:51Z" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>11</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" /v "PauseFeatureUpdatesEndTime" /t REG_SZ /d "2038-01-19T03:14:07Z" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>12</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" /v "PauseQualityUpdatesStartTime" /t REG_SZ /d "2023-08-17T12:47:51Z" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>13</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" /v "PauseQualityUpdatesEndTime" /t REG_SZ /d "2038-01-19T03:14:07Z" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>14</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" /v "PauseUpdatesStartTime" /t REG_SZ /d "2023-08-17T12:47:51Z" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>15</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" /v "PauseUpdatesExpiryTime" /t REG_SZ /d "2038-01-19T03:14:07Z" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>16</Order><Path>reg add "HKLM\SYSTEM\ControlSet001\Services\DiagTrack" /v "Start" /t REG_DWORD /d "4" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>17</Order><Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "AllowTelemetry" /t REG_DWORD /d "0" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>18</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" /v "AllowTelemetry" /t REG_DWORD /d "0" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>19</Order><Path>reg add "HKLM\SYSTEM\ControlSet001\Control\Session Manager" /v "DisableWpbtExecution" /t REG_DWORD /d "1" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>20</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Communications" /v "ConfigureChatAutoInstall" /t REG_DWORD /d "0" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>21</Order><Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Chat" /v "ChatIcon" /t REG_DWORD /d "2" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>22</Order><Path>reg add "HKLM\SYSTEM\ControlSet001\Control\BitLocker" /v "PreventDeviceEncryption" /t REG_DWORD /d "1" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>23</Order><Path>reg add "HKLM\SYSTEM\ControlSet001\Control\CI\Policy" /v "VerifiedAndReputablePolicyState" /t REG_DWORD /d "0" /f</Path></RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg add "HKLM\SYSTEM\Setup\LabConfig" /v "BypassTPMCheck" /t REG_DWORD /d 1 /f</Path><Description>Add BypassTPMCheck</Description></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>2</Order><Path>reg add "HKLM\SYSTEM\Setup\LabConfig" /v "BypassRAMCheck" /t REG_DWORD /d 1 /f</Path><Description>Add BypassRAMCheck</Description></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>3</Order><Path>reg add "HKLM\SYSTEM\Setup\LabConfig" /v "BypassSecureBootCheck" /t REG_DWORD /d 1 /f</Path><Description>Add BypassSecureBootCheck</Description></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>4</Order><Path>reg add "HKLM\SYSTEM\Setup\LabConfig" /v "BypassCPUCheck" /t REG_DWORD /d 1 /f</Path><Description>Add BypassCPUCheck</Description></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>5</Order><Path>reg add "HKLM\SYSTEM\Setup\LabConfig" /v "BypassStorageCheck" /t REG_DWORD /d 1 /f</Path><Description>Add BypassStorageCheck</Description></RunSynchronousCommand>
            </RunSynchronous>
            <Diagnostics>
                <OptIn>false</OptIn>
            </Diagnostics>
            <DynamicUpdate>
                <Enable>false</Enable>
                <WillShowUI>Never</WillShowUI>
            </DynamicUpdate>
            <UserData>
                <ProductKey>
                    <Key></Key>
                    <WillShowUI>Never</WillShowUI>
                </ProductKey>
                <AcceptEula>true</AcceptEula>
            </UserData>
        </component>
    </settings>
</unattend>
'@
$AutoUnattendXml | Set-Content -Path "$BuildDir\ventoy\albus\autounattend.xml" -Encoding UTF8

Write-Host "`n========================================================" -ForegroundColor Green
Write-Host " ALL DONE! VENTOY & ALBUS USB IS READY." -ForegroundColor Green
if ($VentoyVol) {
    Write-Host " Just place your Windows .ISO files into $($BuildDir)ISOs" -ForegroundColor Cyan
} else {
    Write-Host " Config was placed in $BuildDir. Move to your Ventoy USB!" -ForegroundColor Cyan
}
Write-Host "========================================================" -ForegroundColor Green
