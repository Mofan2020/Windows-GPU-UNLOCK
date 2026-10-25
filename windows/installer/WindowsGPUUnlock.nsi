; Copyright (C) 2026 Windows GPU UNLOCK contributors. GPL-2.0-only.
;
; Builds the double-click installer.
;
; The executable itself is small. It shows the notes, asks for the
; administrator token it needs, and then hands over to the PowerShell
; installer, which does the detection, the downloads and the staging. The
; firmware assets are not bundled: NVIDIA's licence does not allow
; redistributing them, so they are generated on the user's machine at
; install time from pinned public inputs.

!ifndef VERSION
  !define VERSION "1.0.0"
!endif

; The product version in the resources has to be a plain number of four
; parts. A version with a suffix, like 1.0.0-dev, is only used for the
; name that the user sees.
!ifndef PRODUCT_VERSION
  !define PRODUCT_VERSION "${VERSION}.0"
!endif

!ifndef PAYLOAD
  !define PAYLOAD "..\..\build\payload"
!endif

!ifndef HELPER
  !define HELPER "..\..\build\helper"
!endif

!define PRODUCT "Windows GPU UNLOCK"
!define PUBLISHER "Windows GPU UNLOCK contributors"
!define UNINSTKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\WindowsGPUUnlock"

Name "${PRODUCT} ${VERSION}"
OutFile "WindowsGPUUnlock-${VERSION}-setup.exe"
Unicode true
InstallDir "$PROGRAMFILES64\WindowsGPUUnlock"
InstallDirRegKey HKLM "Software\WindowsGPUUnlock" "InstallDir"
RequestExecutionLevel admin
ShowInstDetails show
ShowUninstDetails show
SetCompressor /SOLID lzma

VIProductVersion "${PRODUCT_VERSION}"
VIAddVersionKey "ProductName" "${PRODUCT}"
VIAddVersionKey "CompanyName" "${PUBLISHER}"
VIAddVersionKey "FileDescription" "${PRODUCT} installer"
VIAddVersionKey "FileVersion" "${PRODUCT_VERSION}"
VIAddVersionKey "LegalCopyright" "GPL-2.0-only"
VIAddVersionKey "ProductVersion" "${PRODUCT_VERSION}"

!include "MUI2.nsh"
!include "FileFunc.nsh"

!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\Uninstall.exe"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

Function .onInit
  ; The installer writes to the EFI system partition and edits the boot
  ; configuration, both of which need the administrator token. The manifest
  ; requests it, but check as well so the failure is clear rather than
  ; mysterious.
  IfErrors 0 +2
  MessageBox MB_ICONSTOP "The installer could not obtain administrator rights. Right-click the file and choose 'Run as administrator'."
  Abort
FunctionEnd

Section "Install"
  SetOutPath "$INSTDIR"

  ; The scripts that do the work.
  File "..\installer\Invoke-Installer.ps1"
  File "..\installer\Install-GpuUnlock.ps1"
  File "..\installer\Installer-Common.ps1"
  File "..\installer\Detect-Hardware.ps1"
  File "..\installer\Test-Preconditions.ps1"
  File "..\installer\Get-FirmwareAssets.ps1"

  ; The EFI application. It is small, and it is ours, so it can be bundled.
  File /oname=payload\UNLOCK.EFI "${PAYLOAD}\UNLOCK.EFI"

  ; The helper that reads the zstd compressed firmware package. The tar.exe
  ; of Windows cannot do that, so the helper is part of the installer.
  File /oname=zstdcat.exe "${HELPER}\zstdcat.exe"

  ; The uninstaller is the same script in reverse.
  WriteUninstaller "$INSTDIR\Uninstall.exe"

  ; Record where the scripts live so the uninstaller can find them.
  WriteRegStr HKLM "Software\WindowsGPUUnlock" "InstallDir" "$INSTDIR"

  WriteRegStr HKLM "${UNINSTKEY}" "DisplayName" "${PRODUCT}"
  WriteRegStr HKLM "${UNINSTKEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "${UNINSTKEY}" "Publisher" "${PUBLISHER}"
  WriteRegStr HKLM "${UNINSTKEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKLM "${UNINSTKEY}" "InstallLocation" "$INSTDIR"
  WriteRegDWORD HKLM "${UNINSTKEY}" "NoModify" 1
  WriteRegDWORD HKLM "${UNINSTKEY}" "NoRepair" 1

  ; Run the installer. It shows the notes, checks the machine, downloads the
  ; firmware inputs and stages the files.
  DetailPrint "Running the installer..."
  ExecWait '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\Invoke-Installer.ps1" -PayloadDirectory "$INSTDIR\payload"' $0
  ${If} $0 != 0
    MessageBox MB_ICONSTOP "The installation did not complete. Nothing was changed on this machine. See the messages above for the reason."
    Abort
  ${EndIf}

  ; The staged files live on the EFI system partition, not under $INSTDIR,
  ; so the uninstaller has to remove them itself. Record that.
  WriteRegStr HKLM "Software\WindowsGPUUnlock" "Staged" "1"
SectionEnd

Section "Uninstall"
  ; Ask the PowerShell installer to reverse what it did: remove the boot
  ; entry and the staged files on the EFI partition.
  IfFileExists "$INSTDIR\Install-GpuUnlock.ps1" 0 +2
  ExecWait '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\Install-GpuUnlock.ps1" -Action Uninstall' $0

  Delete "$INSTDIR\payload\UNLOCK.EFI"
  Delete "$INSTDIR\zstdcat.exe"
  Delete "$INSTDIR\Invoke-Installer.ps1"
  Delete "$INSTDIR\Install-GpuUnlock.ps1"
  Delete "$INSTDIR\Installer-Common.ps1"
  Delete "$INSTDIR\Detect-Hardware.ps1"
  Delete "$INSTDIR\Test-Preconditions.ps1"
  Delete "$INSTDIR\Get-FirmwareAssets.ps1"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR\payload"
  RMDir "$INSTDIR"

  DeleteRegKey HKLM "${UNINSTKEY}"
  DeleteRegKey HKLM "Software\WindowsGPUUnlock"
SectionEnd
