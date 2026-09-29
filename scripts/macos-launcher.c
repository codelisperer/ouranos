/* macos-launcher.c --- the executable a macOS desktop app starts from (#98, #332).
 *
 * A macOS bundle from scripts/build-desktop-app.lisp holds three files where it used to hold
 * one dumped image:
 *
 *     Contents/MacOS/<name>       this launcher
 *     Contents/MacOS/sbcl         the SBCL runtime (patched per ADR-0014, signed ad hoc)
 *     Contents/MacOS/sbcl.core    the app's Lisp core, dumped with :executable nil
 *
 * WHY NOT ONE FILE. A dumped image appends the core past the end of the Mach-O, so codesign
 * cannot sign it, and Gatekeeper reports a downloaded copy as damaged, with no Open Anyway.
 * With the core in its own file, the whole .app signs ad hoc and verifies, and Gatekeeper gives
 * the ordinary "Not Opened" prompt that System Settings can open (#332).
 *
 * WHY A LAUNCHER. A core dumped without the runtime cannot carry runtime options:
 * :save-runtime-options is ignored unless :executable is true. So the bare runtime would start
 * with its default heap (1024 MB, where the single file saved 4096) and would take any app
 * argument matching one of its own options, such as --version, for itself (#98). This passes
 * the heap the build chose, and ends runtime-option processing before the app's arguments.
 *
 * OURANOS_HEAP_MB is set when build-desktop-app.lisp compiles this file, to the heap of the
 * process that dumped the core.
 */

#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef OURANOS_HEAP_MB
#error "compile with -DOURANOS_HEAP_MB=<megabytes>"
#endif

#define STR2(x) #x
#define STR(x) STR2(x)

int main(int argc, char **argv) {
  char raw[PATH_MAX], dir[PATH_MAX], runtime[PATH_MAX], core[PATH_MAX];
  uint32_t size = sizeof raw;

  /* The directory this file is in, resolved, so a launch through a symlink or from App
     Translocation still finds the runtime and the core beside the launcher. */
  if (_NSGetExecutablePath(raw, &size) != 0 || realpath(raw, dir) == NULL) {
    perror("launcher: cannot find its own path");
    return 127;
  }
  char *slash = strrchr(dir, '/');
  if (slash == NULL) {
    fprintf(stderr, "launcher: its own path has no directory: %s\n", dir);
    return 127;
  }
  *slash = '\0';

  if (snprintf(runtime, sizeof runtime, "%s/sbcl", dir) >= (int)sizeof runtime ||
      snprintf(core, sizeof core, "%s/sbcl.core", dir) >= (int)sizeof core) {
    fprintf(stderr, "launcher: path too long: %s\n", dir);
    return 127;
  }

  /* argv[0] is kept, so the app sees the name it was started by, as it did as one file. */
  char **args = calloc((size_t)argc + 8, sizeof *args);
  if (args == NULL) {
    perror("launcher");
    return 127;
  }
  int n = 0;
  args[n++] = argv[0];
  args[n++] = "--core";
  args[n++] = core;
  args[n++] = "--dynamic-space-size";
  args[n++] = STR(OURANOS_HEAP_MB);
  args[n++] = "--noinform";
  args[n++] = "--end-runtime-options";
  for (int i = 1; i < argc; i++) args[n++] = argv[i];
  args[n] = NULL;

  execv(runtime, args);
  fprintf(stderr, "launcher: cannot start %s: ", runtime);
  perror(NULL);
  return 127;
}
