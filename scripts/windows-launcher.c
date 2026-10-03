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
 * When the launcher has no console -- the build or CI switched it to the GUI subsystem -- the
 * runtime, a console program, is started with DETACHED_PROCESS, so it has no console either,
 * as the one-file GUI image had none. CREATE_NO_WINDOW would hide the window but still start
 * a conhost.exe for it (seen in desktop-release run 36699201220).
 *
 * The app's own arguments are passed on as the text they were given in, not re-quoted: the
 * tail of GetCommandLineW after the launcher's own name. Re-quoting argv would change
 * arguments that contain quotes or trailing backslashes.
 *
 * BEFORE STARTING THE RUNTIME it checks sbcl.core's SHA-256 against the one compiled in
 * (OURANOS_CORE_SHA256, below) and exits with 126, saying so, when they differ (#98, step 2).
 *
 * With OURANOS_LAUNCHER_CHECK_ONLY set in its environment, it checks the core, reports nothing,
 * and exits 0 when the core is the one it was built with and 126 when it is not, without
 * starting the runtime. The installers run it this way against the files they staged (#98,
 * step 3); an environment variable, because every argument belongs to the app.
 *
 * AFTER STARTING THE RUNTIME it deletes <install>.old, the directory beside its own that an
 * installer leaves when it swaps a new version in (scripts/installers/, #98 step 3). That is
 * the previous version, kept only until the new one has started.
 *
 * OURANOS_HEAP_MB and OURANOS_CORE_SHA256 are set when build-desktop-app.lisp compiles this
 * file, after the core is dumped: the heap of the process that dumped it, and its hash.
 */

#define WIN32_LEAN_AND_MEAN
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <bcrypt.h>
#include <stdio.h>
#include <wchar.h>

#pragma comment(lib, "bcrypt")
#pragma comment(lib, "user32")

#ifndef OURANOS_HEAP_MB
#error "compile with /DOURANOS_HEAP_MB=<megabytes>"
#endif

/* THE CORE'S HASH (#98, step 2). The SHA-256 of sbcl.core, as 64 lowercase hex digits, written
 * in when build-desktop-app.lisp compiles this file after the core is dumped. The launcher
 * hashes sbcl.core before starting the runtime and refuses to start it when the hashes differ.
 *
 * Why here: the launcher is the signed file, and the core is data that Authenticode does not
 * cover. An app installed per user, where anything running as the user can write the install
 * directory, is safe to sign only if the signed code checks what it loads; otherwise a replaced
 * core would run under the app's signature (#98, 2026-08-07 decision). The hash is compiled in,
 * not read from a file beside the core, because a file beside the core can be replaced with it. */
#ifndef OURANOS_CORE_SHA256
#error "compile with /DOURANOS_CORE_SHA256=<64 hex digits of sbcl.core's SHA-256>"
#endif

#define WSTR2(x) L## #x
#define WSTR(x) WSTR2(x)

/* Exit code for a core that is not the one the launcher was built with. */
#define EXIT_CORE_CHANGED 126

/* When set in the environment, check the core and exit without starting the runtime. */
#define CHECK_ONLY_VARIABLE L"OURANOS_LAUNCHER_CHECK_ONLY"

static void fail(const wchar_t *what, const wchar_t *path) {
  fwprintf(stderr, L"launcher: %ls %ls (error %lu)\n", what, path ? path : L"", GetLastError());
}

/* MESSAGE to whoever started the launcher: standard error when there is one, which is how a
   terminal, a script or a test starts it, and otherwise a message box, which is how a user who
   double-clicked the app sees anything at all. */
static void tell(const wchar_t *message) {
  HANDLE err = GetStdHandle(STD_ERROR_HANDLE);
  if (err == NULL || err == INVALID_HANDLE_VALUE || GetFileType(err) == FILE_TYPE_UNKNOWN) {
    MessageBoxW(NULL, message, L"This app cannot start", MB_OK | MB_ICONERROR);
  } else {
    fwprintf(stderr, L"launcher: %ls\n", message);
    fflush(stderr);
  }
}

/* The SHA-256 of the file at PATH into HEX, 64 lowercase hex digits and a NUL. Returns 0 on
   success, or the Windows or CNG error code. */
static DWORD sha256_file(const wchar_t *path, wchar_t hex[65]) {
  BCRYPT_ALG_HANDLE alg = NULL;
  BCRYPT_HASH_HANDLE hash = NULL;
  HANDLE file = INVALID_HANDLE_VALUE;
  UCHAR digest[32];
  static UCHAR buffer[1 << 20];
  DWORD result = 0, got = 0;
  NTSTATUS st;

  file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                     FILE_FLAG_SEQUENTIAL_SCAN, NULL);
  if (file == INVALID_HANDLE_VALUE) return GetLastError();
  st = BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, NULL, 0);
  if (!BCRYPT_SUCCESS(st)) { result = (DWORD)st; goto done; }
  st = BCryptCreateHash(alg, &hash, NULL, 0, NULL, 0, 0);
  if (!BCRYPT_SUCCESS(st)) { result = (DWORD)st; goto done; }
  for (;;) {
    if (!ReadFile(file, buffer, sizeof buffer, &got, NULL)) { result = GetLastError(); goto done; }
    if (got == 0) break;
    st = BCryptHashData(hash, buffer, got, 0);
    if (!BCRYPT_SUCCESS(st)) { result = (DWORD)st; goto done; }
  }
  st = BCryptFinishHash(hash, digest, sizeof digest, 0);
  if (!BCRYPT_SUCCESS(st)) { result = (DWORD)st; goto done; }
  for (int i = 0; i < 32; i++) swprintf_s(hex + 2 * i, 3, L"%02x", digest[i]);
done:
  if (hash) BCryptDestroyHash(hash);
  if (alg) BCryptCloseAlgorithmProvider(alg, 0);
  CloseHandle(file);
  return result;
}

