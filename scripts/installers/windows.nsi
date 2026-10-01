; windows.nsi --- per-user NSIS installer for a Hyperion desktop app.
;
; Built by scripts/build-installer.ps1 (dev machines and CI both) from a bundle produced by
; scripts/build-desktop-app.lisp. See hyperion/docs/desktop-distribution-design.md §9 and
; ADR-0010.
;
; TWO ROLES, one artifact. This installer is both the first-install download AND the update
; payload: hyperion/update fetches it, verifies its Ed25519 signature, then runs it with /S
; and exits, so nothing is locked when files are replaced. That is why the silent path must
; relaunch the app at the end -- from the user's point of view the app restarts itself.
;
; THE NEW VERSION IS SWAPPED IN WHOLE (#98, step 3). A Windows bundle is a launcher,
; sbcl-runtime.exe and sbcl.core, and the launcher refuses a core it was not built with, so a
; bundle with some files from each version does not start. The files are therefore never
; written into the install directory. They are extracted to $INSTDIR.new, the staged core is
; checked by the staged launcher, and then two renames swap the directories: $INSTDIR becomes
; $INSTDIR.old and $INSTDIR.new becomes $INSTDIR. The launcher deletes $INSTDIR.old once the
; new version has started. A run that stops part-way leaves the old install whole, or both
; directories renamed except the last; the next run finishes or undoes that first (RepairSwap).
;
; A directory cannot be renamed while a process has its current directory inside it or a file
; in it open, whatever the sharing mode; a program running from it does not prevent it
; (measured on Windows 11, #98). So this installer keeps its own current directory out of both
; directories when it renames them, and retries the first rename while the app finishes
; exiting. If that never succeeds, the install directory has not been touched: the staged copy
; is deleted and the update fails, to be tried again next time.
;
; PER-USER ON PURPOSE (design §1): installing to $LOCALAPPDATA\Programs means the app can
; rewrite itself with no elevation. A Program Files install would need a UAC prompt on every
; single update, or a privileged updater service -- both worse than the disk location is
; worth. RequestExecutionLevel user keeps us honest: this installer CANNOT write there.
;
; Defines (all required except VIVERSION):
;   APPNAME  display + directory name, e.g. "coalton-repl"
;   VERSION  "0.1.0" (may carry a pre-release suffix)
;   SRCDIR   the bundle directory to package
;   OUTFILE  the installer path to write
;   EXENAME  the launched binary, e.g. "coalton-repl.exe"
;   VIVERSION  optional 4-part numeric version for the file's own metadata
;   ICON       optional .ico path. It becomes the installer's and the uninstaller's own icon,
;              and is installed as $INSTDIR\<APPNAME>.ico for the Start menu shortcut and
;              the Add/Remove Programs entry. Without it all three show NSIS's default icon.

Unicode true
SetCompressor /SOLID lzma

!ifndef APPNAME
  !error "windows.nsi: -DAPPNAME is required"
!endif
!ifndef VERSION
  !error "windows.nsi: -DVERSION is required"
!endif
!ifndef SRCDIR
  !error "windows.nsi: -DSRCDIR is required"
!endif
!ifndef OUTFILE
  !error "windows.nsi: -DOUTFILE is required"
!endif
!ifndef EXENAME
  !error "windows.nsi: -DEXENAME is required"
!endif

Name "${APPNAME}"
OutFile "${OUTFILE}"
RequestExecutionLevel user                 ; never elevate -- see the header
InstallDir "$LOCALAPPDATA\Programs\${APPNAME}"
InstallDirRegKey HKCU "Software\${APPNAME}" "InstallDir"
ShowInstDetails hide
ShowUnInstDetails hide

!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}"

VIAddVersionKey "ProductName" "${APPNAME}"
VIAddVersionKey "FileDescription" "${APPNAME} installer"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" ""        ; present-but-empty silences makensis warning 9100
!ifdef VIVERSION
  VIProductVersion "${VIVERSION}"          ; strictly X.X.X.X -- computed by build-installer.ps1
!endif

; --- pages: a normal wizard interactively, nothing at all under /S -------------
; MUI_ICON and MUI_UNICON have to be defined before the page macros below, because those
; macros are where MUI reads them.
!ifdef ICON
  !define MUI_ICON "${ICON}"
  !define MUI_UNICON "${ICON}"
!endif
!include "MUI2.nsh"
!define MUI_ABORTWARNING
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

; --- the WebView2 runtime -----------------------------------------------------
; The one thing this app cannot supply itself: without the Edge WebView2 runtime the
; launcher opens no window. Preinstalled on Windows 11 and pushed to Windows 10 via Edge,
; but still absent on LTSC/Server/fresh images -- so detect, and repair when we can.
!define WV2_CLIENT "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"

; -> $0 = the installed runtime version, or "" if absent.
Function WebView2Version
  ; The Evergreen runtime registers under EdgeUpdate\Clients\<client guid>. Per-machine
  ; installs land in the 32-bit view (NSIS is a 32-bit process, so that is what it sees by
  ; default); per-user installs land in HKCU. Check all three -- a machine with only the
  ; per-user runtime is perfectly valid and would otherwise look empty.
  SetRegView 32
  ReadRegStr $0 HKLM "SOFTWARE\Microsoft\EdgeUpdate\Clients\${WV2_CLIENT}" "pv"
  StrCmp $0 "" 0 wv2_done
  SetRegView 64
  ReadRegStr $0 HKLM "SOFTWARE\Microsoft\EdgeUpdate\Clients\${WV2_CLIENT}" "pv"
  StrCmp $0 "" 0 wv2_done
  SetRegView 32
  ReadRegStr $0 HKCU "SOFTWARE\Microsoft\EdgeUpdate\Clients\${WV2_CLIENT}" "pv"
 wv2_done:
  SetRegView 32
  ; A stale key can linger with pv=0.0.0.0 after a removal -- that means absent, not "0.0.0.0".
  StrCmp $0 "0.0.0.0" 0 +2
    StrCpy $0 ""
FunctionEnd

Function EnsureWebView2
  Call WebView2Version
  StrCmp $0 "" 0 wv2_present
!ifdef WV2BOOTSTRAPPER
  DetailPrint "Installing the Microsoft Edge WebView2 runtime..."
  InitPluginsDir
  File "/oname=$PLUGINSDIR\MicrosoftEdgeWebview2Setup.exe" "${WV2BOOTSTRAPPER}"
  ; Run WITHOUT elevation on purpose: unelevated, the bootstrapper installs the runtime
  ; per-user, which matches this installer's per-user, no-UAC model. Elevating here would
  ; reintroduce the prompt we designed the whole install location to avoid.
  ExecWait '"$PLUGINSDIR\MicrosoftEdgeWebview2Setup.exe" /silent /install' $1
  Call WebView2Version
  StrCmp $0 "" 0 wv2_present
!endif
  ; Could not get it. Do NOT abort:
  ;  - silent means the UPDATE path, where the app was already running (so the runtime was
  ;    there); failing an update over a detection hiccup would break a working install.
  ;  - interactive means a first install; the files are still worth laying down, and the
  ;    user can install the runtime afterwards.
  IfSilent wv2_present 0
  MessageBox MB_OK|MB_ICONEXCLAMATION "The Microsoft Edge WebView2 runtime could not be installed.$\r$\n$\r$\n${APPNAME} will install, but its window will not open until the runtime is present. Install it from:$\r$\nhttps://developer.microsoft.com/microsoft-edge/webview2/"
 wv2_present:
FunctionEnd

; Stop the install, having changed nothing in $INSTDIR. Silent is the update path: exit code 2,
; which the app that started the update can report. Interactive gets MESSAGE.
!macro FailInstall MESSAGE
  IfSilent 0 +3
    SetErrorLevel 2
    Abort
  MessageBox MB_OK|MB_ICONEXCLAMATION "${MESSAGE}"
  Abort
!macroend

; The app may still be shutting down when an update installer starts (it launches us, then
; exits). A running program cannot be opened for writing, so opening the old launcher for
; appending, which changes nothing, tells whether it has exited. The launcher waits for the
; runtime, so it exits last. Retry briefly rather than racing.
!macro WaitForAppToExit
  StrCpy $R1 0
  IfFileExists "$INSTDIR\${EXENAME}" 0 wait_done
  wait_loop:
    ClearErrors
    FileOpen $R2 "$INSTDIR\${EXENAME}" a
    IfErrors 0 wait_closed
    IntOp $R1 $R1 + 1
    IntCmp $R1 20 wait_giveup wait_retry wait_giveup
  wait_retry:
    Sleep 500
    Goto wait_loop
  wait_giveup:
    !insertmacro FailInstall "${APPNAME} appears to still be running. Close it and run this installer again."
  wait_closed:
    FileClose $R2
  wait_done:
!macroend

; Finish or undo a swap an earlier run of this installer left half done. $INSTDIR.old exists
; only after the staged copy passed its check, so with no $INSTDIR, a $INSTDIR.new beside
; $INSTDIR.old is a checked copy and is moved into place; without one, $INSTDIR.old is moved
; back. Any other $INSTDIR.new is an extraction that did not finish, and is deleted.
Function RepairSwap
  IfFileExists "$INSTDIR\*.*" drop_staged
  IfFileExists "$INSTDIR.old\*.*" 0 drop_staged
  IfFileExists "$INSTDIR.new\*.*" 0 restore_old
    Rename "$INSTDIR.new" "$INSTDIR"
    Return
  restore_old:
    Rename "$INSTDIR.old" "$INSTDIR"
    Return
  drop_staged:
    RMDir /r "$INSTDIR.new"
FunctionEnd

; Swap $INSTDIR.new in for $INSTDIR, keeping the old one as $INSTDIR.old until the new version
; starts. The first rename is retried for 20 seconds: until it succeeds nothing has changed, so
; giving up deletes the staged copy and fails. The second is retried for 20 seconds too,
; because a file open in $INSTDIR.new stops it -- an antivirus scanner reading the files just
; written, for one (measured with a process reading them, #98) -- and giving up on it undoes
; the first. That undo is retried for 20 seconds as well, and $INSTDIR.new is deleted only once
; $INSTDIR is back. If it never comes back, $INSTDIR.new is kept: it is a complete, checked copy,
; and with $INSTDIR.old beside it and no $INSTDIR, the next run's RepairSwap moves it into place.
; Deleting it then could leave part of it, which RepairSwap would take for the whole.
Function SwapIn
  StrCpy $R1 0
  swap_retry:
    ; A previous version still here from the last update is in the way of the first rename.
    RMDir /r "$INSTDIR.old"
    IfFileExists "$INSTDIR.old\*.*" swap_wait
    IfFileExists "$INSTDIR\*.*" 0 swap_second
    ClearErrors
    Rename "$INSTDIR" "$INSTDIR.old"
    IfErrors 0 swap_second
  swap_wait:
    IntOp $R1 $R1 + 1
    IntCmp $R1 40 swap_giveup
    Sleep 500
    Goto swap_retry
  swap_giveup:
    RMDir /r "$INSTDIR.new"
    !insertmacro FailInstall "${APPNAME} could not be updated because its folder is in use: a window or a program may have it open. Close it and run this installer again."
  swap_second:
    StrCpy $R1 0
  swap_second_retry:
    ClearErrors
    Rename "$INSTDIR.new" "$INSTDIR"
    IfErrors 0 swap_done
    IntOp $R1 $R1 + 1
    IntCmp $R1 40 swap_second_giveup
    Sleep 500
    Goto swap_second_retry
  swap_second_giveup:
    ; A first install has no $INSTDIR.old to put back, and nothing is lost by deleting the copy.
    IfFileExists "$INSTDIR.old\*.*" 0 swap_drop_staged
    StrCpy $R1 0
  swap_undo_retry:
    ClearErrors
    Rename "$INSTDIR.old" "$INSTDIR"
    IfErrors 0 swap_drop_staged
    IntOp $R1 $R1 + 1
    IntCmp $R1 40 swap_undo_giveup
    Sleep 500
    Goto swap_undo_retry
  swap_undo_giveup:
    !insertmacro FailInstall "${APPNAME} could not be updated, and its previous version could not be put back. Run this installer again to finish the update."
  swap_drop_staged:
    RMDir /r "$INSTDIR.new"
    !insertmacro FailInstall "${APPNAME} could not be updated: its new files could not be moved into place."
  swap_done:
FunctionEnd

Section "Install"
  SetShellVarContext current                ; per-user shortcuts, never all-users
  Call EnsureWebView2
  !insertmacro WaitForAppToExit
  ; SetOutPath is also this process's current directory, which must not be inside a directory
  ; this installer renames (see the header).
  SetOutPath "$TEMP"
  Call RepairSwap
  ; A label, not a relative jump: FailInstall is several instructions.
  IfFileExists "$INSTDIR.new\*.*" 0 staged_clear
    !insertmacro FailInstall "${APPNAME} could not be updated: $INSTDIR.new is left from an earlier update and could not be removed."
  staged_clear:

  SetOutPath "$INSTDIR.new"
  File /r "${SRCDIR}\*.*"
!ifdef ICON
  ; A separate file rather than the exe's own icon resource, so the shortcut and the
  ; Add/Remove Programs entry show the icon whether or not one is embedded in the exe.
  File "/oname=$INSTDIR.new\${APPNAME}.ico" "${ICON}"
  !define SHORTCUT_ICON "$INSTDIR\${APPNAME}.ico"
!else
  !define SHORTCUT_ICON "$INSTDIR\${EXENAME}"
!endif
  WriteUninstaller "$INSTDIR.new\uninstall.exe"
  SetOutPath "$TEMP"

  ; The staged launcher checks the staged core, the check it makes at every start, and exits
  ; without starting the app (OURANOS_LAUNCHER_CHECK_ONLY, scripts/windows-launcher.c). Only a
  ; bundle with the launcher's layout has a pair to check; a one-file image has neither file.
  ; Exactly one of the two is neither layout: it would be swapped in and fail at launch, so it
  ; is refused (review of train 20). nsExec runs the launcher with no console window.
  IfFileExists "$INSTDIR.new\sbcl.core" staged_has_core staged_no_core
  staged_no_core:
    IfFileExists "$INSTDIR.new\sbcl-runtime.exe" staged_half staged_checked
  staged_has_core:
    IfFileExists "$INSTDIR.new\sbcl-runtime.exe" staged_pair staged_half
  staged_half:
    RMDir /r "$INSTDIR.new"
    !insertmacro FailInstall "${APPNAME} could not be updated: the downloaded files are incomplete, with one of sbcl.core and sbcl-runtime.exe and not the other."
  staged_pair:
    System::Call 'kernel32::SetEnvironmentVariable(t "OURANOS_LAUNCHER_CHECK_ONLY", t "1")'
    nsExec::Exec '"$INSTDIR.new\${EXENAME}"'
    Pop $R3
    System::Call 'kernel32::SetEnvironmentVariable(t "OURANOS_LAUNCHER_CHECK_ONLY", p 0)'
    StrCmp $R3 "0" staged_checked
    RMDir /r "$INSTDIR.new"
    !insertmacro FailInstall "${APPNAME} could not be updated: the downloaded files did not pass their check ($R3)."
  staged_checked:
  Call SwapIn

  WriteRegStr HKCU "Software\${APPNAME}" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\${APPNAME}" "Version" "${VERSION}"

  ; Add/Remove Programs (per-user hive -- matches where we installed)
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayName" "${APPNAME}"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINST_KEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKCU "${UNINST_KEY}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayIcon" "${SHORTCUT_ICON}"
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoRepair" 1

  ; The swap is done. The shortcut's working directory and the relaunched app's below are
  ; SetOutPath's, and the app starts in its own directory, as it always has.
  SetOutPath "$INSTDIR"
  CreateShortcut "$SMPROGRAMS\${APPNAME}.lnk" "$INSTDIR\${EXENAME}" "" "${SHORTCUT_ICON}" 0

  ; Silent == the update path: hand the user back a running app, not a closed one.
  ;
  ; ExecShell, not Exec: this installer is a GUI process, so a child started with plain
  ; CreateProcess inherits NO console. A console-subsystem SBCL image then dies on its first
  ; write to stdout -- observed exactly that, the app never appeared after a silent install.
  ; ShellExecute gives the child its own console allocation, and works for a GUI-subsystem
  ; image too, so it is correct either way.
  IfSilent 0 +2
    ExecShell "open" "$INSTDIR\${EXENAME}"
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  Delete "$SMPROGRAMS\${APPNAME}.lnk"
  ; Remove what we installed, not what the user made. App DATA lives in ~/.<appname> and is
  ; deliberately NOT touched -- an uninstall must not eat someone's database.
  ;
  ; /REBOOTOK matters here: uninstall.exe is RUNNING from $INSTDIR, and Windows will not let
  ; a running binary delete itself, so without it the directory survives every uninstall.
  ; This marks the stragglers for removal on next boot instead of silently leaving them.
  Delete /REBOOTOK "$INSTDIR\uninstall.exe"
  RMDir /r /REBOOTOK "$INSTDIR"
  RMDir /r "$INSTDIR.old"                  ; what an update may have left (see the header)
  RMDir /r "$INSTDIR.new"
  DeleteRegKey HKCU "${UNINST_KEY}"
  DeleteRegKey HKCU "Software\${APPNAME}"
SectionEnd
