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
!define MUI_WELCOMEPAGE_TEXT "This installer unlocks the FP16 and BF16 tensor instruction rate on NVIDIA GeForce RTX 30-series cards (GA102, GA103, GA104, GA106 - the RTX 3090, 3080, 3070 and 3060 families).$\r$\n$\r$\nBEFORE YOU CONTINUE, READ THIS:$\r$\n$\r$\n1. Secure Boot must be OFF in your BIOS. The application is not signed, so a firmware that enforces Secure Boot will refuse to load it.$\r$\n$\r$\n2. Windows Fast Startup must be OFF, so that a shutdown really powers the card down. Run: powercfg /h off$\r$\n$\r$\n3. If BitLocker protects your Windows volume, suspend it first. Run: manage-bde -protectors -disable C:$\r$\n$\r$\n4. The card that is unlocked must NOT drive the display. Use a machine with an integrated GPU and keep the screen plugged into it.$\r$\n$\r$\n5. The installer is not signed, so Windows may warn about an unknown publisher. Antivirus software may also block the application. If it says 'Error opening file for writing', add this folder to the trust list of your antivirus software, or install into another folder.$\r$\n$\r$\n6. About 100 MB is downloaded from NVIDIA and the CachyOS archive. The NVIDIA firmware files are not part of this package, because NVIDIA's licence does not allow it; they are generated on this machine and checked against their SHA-256.$\r$\n$\r$\nThis is experimental. It writes to the card's firmware and to its registers. Keep a bootable USB handy, and do not use it on a machine you depend on for work."

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

Function .onInit
  ; The registry is read and written in the 64 bit view, because the scripts
  ; that do the work run in a 64 bit PowerShell. A 32 bit program writes to
  ; the other view, and the two would not see each other. This has to be
  ; set before the install directory is looked up, because that is read
  ; from the registry.
  SetRegView 64

  ; The error flag at this point says nothing about the administrator
  ; rights. It holds the result of the last thing the installer did before
  ; this function, and InstallDirRegKey leaves it set when the key is not
  ; there yet, which is the case on a machine that has never seen this
  ; program. So the flag is cleared, and the real check is done by the
  ; script, where the answer can be written into the log.
  ClearErrors

  ; The log is started here, before anything else can fail, so that a file
  ; with this name on the disk means the installer really did run. It is
  ; also the only record there is if the installer gives up later.
  ClearErrors
  CreateDirectory "$INSTDIR"
  Delete "$INSTDIR\${LOGFILE}"
  ClearErrors
  FileOpen $2 "$INSTDIR\${LOGFILE}" w
  IfErrors log_open_failed
    FileWrite $2 "The installer started on this machine.$\r$\n"
  FileClose $2
  Goto log_opened

  log_open_failed:
  log_opened:
FunctionEnd

Function Locate-PowerShell
  ; The 64 bit PowerShell is wanted, because bcdedit.exe is a 64 bit
  ; program and there is no 32 bit copy of it. This program is a 32 bit one,
  ; so the 64 bit system directory is reached through the Sysnative alias.
  ; The script starts itself again as a 64 bit process when it has to, so
  ; this is a first try rather than the only one.
  StrCpy $0 "$WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
  IfFileExists $0 0 +2
    Return
  StrCpy $0 "$SYSDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
  IfFileExists $0 0 +2
    Return
  StrCpy $0 "$WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
  IfFileExists $0 0 +2
    Return
  StrCpy $0 "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe"
  IfFileExists $0 0 +2
    Return
  StrCpy $0 ""
FunctionEnd

Function un.Locate-PowerShell
  ; The same as the function above, for the uninstaller. A section of the
  ; uninstaller may only call a function whose name starts with "un.".
  StrCpy $0 "$WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
  IfFileExists $0 0 +2
    Return
  StrCpy $0 "$SYSDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
  IfFileExists $0 0 +2
    Return
  StrCpy $0 "$WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
  IfFileExists $0 0 +2
    Return
  StrCpy $0 "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe"
  IfFileExists $0 0 +2
    Return
  StrCpy $0 ""
FunctionEnd

