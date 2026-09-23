; windows.iss --- per-user Inno Setup installer for a Hyperion desktop app.
;
; The second Windows packaging, alongside windows.nsi. Built by
; scripts/build-installer.ps1 from a bundle produced by scripts/build-desktop-app.lisp.
; See hyperion/docs/desktop-distribution-design.md sections 1, 7 and 9, and ADR-0010.
;
; WHY A SECOND ONE AT ALL. Inno Setup has first-class code signing -- a SignTool directive
; that signs the installer and the uninstaller as part of the build, rather than a
; post-build step somebody has to remember. Ed25519 payload signing (section 4) is UPDATE
; INTEGRITY and does nothing about SmartScreen on a first install; that needs an
; Authenticode signature, and this is the path that makes it routine.
;
; NOTHING IN THE CLIENT CHANGES TO SUPPORT IT. The manifest's per-platform `format' field
; (section 3) selects the apply strategy, so this ships as "format": "inno" and every
; installed client that already reads the field picks it up. That is what the field is
; for: a product changes packaging without shipping a new client first.
;
; THE INSTALL DIRECTORY IS A CONTRACT, NOT A CONVENTION. hyperion/update reads
; HKCU\Software\<APPNAME>\InstallDir to decide where to install an update, because that is
; where the app actually IS -- including when a user chose somewhere else. windows.nsi
; writes that value; SO MUST THIS. Two installers writing different keys is the
; producer/consumer drift that pre-publication issue 206 was, and the failure mode is an update that installs a
; second copy elsewhere, leaves the running one untouched, and looks to the user like an
; update that silently did nothing.
;
; PER-USER ON PURPOSE (section 1). PrivilegesRequired=lowest and an install under
; {localappdata}\Programs mean the app can rewrite itself with no elevation. A Program
; Files install would need a UAC prompt on every single update, or a privileged updater
; service -- both worse than the disk location is worth.
;
; Defines (all required except WV2BOOTSTRAPPER and SIGNTOOL):
;   APPNAME         display + directory name, e.g. "coalton-repl"
;   VERSION         "0.1.0" (may carry a pre-release suffix)
;   SRCDIR          the bundle directory to package
;   OUTDIR          directory to write the installer into
;   OUTBASE         installer filename without .exe
;   EXENAME         the launched binary, e.g. "coalton-repl.exe"
;   WV2BOOTSTRAPPER optional path to MicrosoftEdgeWebview2Setup.exe
;   SIGNTOOL        optional name of a SignTool configured via ISCC /S<name>=...

#ifndef APPNAME
  #error "windows.iss: -DAPPNAME is required"
#endif
#ifndef VERSION
  #error "windows.iss: -DVERSION is required"
#endif
#ifndef SRCDIR
  #error "windows.iss: -DSRCDIR is required"
#endif
#ifndef OUTDIR
  #error "windows.iss: -DOUTDIR is required"
#endif
#ifndef OUTBASE
  #error "windows.iss: -DOUTBASE is required"
#endif
#ifndef EXENAME
  #error "windows.iss: -DEXENAME is required"
#endif

