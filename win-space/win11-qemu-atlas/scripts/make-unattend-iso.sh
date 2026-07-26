#!/usr/bin/env bash
# Builds PROVISION.iso: Autounattend.xml + guest bootstrap scripts.
# Windows Setup auto-scans the root of every removable/optical volume for
# Autounattend.xml, so a tiny second CD-ROM is the cleanest injection method
# (no repacking / re-signing of the user's ISO).
set -euo pipefail

VM_DIR=${VM_DIR:-/mnt/vm}
MEDIA="$VM_DIR/media"
STAGE="$MEDIA/root"
EDITION=${WINDOWS_EDITION:-Windows 11 Pro}
ATLAS_MODE=${ATLAS_MODE:-stage}
BEACON_PORT=${BEACON_PORT:-8099}
ADMIN_USER=${ADMIN_USER:-atlas}
ADMIN_PASS=${ADMIN_PASS:-Atlas!2026}
IMAGE_INDEX=$(cat "$MEDIA/image-index.txt" 2>/dev/null || echo 1)

rm -rf "$STAGE"; mkdir -p "$STAGE/scripts"

echo "==> Generating Autounattend.xml (edition='$EDITION', index=$IMAGE_INDEX)"

# Windows stores AdministratorPassword as base64 of UTF-16LE (value + "Password").
b64pw() { printf '%s' "$1Password" | iconv -f UTF-8 -t UTF-16LE | base64 -w0; }
PW_B64=$(b64pw "$ADMIN_PASS")

