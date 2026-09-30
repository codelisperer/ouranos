/* windows-launcher.c --- the executable a Windows desktop app starts from (#98).
 *
 * A Windows bundle from scripts/build-desktop-app.lisp holds three files where it used to
 * hold one dumped image:
 *
 *     <name>.exe          this launcher; it carries the app's icon and is the file a
 *                         shortcut, the installer and the updater start
 *     sbcl-runtime.exe    the SBCL runtime
 *     sbcl.core           the app's Lisp core, dumped with :executable nil
 *
 * WHY NOT ONE FILE. Authenticode appends its signature to the end of the file, and a dumped
 * image keeps its core at the end: a signed dumped image stops with "Can't find sbcl.core".
 * A signed runtime with a separate core starts (measured on #98). The runtime is named
 * sbcl-runtime.exe, not sbcl.exe, so that hyperion/update can tell a shipped build from an
 * SBCL installation, which keeps sbcl.exe and sbcl.core in one directory.
 *
 * WHY A LAUNCHER. A core dumped without the runtime cannot carry runtime options:
 * :save-runtime-options is ignored unless :executable is true. So the bare runtime would start
 * with its default heap (1024 MB) and would take any leading app argument that is one of its
 * own options, such as --help or --version (measured on #98). This passes the heap the build
 * chose and ends runtime-option processing before the app's arguments, as
 * scripts/macos-launcher.c does on macOS.
 *
 * Windows has no exec: the runtime is a child process. The launcher waits for it and exits
 * with its exit code. It ignores Ctrl-C and Ctrl-Break, which reach every process on the
 * console, so that the runtime decides how to stop and the launcher reports what it did.
 * When the launcher has no console -- the build or CI switched it to the GUI subsystem --
 * the runtime, a console program, is started with CREATE_NO_WINDOW, so no console window
 * appears behind the app.
 *
 * The app's own arguments are passed on as the text they were given in, not re-quoted: the
 * tail of GetCommandLineW after the launcher's own name. Re-quoting argv would change
 * arguments that contain quotes or trailing backslashes.
 *
 * OURANOS_HEAP_MB is set when build-desktop-app.lisp compiles this file, to the heap of the
 * process that dumped the core.
 */

#define WIN32_LEAN_AND_MEAN
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <stdio.h>
#include <wchar.h>

#ifndef OURANOS_HEAP_MB
#error "compile with /DOURANOS_HEAP_MB=<megabytes>"
#endif

#define WSTR2(x) L## #x
#define WSTR(x) WSTR2(x)

static void fail(const wchar_t *what, const wchar_t *path) {
  fwprintf(stderr, L"launcher: %ls %ls (error %lu)\n", what, path ? path : L"", GetLastError());
}

/* The rest of the command line after the program name, following the rules the C runtime
   uses to split argv[0]: a quoted name ends at the next quote, an unquoted one at the first
   space or tab. Leading spaces of the rest are kept out. */
static const wchar_t *after_program_name(const wchar_t *line) {
  const wchar_t *p = line;
  if (*p == L'"') {
    p++;
    while (*p && *p != L'"') p++;
    if (*p == L'"') p++;
  } else {
    while (*p && *p != L' ' && *p != L'\t') p++;
  }
  while (*p == L' ' || *p == L'\t') p++;
  return p;
}

static BOOL WINAPI ignore_ctrl(DWORD type) {
  (void)type;
  return TRUE;
}

int wmain(void) {
  wchar_t self[MAX_PATH * 4], dir[MAX_PATH * 4], runtime[MAX_PATH * 4], core[MAX_PATH * 4];
  DWORD n = GetModuleFileNameW(NULL, self, (DWORD)(sizeof self / sizeof self[0]));
  if (n == 0 || n >= sizeof self / sizeof self[0]) {
    fail(L"cannot find its own path", NULL);
    return 127;
  }
  wcscpy_s(dir, sizeof dir / sizeof dir[0], self);
  wchar_t *slash = wcsrchr(dir, L'\\');
  if (slash == NULL) {
    fail(L"its own path has no directory:", self);
    return 127;
  }
  *slash = L'\0';
  if (swprintf_s(runtime, sizeof runtime / sizeof runtime[0], L"%ls\\sbcl-runtime.exe", dir) < 0 ||
      swprintf_s(core, sizeof core / sizeof core[0], L"%ls\\sbcl.core", dir) < 0) {
    fail(L"path too long:", dir);
    return 127;
  }

  /* The app sees the launcher's own path as its program name, as it did as one file. */
  const wchar_t *rest = after_program_name(GetCommandLineW());
  size_t size = wcslen(self) + wcslen(core) + wcslen(rest) + 128;
  wchar_t *line = HeapAlloc(GetProcessHeap(), 0, size * sizeof *line);
  if (line == NULL) {
    fail(L"out of memory", NULL);
    return 127;
  }
  if (swprintf_s(line, size,
                 L"\"%ls\" --core \"%ls\" --dynamic-space-size " WSTR(OURANOS_HEAP_MB)
                 L" --noinform --end-runtime-options%ls%ls",
                 self, core, *rest ? L" " : L"", rest) < 0) {
    fail(L"command line too long", NULL);
    return 127;
  }

  SetConsoleCtrlHandler(ignore_ctrl, TRUE);
  STARTUPINFOW si;
  PROCESS_INFORMATION pi;
  ZeroMemory(&si, sizeof si);
  si.cb = sizeof si;
  /* The runtime writes where the launcher was told to write. Without this, a launcher with no
     console (started by another program with pipes, or switched to the GUI subsystem) starts
     the runtime with no standard handles, and its output is lost. */
  si.dwFlags = STARTF_USESTDHANDLES;
  si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
  si.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
  si.hStdError = GetStdHandle(STD_ERROR_HANDLE);
  DWORD flags = GetConsoleWindow() == NULL ? CREATE_NO_WINDOW : 0;
  if (!CreateProcessW(runtime, line, NULL, NULL, TRUE, flags, NULL, NULL, &si, &pi)) {
    fail(L"cannot start", runtime);
    return 127;
  }
  CloseHandle(pi.hThread);
  WaitForSingleObject(pi.hProcess, INFINITE);
  DWORD code = 127;
  if (!GetExitCodeProcess(pi.hProcess, &code)) {
    fail(L"cannot read the exit code of", runtime);
    code = 127;
  }
  CloseHandle(pi.hProcess);
  return (int)code;
}
