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

; The app may still be shutting down when an update installer starts (it launches us, then
; exits). Deleting the old exe is the reliable "is it gone yet?" probe -- retry briefly
; rather than racing, and say something useful if it never frees up.
!macro WaitForAppToExit
  StrCpy $R1 0
  wait_loop:
    ClearErrors
    Delete "$INSTDIR\${EXENAME}"
    IfErrors 0 wait_done
    IntOp $R1 $R1 + 1
    IntCmp $R1 20 wait_giveup wait_retry wait_giveup
  wait_retry:
    Sleep 500
    Goto wait_loop
  wait_giveup:
    IfSilent 0 +3
      SetErrorLevel 2                      ; an update: fail loudly, the app can report it
      Abort
    MessageBox MB_OK|MB_ICONEXCLAMATION "${APPNAME} appears to still be running. Close it and run this installer again."
    Abort
  wait_done:
!macroend

Section "Install"
  SetShellVarContext current                ; per-user shortcuts, never all-users
  Call EnsureWebView2
  !insertmacro WaitForAppToExit
  SetOutPath "$INSTDIR"
  File /r "${SRCDIR}\*.*"
!ifdef ICON
  ; A separate file rather than the exe's own icon resource, so the shortcut and the
  ; Add/Remove Programs entry show the icon whether or not one is embedded in the exe.
  File "/oname=$INSTDIR\${APPNAME}.ico" "${ICON}"
  !define SHORTCUT_ICON "$INSTDIR\${APPNAME}.ico"
!else
  !define SHORTCUT_ICON "$INSTDIR\${EXENAME}"
!endif

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

  CreateShortcut "$SMPROGRAMS\${APPNAME}.lnk" "$INSTDIR\${EXENAME}" "" "${SHORTCUT_ICON}" 0
  WriteUninstaller "$INSTDIR\uninstall.exe"

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
  DeleteRegKey HKCU "${UNINST_KEY}"
  DeleteRegKey HKCU "Software\${APPNAME}"
SectionEnd