cat > "$STAGE/Autounattend.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">

  <!-- ==================== 1. WinPE ==================== -->
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE"
               processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage>
      <InputLocale>0409:00000409</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>

    <component name="Microsoft-Windows-PnpCustomizationsWinPE"
               processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <!-- virtio storage driver, or Setup reports "no drives were found" -->
      <DriverPaths>
        <PathAndCredentials wcm:action="add" wcm:keyValue="1" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Path>E:\\amd64\\w11</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="2" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Path>F:\\amd64\\w11</Path>
        </PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="3" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Path>G:\\amd64\\w11</Path>
        </PathAndCredentials>
      </DriverPaths>
    </component>

    <component name="Microsoft-Windows-Setup"
               processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">

      <RunSynchronous>
        <!-- WinPE is alive. curl.exe ships in modern WinPE; if it is missing
             this command fails harmlessly and the host falls back to detecting
             disk-write activity instead. -->
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>1</Order><Description>beacon: winpe</Description>
          <Path>cmd /c curl.exe -m 10 -s "http://10.0.2.2:${BEACON_PORT}/beacon?stage=winpe" &amp; exit /b 0</Path>
          <WillReboot>Never</WillReboot>
        </RunSynchronousCommand>
        <!-- Hardware gates: harmless on this VM (it has TPM 2.0 + SecureBoot),
             but keeps the run alive if a runner lands without a TPM device. -->
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>2</Order><Description>Bypass compat gates</Description>
          <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>3</Order><Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>4</Order><Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>5</Order><Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>6</Order><Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <!-- 25H2 OOBE otherwise forces an MSA + network. We need a local admin. -->
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>7</Order><Description>Allow local account at OOBE</Description>
          <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassNRO /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>8</Order><Path>reg add HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
      </RunSynchronous>

      <DiskConfiguration>
        <WillShowUI>OnError</WillShowUI>
        <Disk wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>          <!-- clean installation -->
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <Order>1</Order><PartitionID>1</PartitionID>
              <Label>System</Label><Format>FAT32</Format>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>2</Order><PartitionID>2</PartitionID>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>3</Order><PartitionID>3</PartitionID>
              <Label>Windows</Label><Letter>C</Letter><Format>NTFS</Format>
            </ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>

      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
              <Key>/IMAGE/NAME</Key>
              <Value>${EDITION}</Value>
            </MetaData>
          </InstallFrom>
          <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
          <WillShowUI>OnError</WillShowUI>
        </OSImage>
      </ImageInstall>

      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>Atlas Lab</FullName>
        <Organization>CI</Organization>
        <!-- Generic KMS client setup key: selects the edition, activates nothing. -->
        <ProductKey><Key>W269N-WFGWX-YVC9B-4J6C9-T83GX</Key><WillShowUI>OnError</WillShowUI></ProductKey>
      </UserData>
    </component>
  </settings>

  <!-- ==================== 2. specialize ==================== -->
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <ComputerName>ATLAS-LAB</ComputerName>
      <TimeZone>UTC</TimeZone>
    </component>

    <component name="Microsoft-Windows-Deployment"
               processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>1</Order><Description>beacon: specialize</Description>
          <Path>cmd /c curl.exe -m 10 -s "http://10.0.2.2:${BEACON_PORT}/beacon?stage=specialize" 1&gt;nul 2&gt;nul</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>2</Order><Description>Copy provisioning payload to C:\\Atlas</Description>
          <Path>cmd /c for %i in (D E F G H) do @if exist %i:\\scripts\\guest-bootstrap.ps1 xcopy /e /i /y %i:\\scripts C:\\Atlas\\scripts</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>3</Order><Description>Install virtio guest drivers</Description>
          <Path>cmd /c for %i in (E F G) do @if exist %i:\\amd64\\w11 pnputil /add-driver %i:\\amd64\\w11\\*.inf /install /subdirs</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>

  <!-- ==================== 3. oobeSystem ==================== -->
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">

      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>

      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <Name>${ADMIN_USER}</Name>
            <DisplayName>${ADMIN_USER}</DisplayName>
            <Group>Administrators</Group>     <!-- administrator privileges -->
            <Password><Value>${PW_B64}</Value><PlainText>false</PlainText></Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>

      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>${ADMIN_USER}</Username>
        <LogonCount>5</LogonCount>
        <Password><Value>${PW_B64}</Value><PlainText>false</PlainText></Password>
      </AutoLogon>

      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>1</Order><Description>beacon: firstlogon</Description>
          <CommandLine>cmd /c curl.exe -m 10 -s "http://10.0.2.2:${BEACON_PORT}/beacon?stage=firstlogon"</CommandLine>
          <RequiresUserInput>false</RequiresUserInput>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>2</Order><Description>Atlas bootstrap</Description>
          <CommandLine>powershell -NoProfile -ExecutionPolicy Bypass -File C:\\Atlas\\scripts\\guest-bootstrap.ps1 -BeaconPort ${BEACON_PORT} -AtlasMode ${ATLAS_MODE}</CommandLine>
          <RequiresUserInput>false</RequiresUserInput>
        </SynchronousCommand>
      </FirstLogonCommands>

      <TimeZone>UTC</TimeZone>
    </component>
  </settings>
</unattend>
XML

# Runtime config the guest reads instead of us templating five more files.
cat > "$STAGE/scripts/lab.json" <<JSON
{
  "beacon_port": ${BEACON_PORT},
  "beacon_host": "10.0.2.2",
  "atlas_mode": "${ATLAS_MODE}",
  "edition": "${EDITION}",
  "admin_user": "${ADMIN_USER}"
}
JSON

cp scripts/guest/guest-bootstrap.ps1 "$STAGE/scripts/"
cp scripts/guest/atlas-preflight.ps1 "$STAGE/scripts/"
cp scripts/guest/Launch-Atlas.cmd    "$STAGE/scripts/"
cp scripts/guest/README-DESKTOP.txt  "$STAGE/scripts/"

echo "==> XML well-formedness"
python3 - "$STAGE/Autounattend.xml" <<'PY'
import sys, xml.dom.minidom as m
try:
    m.parse(sys.argv[1])
    print("    Autounattend.xml parses cleanly")
except Exception as e:
    print(f"::error::Autounattend.xml is malformed: {e}"); sys.exit(1)
PY

cp "$STAGE/Autounattend.xml" "$MEDIA/autounattend.xml"   # artifact copy

echo "==> Building PROVISION.iso"
genisoimage -quiet -J -r -V "PROVISION" -o "$MEDIA/provision.iso" "$STAGE"
ls -lh "$MEDIA/provision.iso"