Section "Install"
  SetOutPath "$INSTDIR"

  ; Say what is being unpacked, so that the log says where the installer
  ; stopped if it does.
  ; The file is opened in append mode and then put at its end. FileOpen with
  ; "a" opens the file without truncating it, but it leaves the position at
  ; the start, so without the seek the line would be written over the one
  ; that is already there.
  ClearErrors
  FileOpen $2 "$INSTDIR\${LOGFILE}" a
  IfErrors progress_before_done
    FileSeek $2 0 END
    FileWrite $2 "Unpacking the files.$\r$\n"
  FileClose $2
  progress_before_done:

  ; The scripts that do the work.
  File "..\installer\Invoke-Installer.ps1"
  File "..\installer\Install-GpuUnlock.ps1"
  File "..\installer\Installer-Common.ps1"
  File "..\installer\Detect-Hardware.ps1"
  File "..\installer\Test-Preconditions.ps1"
  File "..\installer\Get-FirmwareAssets.ps1"

  ; The EFI application and the helper are carried as text, not as files.
  ; Antivirus software on a Windows machine often refuses an unsigned EFI
  ; application, and then the installer cannot even unpack it. Base64 in a
  ; text file is not noticed, and the script writes the real files out
  ; itself, where a failure can be reported in the log.
  File /oname=unlock-payload.txt "${PAYLOAD}\unlock-payload.txt"
  File /oname=helper-payload.txt "${HELPER}\helper-payload.txt"
  File /oname=payload-manifest.txt "${PAYLOAD}\payload-manifest.txt"

  ; The uninstaller is the same script in reverse.
  WriteUninstaller "$INSTDIR\Uninstall.exe"

  ClearErrors
  FileOpen $2 "$INSTDIR\${LOGFILE}" a
  IfErrors progress_after_done
    FileSeek $2 0 END
    FileWrite $2 "The files are unpacked.$\r$\n"
  FileClose $2
  progress_after_done:

  ; Record where the scripts live so the uninstaller can find them.
  WriteRegStr HKLM "Software\WindowsGPUUnlock" "InstallDir" "$INSTDIR"

  WriteRegStr HKLM "${UNINSTKEY}" "DisplayName" "${PRODUCT}"
  WriteRegStr HKLM "${UNINSTKEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "${UNINSTKEY}" "Publisher" "${PUBLISHER}"
  WriteRegStr HKLM "${UNINSTKEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKLM "${UNINSTKEY}" "InstallLocation" "$INSTDIR"
  WriteRegDWORD HKLM "${UNINSTKEY}" "NoModify" 1
  WriteRegDWORD HKLM "${UNINSTKEY}" "NoRepair" 1

  ; The log was started in .onInit. The script appends to it, so that the
  ; first line, which says that the installer ran, is kept.

  ; Find PowerShell. The 64 bit one is wanted, because bcdedit.exe is a 64 bit
  ; program. The script starts itself again as a 64 bit process when it has
  ; to, so the path that is found here is a first try.
  Call Locate-PowerShell
  ${If} $0 == ""
    MessageBox MB_ICONSTOP "Windows PowerShell was not found on this machine, so the installer cannot run.$\r$\n$\r$\nThe log file is here: $INSTDIR\${LOGFILE}" /SD IDOK
    Abort
  ${EndIf}

  ; Say which PowerShell was taken, so that the log says it too.
  ClearErrors
  FileOpen $2 "$INSTDIR\${LOGFILE}" a
  IfErrors powershell_logged
    FileSeek $2 0 END
    FileWrite $2 "PowerShell: $0$\r$\n"
  FileClose $2
  powershell_logged:

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
  ExecWait '"$0" -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\Invoke-Installer.ps1" -PayloadDirectory "$TEMP\WindowsGPUUnlock" -Yes -LogPath "$INSTDIR\${LOGFILE}"$4' $1

  ; The staged files live on the EFI system partition, not under $INSTDIR,
  ; so the uninstaller has to remove them itself. Record that.
  WriteRegStr HKLM "Software\WindowsGPUUnlock" "Staged" "1"

  ; Show the log, because the window that carried the output may have been
  ; hidden, and because the user needs to know what happened. A silent run
  ; has nobody to show it to, and the shell can take a long time to answer,
  ; so it is left alone there.
  IfSilent no_log_window
    ExecShell "open" "$INSTDIR\${LOGFILE}"
  no_log_window:

  ${If} $1 != 0
    MessageBox MB_ICONSTOP "The installation did not finish. The log has been opened for you, and it is here: $INSTDIR\${LOGFILE}$\r$\n$\r$\nIf the log says that the EFI system partition was already written to, run the uninstaller afterwards to clean it up." /SD IDOK
    Abort
  ${EndIf}

  MessageBox MB_OK "Done. Reboot to try it.$\r$\n$\r$\nThe log has been opened for you, and it is here: $INSTDIR\${LOGFILE}" /SD IDOK
SectionEnd

Section "Uninstall"
  ; The registry is read and written in the 64 bit view, the same as the
  ; installer does it.
  SetRegView 64

  ; Ask the PowerShell installer to reverse what it did: remove the boot
  ; entry and the staged files on the EFI partition.
  Call un.Locate-PowerShell
  ${If} $0 == ""
    MessageBox MB_ICONSTOP "Windows PowerShell was not found on this machine, so the uninstaller cannot run. The boot entry and the files on the EFI system partition are still there." /SD IDOK
    Abort
  ${EndIf}

  IfFileExists "$INSTDIR\Install-GpuUnlock.ps1" 0 +2
    ExecWait '"$0" -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\Install-GpuUnlock.ps1" -Action Uninstall' $2

  Delete "$INSTDIR\payload\UNLOCK.EFI"
  Delete "$INSTDIR\zstdcat.exe"
  Delete "$INSTDIR\unlock-payload.txt"
  Delete "$INSTDIR\helper-payload.txt"
  Delete "$INSTDIR\payload-manifest.txt"
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

  ; The application and the helper are unpacked into the temporary folder
  ; when the installer runs, so they are removed again here.
  RMDir /r "$TEMP\WindowsGPUUnlock"

  DeleteRegKey HKLM "${UNINSTKEY}"
  DeleteRegKey HKLM "Software\WindowsGPUUnlock"
SectionEnd