/* Delete the directory tree at PATH, which is not followed through a junction or a symbolic
   link: those are removed as links. A file that cannot be deleted, such as a program still
   running from the previous version, is left, and the next start or the next update tries
   again. */
static void delete_tree(const wchar_t *path) {
  wchar_t pattern[MAX_PATH * 4], child[MAX_PATH * 4];
  WIN32_FIND_DATAW found;
  if (swprintf_s(pattern, sizeof pattern / sizeof pattern[0], L"%ls\\*", path) < 0) return;
  HANDLE search = FindFirstFileW(pattern, &found);
  if (search != INVALID_HANDLE_VALUE) {
    do {
      if (wcscmp(found.cFileName, L".") == 0 || wcscmp(found.cFileName, L"..") == 0) continue;
      if (swprintf_s(child, sizeof child / sizeof child[0], L"%ls\\%ls", path, found.cFileName) < 0)
        continue;
      if (found.dwFileAttributes & FILE_ATTRIBUTE_READONLY)
        SetFileAttributesW(child, found.dwFileAttributes & ~FILE_ATTRIBUTE_READONLY);
      if ((found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) &&
          !(found.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
        delete_tree(child);
      } else if (found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
        RemoveDirectoryW(child);
      } else {
        DeleteFileW(child);
      }
    } while (FindNextFileW(search, &found));
    FindClose(search);
  }
  RemoveDirectoryW(path);
}

/* Delete DIR.old, the previous version an installer's swap leaves beside the install directory
   DIR, if it is there and is a directory. A junction or symbolic link of that name is removed
   as a link, and what it points to is not touched. */
static void delete_previous_version(const wchar_t *dir) {
  wchar_t old[MAX_PATH * 4];
  if (swprintf_s(old, sizeof old / sizeof old[0], L"%ls.old", dir) < 0) return;
  DWORD attributes = GetFileAttributesW(old);
  if (attributes == INVALID_FILE_ATTRIBUTES || !(attributes & FILE_ATTRIBUTE_DIRECTORY)) return;
  if (attributes & FILE_ATTRIBUTE_REPARSE_POINT) {
    RemoveDirectoryW(old);
  } else {
    delete_tree(old);
  }
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

  /* The core must be the one this launcher was built with (see OURANOS_CORE_SHA256 above). */
  {
    wchar_t found[65] = L"";
    wchar_t message[MAX_PATH * 4 + 512];
    /* Set and not empty: GetEnvironmentVariableW returns 0 for an empty value as for none, so
       a caller that clears the variable by emptying it does not leave the app unable to start. */
    wchar_t flag[8];
    BOOL check_only = GetEnvironmentVariableW(CHECK_ONLY_VARIABLE, flag, 8) > 0;
    DWORD err = sha256_file(core, found);
    if (check_only) {
      return (err == 0 && _wcsicmp(found, WSTR(OURANOS_CORE_SHA256)) == 0) ? 0 : EXIT_CORE_CHANGED;
    }
    if (err != 0) {
      swprintf_s(message, sizeof message / sizeof message[0],
                 L"cannot read %ls to check it (error %lu). Reinstall the app.", core, err);
      tell(message);
      return EXIT_CORE_CHANGED;
    }
    if (_wcsicmp(found, WSTR(OURANOS_CORE_SHA256)) != 0) {
      swprintf_s(message, sizeof message / sizeof message[0],
                 L"%ls is not the file this app was built with, so it was not started. "
                 L"It may have been changed or replaced since the app was installed. "
                 L"Reinstall the app. (SHA-256 expected %ls, found %ls)",
                 core, WSTR(OURANOS_CORE_SHA256), found);
      tell(message);
      return EXIT_CORE_CHANGED;
    }
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
  DWORD flags = GetConsoleWindow() == NULL ? DETACHED_PROCESS : 0;
  if (!CreateProcessW(runtime, line, NULL, NULL, TRUE, flags, NULL, NULL, &si, &pi)) {
    fail(L"cannot start", runtime);
    return 127;
  }
  CloseHandle(pi.hThread);
  /* The new version has started, so the previous one an update left beside it can go. */
  delete_previous_version(dir);
  WaitForSingleObject(pi.hProcess, INFINITE);
  DWORD code = 127;
  if (!GetExitCodeProcess(pi.hProcess, &code)) {
    fail(L"cannot read the exit code of", runtime);
    code = 127;
  }
  CloseHandle(pi.hProcess);
  return (int)code;
}
