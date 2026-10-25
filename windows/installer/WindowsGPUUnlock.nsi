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
;
; Everything the PowerShell installer prints goes into a log file next to
; the other files. The window that shows the output can end up behind
; another one, and a message that is gone with the window is of no use to
; anybody, so the log is the record and it is opened at the end.

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
!define LOGFILE "install.log"

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
!include "LogicLib.nsh"

!define MUI_ABORTWARNING

; The notes are on the welcome page, so that they are read before anything
; is done. The long version is in the log and in the documentation.
!define MUI_WELCOMEPAGE_TITLE "${PRODUCT} ${VERSION}"
!define MUI_WELCOMEPAGE_TEXT "This installer unlocks the FP16 and BF16 tensor instruction rate on NVIDIA GeForce RTX 30-series cards (GA102, GA103, GA104, GA106 - the RTX 3090, 3080, 3070 and 3060 families).`r`n`r`nBEFORE YOU CONTINUE, READ THIS:`r`n`r`n1. Secure Boot must be OFF in your BIOS. The application is not signed, so a firmware that enforces Secure Boot will refuse to load it.`r`n`r`n2. Windows Fast Startup must be OFF, so that a shutdown really powers the card down. Run: powercfg /h off`r`n`r`n3. If BitLocker protects your Windows volume, suspend it first. Run: manage-bde -protectors -disable C:`r`n`r`n4. The card that is unlocked must NOT drive the display. Use a machine with an integrated GPU and keep the screen plugged into it.`r`n`r`n5. The installer is not signed, so Windows may warn about an unknown publisher.`r`n`r`n6. About 100 MB is downloaded from NVIDIA and the CachyOS archive. The NVIDIA firmware files are not part of this package, because NVIDIA's licence does not allow it; they are generated on this machine and checked against their SHA-256.`r`n`r`nThis is experimental. It writes to the card's firmware and to its registers. Keep a bootable USB handy, and do not use it on a machine you depend on for work."

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
  ; requests it, but check as well so that the failure is clear rather than
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

  ; The log is started here, before anything else happens, so that a file
  ; with this name on the disk means the installer really did run.
  Delete "$INSTDIR\${LOGFILE}"
  ClearErrors
  FileOpen $2 "$INSTDIR\${LOGFILE}" w
  IfErrors log_open_failed
    FileWrite $2 "The installer started on this machine."
    FileWrite $2 ""
  FileClose $2
  Goto log_opened

  log_open_failed:
  log_opened:

  ; Find PowerShell. The installer is a 32 bit program, so the system
  ; directory of a 64 bit Windows is the 32 bit one. The 32 bit PowerShell
  ; is there as well, but the 64 bit one is the better choice.
  StrCpy $0 "$SYSDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
  IfFileExists $0 powershell_found
  StrCpy $0 "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe"
  IfFileExists $0 powershell_found
  StrCpy $0 "$WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
  IfFileExists $0 powershell_found
  StrCpy $0 "$WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
  IfFileExists $0 powershell_found

  MessageBox MB_ICONSTOP "Windows PowerShell was not found on this machine, so the installer cannot run.`r`n`r`nThe log file is here: $INSTDIR\${LOGFILE}"
  Abort

  powershell_found:

  ; Run the installer. It writes everything it does into the log file.
  ; -Yes keeps it from waiting for a key press in a window that may be
  ; hidden behind this one.
  ; The automatic test sets WGPU_CHECK_ONLY, so that a test run reports
  ; what it found and changes nothing.
  ReadEnvStr $3 "WGPU_CHECK_ONLY"
  ${If} $3 != ""
    StrCpy $4 " -CheckOnly"
  ${Else}
    StrCpy $4 ""
  ${EndIf}

  DetailPrint "Running the installer..."
  ClearErrors
  ExecWait '"$0" -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\Invoke-Installer.ps1" -PayloadDirectory "$INSTDIR\payload" -Yes -LogPath "$INSTDIR\${LOGFILE}"$4' $1

  ; The staged files live on the EFI system partition, not under $INSTDIR,
  ; so the uninstaller has to remove them itself. Record that.
  WriteRegStr HKLM "Software\WindowsGPUUnlock" "Staged" "1"

  ; Show the log, because the window that carried the output may have been
  ; hidden, and because the user needs to know what happened.
  ExecShell "open" "$INSTDIR\${LOGFILE}"

  ${If} $1 != 0
    MessageBox MB_ICONSTOP "The installation did not finish. The log has been opened for you, and it is here: $INSTDIR\${LOGFILE}`r`n`r`nNothing was written to the EFI system partition, and nothing was changed in the boot configuration."
    Abort
  ${EndIf}

  MessageBox MB_OK "Done. Reboot to try it.`r`n`r`nThe log has been opened for you, and it is here: $INSTDIR\${LOGFILE}"
SectionEnd

Section "Uninstall"
  ; Ask the PowerShell installer to reverse what it did: remove the boot
  ; entry and the staged files on the EFI partition.
  StrCpy $0 "$SYSDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
  IfFileExists $0 uninstaller_found
  StrCpy $0 "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe"
  IfFileExists $0 uninstaller_found
  StrCpy $0 "$WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
  IfFileExists $0 uninstaller_found

  MessageBox MB_ICONSTOP "Windows PowerShell was not found on this machine, so the uninstaller cannot run. The boot entry and the files on the EFI system partition are still there."
  Abort

  uninstaller_found:
  IfFileExists "$INSTDIR\Install-GpuUnlock.ps1" 0 +2
    ExecWait '"$0" -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\Install-GpuUnlock.ps1" -Action Uninstall' $2

  Delete "$INSTDIR\payload\UNLOCK.EFI"
  Delete "$INSTDIR\zstdcat.exe"
  Delete "$INSTDIR\Invoke-Installer.ps1"
  Delete "$INSTDIR\Install-GpuUnlock.ps1"
  Delete "$INSTDIR\Installer-Common.ps1"
  Delete "$INSTDIR\Detect-Hardware.ps1"
  Delete "$INSTDIR\Test-Preconditions.ps1"
  Delete "$INSTDIR\Get-FirmwareAssets.ps1"
  Delete "$INSTDIR\Uninstall.exe"
  Delete "$INSTDIR\${LOGFILE}"
  RMDir "$INSTDIR\payload"
  RMDir "$INSTDIR"

  DeleteRegKey HKLM "${UNINSTKEY}"
  DeleteRegKey HKLM "Software\WindowsGPUUnlock"
SectionEnd