[Setup]
; AppId identifies the product across versions and drives the uninstall entry. The app
; name rather than a GUID: it is already unique per product in this tree, and a literal
; brace here collides with the preprocessor substitution.
AppId={#APPNAME}
AppName={#APPNAME}
AppVersion={#VERSION}
VersionInfoVersion={#VERSION}
DefaultDirName={localappdata}\Programs\{#APPNAME}
DefaultGroupName={#APPNAME}
DisableProgramGroupPage=yes
DisableDirPage=auto
; NEVER elevate. This is the same honesty RequestExecutionLevel user gives windows.nsi:
; the installer CANNOT write to Program Files, so it cannot quietly become the thing that
; needs a UAC prompt on every update.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir={#OUTDIR}
OutputBaseFilename={#OUTBASE}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; The uninstaller is signed too. An unsigned uninstaller beside a signed installer is the
; kind of asymmetry that produces a SmartScreen prompt at the worst possible moment.
#ifdef SIGNTOOL
SignTool={#SIGNTOOL}
SignedUninstaller=yes
#endif

[Files]
Source: "{#SRCDIR}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
#ifdef WV2BOOTSTRAPPER
Source: "{#WV2BOOTSTRAPPER}"; DestDir: "{tmp}"; DestName: "MicrosoftEdgeWebview2Setup.exe"; \
  Flags: deleteafterinstall
#endif

[Icons]
Name: "{group}\{#APPNAME}"; Filename: "{app}\{#EXENAME}"
Name: "{userdesktop}\{#APPNAME}"; Filename: "{app}\{#EXENAME}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Registry]
; THE CONTRACT WITH hyperion/update. Same key, same value name, same meaning as
; windows.nsi. If this line is edited, the updater stops finding the install directory and
; starts guessing -- silently, and only on machines installed with this packaging.
Root: HKCU; Subkey: "Software\{#APPNAME}"; ValueType: string; ValueName: "InstallDir"; \
  ValueData: "{app}"; Flags: uninsdeletekey

[Run]
; TWO ENTRIES, ONE JOB, AND THE SECOND IS THE UPDATE PATH.
;
; `postinstall' entries are the finish-page checkbox, and they are SKIPPED in a silent
; install -- which is exactly the install the updater performs. windows.nsi solves this
; with `IfSilent'; `Check: WizardSilent' is the Inno equivalent, and without it a user who
; accepts an in-app update is left staring at a closed application.
;
; MEASURED, both directions, against a real install of a real 39 MB SBCL executable that
; writes a marker file when it starts:
;
;   with `Check: WizardSilent'      /VERYSILENT install -> marker written. RELAUNCHED.
;   with that line removed          /VERYSILENT install -> files installed, NO marker.
;
; So the hazard was real: `postinstall skipifsilent' alone does NOT relaunch under
; /VERYSILENT, and without the second line every in-app update would have left the user
; staring at a closed application. The control also confirms the install itself still
; succeeds, so the difference is the relaunch and nothing else.
Filename: "{app}\{#EXENAME}"; Description: "Launch {#APPNAME}"; \
  Flags: nowait postinstall skipifsilent
Filename: "{app}\{#EXENAME}"; Flags: nowait; Check: WizardSilent

[UninstallDelete]
; Nothing here on purpose. The app's own data lives in ~/.<appname> and an uninstall must
; not eat someone's database -- the same promise windows.nsi makes in its Uninstall
; section, and the guarantee tracked separately because nothing currently asserts it.

[Code]
const
  WV2_CLIENT = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';

function WebView2Present: Boolean;
var
  Version: String;
begin
  { The Evergreen runtime registers under EdgeUpdate\Clients\<client guid>. A per-machine
    install lands in HKLM (in either registry view) and a per-user install in HKCU, and a
    machine carrying only the per-user runtime is perfectly valid -- so all three are
    checked. A stale key can linger with pv=0.0.0.0 after a removal, which means ABSENT
    rather than "version 0.0.0.0". }
  Version := '';
  if not RegQueryStringValue(HKLM32, 'SOFTWARE\Microsoft\EdgeUpdate\Clients\' + WV2_CLIENT, 'pv', Version) then
    if not RegQueryStringValue(HKLM64, 'SOFTWARE\Microsoft\EdgeUpdate\Clients\' + WV2_CLIENT, 'pv', Version) then
      RegQueryStringValue(HKCU, 'SOFTWARE\Microsoft\EdgeUpdate\Clients\' + WV2_CLIENT, 'pv', Version);
  Result := (Version <> '') and (Version <> '0.0.0.0');
end;

procedure CurStepChanged(CurStep: TSetupStep);
{ ResultCode is only referenced on the bootstrapper path, so its declaration is guarded
  too -- otherwise a build without WV2BOOTSTRAPPER compiles with a hint, and a build that
  is noisy by default is one whose real warnings nobody reads. }
#ifdef WV2BOOTSTRAPPER
var
  ResultCode: Integer;
#endif
begin
  if CurStep = ssPostInstall then
  begin
    if not WebView2Present then
    begin
#ifdef WV2BOOTSTRAPPER
      { Run WITHOUT elevation on purpose: unelevated, the bootstrapper installs the runtime
        per-user, which matches this installer's per-user, no-UAC model. Elevating here
        would reintroduce the prompt the install location exists to avoid. }
      Exec(ExpandConstant('{tmp}\MicrosoftEdgeWebview2Setup.exe'), '/silent /install',
           '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
#endif
      { DO NOT ABORT if it is still missing. A silent run is the UPDATE path, where the app
        was already running and therefore the runtime was already there; failing an update
        over a detection hiccup would break a working install to fix nothing. }
    end;
  end;
end;
