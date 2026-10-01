// hyperion-view.cc --- a tiny native window hosting the OS webview at a URL.
//
//   usage:  hyperion-view URL [TITLE] [WIDTH] [HEIGHT] [--icon PATH] [--placement-file PATH]
//
// The native half of Hyperion's desktop capability (ADR-0008). The CL side
// (hyperion/desktop:run-app) starts a Hyperion server on localhost, then launches THIS
// as a subprocess pointed at it. Out-of-process on purpose: webview_run() owns this
// process's GUI main thread, so it never collides with SBCL's. One file over the MIT
// `webview.h`, which wraps WebKitGTK / WKWebView / WebView2. Build with ./build.sh.
//
// --icon (#74): webview.h 0.10.0 exposes no icon API, so this is three small platform
// paths hung off webview_get_window(). It sets the WINDOW icon, which on Windows is NOT
// the executable's icon (that comes from the PE resource of the .exe and needs the dumped
// SBCL image post-processed), and on macOS is outranked by a bundle's CFBundleIconFile
// once the app is bundled (#72). Format per platform: .ico on Windows, anything GdkPixbuf
// reads (.png) on Linux, anything NSImage reads on macOS.
#include <cerrno>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include "webview.h"
#include "window-placement.h"

#if defined(_WIN32)
#include <windows.h>
#include <shellapi.h>  // CommandLineToArgvW; webview.h includes windows.h in lean mode, without it
#elif defined(__APPLE__)
#include <objc/objc-runtime.h>
#else
#include <gtk/gtk.h>
#endif

// --- macOS main menu -------------------------------------------------------
//
// webview.h sets NSApplicationActivationPolicyRegular and calls
// activateIgnoringOtherApps:, so this process becomes a REGULAR foreground app -- it owns
// the system menu bar. It never calls setMainMenu:, so it owned the bar and put nothing in
// it. Two consequences, both reported against real apps:
//
//   * the menu bar is dead. Not "empty" -- unclickable, including the Apple menu, because
//     the frontmost application supplies no menu for the bar to route events through.
//   * Cmd-Q does nothing, so the window cannot be closed from the keyboard at all.
//
// Verified before the fix: with the launcher frontmost, System Events reports
// "Can't get menu bar 1 of process ... Invalid index" -- there is no menu bar object.
//
// THE EDIT MENU IS NOT DECORATION. On macOS the standard editing shortcuts are delivered
// through menu items' key equivalents, so a WKWebView with no Edit menu has no working
// Cmd-C / Cmd-V / Cmd-X / Cmd-A / Cmd-Z in any text field. That is the same root cause as
// the reported bug and it bites hardest in exactly the apps most likely to ship this way.
//
// Windows and Linux are deliberately untouched: neither has an application-owned system
// menu bar, their window close buttons and Alt-F4 / Ctrl-Q already work, and adding a
// menu there would be a new feature rather than a fix.
#if defined(__APPLE__)

// NSEventModifierFlags. Spelled out rather than included, because pulling in Cocoa headers
// would make this file Objective-C++ and the build script compiles it as C++.
static const unsigned long kCmd = 1UL << 20;
static const unsigned long kShift = 1UL << 17;
static const unsigned long kOption = 1UL << 19;

static id ns_string(const char *s) {
  return reinterpret_cast<id (*)(id, SEL, const char *)>(objc_msgSend)(
      reinterpret_cast<id>(objc_getClass("NSString")),
      sel_registerName("stringWithUTF8String:"), s);
}

static id ns_alloc(const char *cls) {
  return reinterpret_cast<id (*)(id, SEL)>(objc_msgSend)(
      reinterpret_cast<id>(objc_getClass(cls)), sel_registerName("alloc"));
}

// One menu item. ACTION is a selector name sent up the responder chain -- nullptr leaves
// the item inert. KEY is the key equivalent; MASK its modifiers (0 = no shortcut).
static void add_item(id menu, const char *title, const char *action, const char *key,
                     unsigned long mask) {
  id item = reinterpret_cast<id (*)(id, SEL, id, SEL, id)>(objc_msgSend)(
      ns_alloc("NSMenuItem"), sel_registerName("initWithTitle:action:keyEquivalent:"),
      ns_string(title), action != nullptr ? sel_registerName(action) : nullptr,
      ns_string(key));
  if (mask != 0) {
    reinterpret_cast<void (*)(id, SEL, unsigned long)>(objc_msgSend)(
        item, sel_registerName("setKeyEquivalentModifierMask:"), mask);
  }
  reinterpret_cast<void (*)(id, SEL, id)>(objc_msgSend)(menu, sel_registerName("addItem:"),
                                                        item);
}

static void add_separator(id menu) {
  id sep = reinterpret_cast<id (*)(id, SEL)>(objc_msgSend)(
      reinterpret_cast<id>(objc_getClass("NSMenuItem")), sel_registerName("separatorItem"));
  reinterpret_cast<void (*)(id, SEL, id)>(objc_msgSend)(menu, sel_registerName("addItem:"),
                                                        sep);
}

// A top-level menu. macOS ignores the FIRST submenu's title and shows the process name
// instead, which is why set_process_name below exists.
static id add_submenu(id main_menu, const char *title) {
  id item = reinterpret_cast<id (*)(id, SEL, id, SEL, id)>(objc_msgSend)(
      ns_alloc("NSMenuItem"), sel_registerName("initWithTitle:action:keyEquivalent:"),
      ns_string(title), nullptr, ns_string(""));
  id menu = reinterpret_cast<id (*)(id, SEL, id)>(objc_msgSend)(
      ns_alloc("NSMenu"), sel_registerName("initWithTitle:"), ns_string(title));
  reinterpret_cast<void (*)(id, SEL, id)>(objc_msgSend)(item, sel_registerName("setSubmenu:"),
                                                        menu);
  reinterpret_cast<void (*)(id, SEL, id)>(objc_msgSend)(main_menu,
                                                        sel_registerName("addItem:"), item);
  return menu;
}

// Make the app present itself under its OWN name rather than "hyperion-view". Every
// Hyperion desktop app runs the same launcher binary, so without this they all appear
// identically -- which matters as soon as a machine runs two of them.
//
// TWO mechanisms, because they feed different things and only one of them is the menu:
//
//   setProcessName:  the process's own name. Measured: it applies. It does NOT retitle the
//                    menu bar, which was my first assumption and was wrong.
//   CFBundleName     what AppKit actually reads for the application menu's title. An
//                    unbundled process has no Info.plist, but -[NSBundle infoDictionary]
//                    returns a MUTABLE dictionary (measured: __NSDictionaryM), so the key
//                    can be inserted before AppKit reads it.
//
// The second is undocumented and guarded accordingly: if the dictionary is ever immutable,
// respondsToSelector: fails and the app falls back to the launcher's name. Cosmetic, and a
// wrong name is a far better outcome than a crash on startup. A real .app bundle (#72)
// supplies CFBundleName properly and makes this path moot.
static void set_app_name(const char *name) {
  id info = reinterpret_cast<id (*)(id, SEL)>(objc_msgSend)(
      reinterpret_cast<id>(objc_getClass("NSProcessInfo")), sel_registerName("processInfo"));
  SEL setter = sel_registerName("setProcessName:");
  if (reinterpret_cast<BOOL (*)(id, SEL, SEL)>(objc_msgSend)(
          info, sel_registerName("respondsToSelector:"), setter)) {
    reinterpret_cast<void (*)(id, SEL, id)>(objc_msgSend)(info, setter, ns_string(name));
  }

  id bundle = reinterpret_cast<id (*)(id, SEL)>(objc_msgSend)(
      reinterpret_cast<id>(objc_getClass("NSBundle")), sel_registerName("mainBundle"));
  id dict = reinterpret_cast<id (*)(id, SEL)>(objc_msgSend)(
      bundle, sel_registerName("infoDictionary"));
  SEL put = sel_registerName("setObject:forKey:");
  if (dict != nullptr && reinterpret_cast<BOOL (*)(id, SEL, SEL)>(objc_msgSend)(
                             dict, sel_registerName("respondsToSelector:"), put)) {
    reinterpret_cast<void (*)(id, SEL, id, id)>(objc_msgSend)(
        dict, put, ns_string(name), ns_string("CFBundleName"));
  }
}

static void install_main_menu(const char *app_name) {
  std::string name(app_name);
  id main_menu = reinterpret_cast<id (*)(id, SEL)>(objc_msgSend)(ns_alloc("NSMenu"),
                                                                 sel_registerName("init"));

  id app_menu = add_submenu(main_menu, app_name);
  add_item(app_menu, ("About " + name).c_str(), "orderFrontStandardAboutPanel:", "", 0);
  add_separator(app_menu);
  add_item(app_menu, ("Hide " + name).c_str(), "hide:", "h", kCmd);
  add_item(app_menu, "Hide Others", "hideOtherApplications:", "h", kCmd | kOption);
  add_item(app_menu, "Show All", "unhideAllApplications:", "", 0);
  add_separator(app_menu);
  // terminate: routes through webview.h's applicationShouldTerminate: delegate, so the
  // run loop is stopped the same way closing the last window stops it.
  add_item(app_menu, ("Quit " + name).c_str(), "terminate:", "q", kCmd);

  id edit_menu = add_submenu(main_menu, "Edit");
  add_item(edit_menu, "Undo", "undo:", "z", kCmd);
  add_item(edit_menu, "Redo", "redo:", "z", kCmd | kShift);
  add_separator(edit_menu);
  add_item(edit_menu, "Cut", "cut:", "x", kCmd);
  add_item(edit_menu, "Copy", "copy:", "c", kCmd);
  add_item(edit_menu, "Paste", "paste:", "v", kCmd);
  add_item(edit_menu, "Select All", "selectAll:", "a", kCmd);

  id app = reinterpret_cast<id (*)(id, SEL)>(objc_msgSend)(
      reinterpret_cast<id>(objc_getClass("NSApplication")),
      sel_registerName("sharedApplication"));
  reinterpret_cast<void (*)(id, SEL, id)>(objc_msgSend)(
      app, sel_registerName("setMainMenu:"), main_menu);
}

#else
static void set_app_name(const char *) {}
static void install_main_menu(const char *) {}
#endif

// Set the window icon from PATH, or do nothing if it cannot be loaded. Deliberately
// silent on failure: a missing or malformed icon is a cosmetic problem, and refusing to
// open the window over one would promote it to a fatal one.
static void set_window_icon(webview_t w, const char *path) {
  if (path == nullptr || *path == '\0') {
    return;
  }
#if defined(_WIN32)
  // LoadImageW, not LoadImageA: PATH is UTF-8 (main converts the command line on Windows,
  // see utf8_argv), and a path with non-ASCII in it (a user directory, typically) would
  // otherwise fail to resolve.
  int wide_len = MultiByteToWideChar(CP_UTF8, 0, path, -1, nullptr, 0);
  if (wide_len <= 0) {
    return;
  }
  wchar_t *wide = static_cast<wchar_t *>(std::calloc(static_cast<size_t>(wide_len),
                                                     sizeof(wchar_t)));
  if (wide == nullptr) {
    return;
  }
  MultiByteToWideChar(CP_UTF8, 0, path, -1, wide, wide_len);
  HWND hwnd = static_cast<HWND>(webview_get_window(w));
  // Two sizes, loaded separately: WM_SETICON does no scaling, so handing the big icon to
  // ICON_SMALL yields a blurry titlebar/taskbar glyph. LR_DEFAULTSIZE takes the largest
  // image in the .ico; the small one asks for the system's small-icon metric.
  // NB: not `small` -- rpcndr.h, pulled in by windows.h, #defines it to `char`, and the
  // resulting error points at the line AFTER the declaration.
  HICON icon_big = static_cast<HICON>(LoadImageW(nullptr, wide, IMAGE_ICON, 0, 0,
                                                 LR_LOADFROMFILE | LR_DEFAULTSIZE));
  HICON icon_small = static_cast<HICON>(LoadImageW(nullptr, wide, IMAGE_ICON,
                                                   GetSystemMetrics(SM_CXSMICON),
                                                   GetSystemMetrics(SM_CYSMICON),
                                                   LR_LOADFROMFILE));
  if (icon_big != nullptr) {
    SendMessageW(hwnd, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(icon_big));
  }
  if (icon_small != nullptr) {
    SendMessageW(hwnd, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(icon_small));
  }
  std::free(wide);
#elif defined(__APPLE__)
  // The Dock/app icon, through the objc runtime -- the mechanism webview.h itself uses.
  // UNVERIFIED from this machine (#74 assigns macOS to the mac instance). Inside a .app
  // bundle CFBundleIconFile wins regardless, so this covers the unbundled/dev case.
  id str = reinterpret_cast<id (*)(id, SEL, const char *)>(objc_msgSend)(
      reinterpret_cast<id>(objc_getClass("NSString")),
      sel_registerName("stringWithUTF8String:"), path);
  id image = reinterpret_cast<id (*)(id, SEL)>(objc_msgSend)(
      reinterpret_cast<id>(objc_getClass("NSImage")), sel_registerName("alloc"));
  image = reinterpret_cast<id (*)(id, SEL, id)>(objc_msgSend)(
      image, sel_registerName("initWithContentsOfFile:"), str);
  if (image == nullptr) {
    return;
  }
  id app = reinterpret_cast<id (*)(id, SEL)>(objc_msgSend)(
      reinterpret_cast<id>(objc_getClass("NSApplication")),
      sel_registerName("sharedApplication"));
  reinterpret_cast<void (*)(id, SEL, id)>(objc_msgSend)(
      app, sel_registerName("setApplicationIconImage:"), image);
#else
#if GTK_MAJOR_VERSION >= 4
  // GTK4 dropped per-window icons from a file: an app declares an ICON NAME and the
  // desktop resolves it through the icon theme. There is nothing honest to do with a path
  // here, so leave the default rather than pretend it worked.
  (void)w;
#else
  GtkWindow *win = GTK_WINDOW(webview_get_window(w));
  GError *err = nullptr;
  if (gtk_window_set_icon_from_file(win, path, &err) == FALSE && err != nullptr) {
    g_error_free(err);
  }
#endif
#endif
}

// USAGE GOES TO STDOUT AND EXITS, AND THAT IS THE WHOLE OF pre-publication issue 268. There was no --help at
// all: it fell through to positional[0], became the URL, and webview_run() blocked
// forever on a window showing a failed navigation to the string "--help". Measured
// before the fix -- exited=FALSE after 5s, stdout empty, stderr empty.
//
// It is printed here, before webview_create, because everything after that point needs a
// window server. A --help that requires a display is not a --help.
// Put the window in the work area of the monitor it opened on: centred, and shrunk to fit
// when it is larger (window-placement.h, #485). Windows only. On macOS webview_set_size
// already centres the window ([NSWindow center]); on Linux the window manager places it.
//
// With REPORT, it also prints one line there: the work area, the DPI, what the frame adds, the
// placement computed, and the window's rectangle as Windows reports it after SetWindowPos --
// for --report-placement, which is how a test sees the real calls (review of train 20). A
// step that fails is reported as "placement-failed STEP" and nothing is moved.
static bool place_window(webview_t w, int width, int height, std::FILE *report = nullptr) {
#if defined(_WIN32)
  auto failed = [report](const char *step) {
    if (report != nullptr) std::fprintf(report, "placement-failed %s\n", step);
    return false;
  };
  HWND hwnd = static_cast<HWND>(webview_get_window(w));
  if (hwnd == nullptr) return failed("webview_get_window");
  MONITORINFO info;
  info.cbSize = sizeof info;
  if (!GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &info))
    return failed("GetMonitorInfoW");
  RECT outer, client;
  if (!GetWindowRect(hwnd, &outer) || !GetClientRect(hwnd, &client))
    return failed("GetWindowRect");
  // What the frame adds, measured on the window webview_set_size has just sized, rather than
  // recomputed: it already reflects the window's style and DPI.
  long frame_width = (outer.right - outer.left) - (client.right - client.left);
  long frame_height = (outer.bottom - outer.top) - (client.bottom - client.top);
  long dpi = static_cast<long>(GetDpiForWindow(hwnd));
  window_placement p = place_in_work_area(info.rcWork.left, info.rcWork.top,
                                          info.rcWork.right, info.rcWork.bottom, width, height,
                                          dpi, frame_width, frame_height);
  if (!SetWindowPos(hwnd, nullptr, p.x, p.y, p.width, p.height, SWP_NOZORDER | SWP_NOACTIVATE))
    return failed("SetWindowPos");
  if (report != nullptr) {
    RECT placed;
    if (!GetWindowRect(hwnd, &placed)) return failed("GetWindowRect after SetWindowPos");
    std::fprintf(report,
                 "work %ld %ld %ld %ld dpi %ld frame %ld %ld placement %ld %ld %ld %ld "
                 "window %ld %ld %ld %ld\n",
                 static_cast<long>(info.rcWork.left), static_cast<long>(info.rcWork.top),
                 static_cast<long>(info.rcWork.right), static_cast<long>(info.rcWork.bottom), dpi,
                 frame_width, frame_height, p.x, p.y, p.width, p.height,
                 static_cast<long>(placed.left), static_cast<long>(placed.top),
                 static_cast<long>(placed.right), static_cast<long>(placed.bottom));
  }
  return true;
#else
  (void)w;
  (void)width;
  (void)height;
  if (report != nullptr) std::fprintf(report, "placement-unsupported\n");
  return false;
#endif
}

// --- the last placement (#485, part 2) -------------------------------------------------
//
// --placement-file PATH puts the window back where it was last time, and keeps PATH up to date
// while it is open. The line's format and the rule for when a saved rectangle is used are in
// window-placement.h. Windows only for now: on macOS and Linux the option is accepted and does
// nothing.
//
// The file is written after every move or resize, when the window is maximised or restored,
// and when it is closed, not only at the end: hyperion/desktop:run-app ends this process with
// TerminateProcess when the app closes the window itself, and a save left for the end would
// then never happen. Each write goes to PATH.tmp and is renamed over PATH, so a process ended
// part-way through leaves the previous line, not half of a new one.

// Up to 256 bytes of the file at PATH (UTF-8), or "" if it cannot be read. A placement line is
// about 60 bytes.
static std::string read_small_file(const char *path) {
  std::string out;
#if defined(_WIN32)
  int wide_len = MultiByteToWideChar(CP_UTF8, 0, path, -1, nullptr, 0);
  if (wide_len <= 0) return out;
  std::wstring wide(static_cast<size_t>(wide_len - 1), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, path, -1, &wide[0], wide_len);
  std::FILE *f = _wfopen(wide.c_str(), L"rb");
#else
  std::FILE *f = std::fopen(path, "rb");
#endif
  if (f == nullptr) return out;
  char buf[256];
  size_t n = std::fread(buf, 1, sizeof buf, f);
  std::fclose(f);
  return std::string(buf, n);
}

// The placement saved at PATH, in *OUT. False, with *REASON, when the file cannot be read or is
// not one placement line.
static bool load_saved_placement(const char *path, saved_placement *out, const char **reason) {
  std::string text = read_small_file(path);
  if (text.empty()) {
    *reason = "unreadable";
    return false;
  }
  if (text.find('\0') != std::string::npos || !parse_saved_placement(text.c_str(), out)) {
    *reason = "malformed";
    return false;
  }
  return true;
}

#if defined(_WIN32)
static std::wstring g_placement_path;
// The window's rectangle when it was last neither maximised nor minimised: what is saved while
// it is maximised, so that restoring it un-maximises to the right place.
static RECT g_normal_rect;
static bool g_have_normal_rect = false;
static bool g_in_size_move = false;
static WNDPROC g_previous_window_proc = nullptr;

static void set_placement_path(const char *path) {
  int wide_len = MultiByteToWideChar(CP_UTF8, 0, path, -1, nullptr, 0);
  if (wide_len <= 0) return;
  g_placement_path.assign(static_cast<size_t>(wide_len - 1), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, path, -1, &g_placement_path[0], wide_len);
}

// Write where HWND is to the placement file. False when there is no file, the window is
// minimised, or the write failed.
static bool save_placement(HWND hwnd) {
  if (g_placement_path.empty() || IsIconic(hwnd)) return false;
  bool maximized = IsZoomed(hwnd) != 0;
  if (!maximized) {
    RECT r;
    if (!GetWindowRect(hwnd, &r)) return false;
    g_normal_rect = r;
    g_have_normal_rect = true;
  }
  if (!g_have_normal_rect) return false;
  saved_placement p = {g_normal_rect.left, g_normal_rect.top, g_normal_rect.right,
                       g_normal_rect.bottom, maximized};
  char line[128];
  int n = format_saved_placement(p, line, sizeof line);
  if (n <= 0 || n >= static_cast<int>(sizeof line)) return false;
  std::wstring tmp = g_placement_path + L".tmp";
  std::FILE *f = _wfopen(tmp.c_str(), L"wb");
  if (f == nullptr) return false;
  bool ok = std::fwrite(line, 1, static_cast<size_t>(n), f) == static_cast<size_t>(n);
  ok = (std::fclose(f) == 0) && ok;
  if (!ok) {
    _wremove(tmp.c_str());
    return false;
  }
  return MoveFileExW(tmp.c_str(), g_placement_path.c_str(), MOVEFILE_REPLACE_EXISTING) != 0;
}

// Ahead of webview.h's own window procedure: saves the placement when a move or resize ends,
// when the window is maximised or restored, and when it is closed. WM_SIZE during a drag is
// left to WM_EXITSIZEMOVE, so a resize writes the file once.
static LRESULT CALLBACK placement_window_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
  case WM_ENTERSIZEMOVE:
    g_in_size_move = true;
    break;
  case WM_EXITSIZEMOVE:
    g_in_size_move = false;
    save_placement(hwnd);
    break;
  case WM_SIZE:
    if (!g_in_size_move && (wp == SIZE_MAXIMIZED || wp == SIZE_RESTORED)) save_placement(hwnd);
    break;
  case WM_CLOSE:
    save_placement(hwnd);
    break;
  default:
    break;
  }
  return CallWindowProcW(g_previous_window_proc, hwnd, msg, wp, lp);
}

// Keep PATH up to date while the window of W is open.
static void watch_placement(webview_t w, const char *path) {
  HWND hwnd = static_cast<HWND>(webview_get_window(w));
  if (hwnd == nullptr) return;
  set_placement_path(path);
  if (!g_have_normal_rect && !IsZoomed(hwnd) && GetWindowRect(hwnd, &g_normal_rect))
    g_have_normal_rect = true;
  g_previous_window_proc = reinterpret_cast<WNDPROC>(SetWindowLongPtrW(
      hwnd, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(placement_window_proc)));
}

// Put the window of W where the file at PATH says, if that still fits the work area of the
// monitor it is on. False when it was not used, and the caller places the window instead. With
// REPORT, one line is printed there: "restored L T R B MAXIMIZED window L T R B", or
// "restore-ignored REASON". MAXIMIZE false leaves a saved maximised window unmaximised, for
// --report-placement, whose window must stay hidden.
static bool restore_placement(webview_t w, const char *path, std::FILE *report, bool maximize) {
  auto ignored = [report](const char *why) {
    if (report != nullptr) std::fprintf(report, "restore-ignored %s\n", why);
    return false;
  };
  HWND hwnd = static_cast<HWND>(webview_get_window(w));
  if (hwnd == nullptr) return ignored("webview_get_window");
  saved_placement p;
  const char *reason = nullptr;
  if (!load_saved_placement(path, &p, &reason)) return ignored(reason);
  RECT r = {p.left, p.top, p.right, p.bottom};
  HMONITOR monitor = MonitorFromRect(&r, MONITOR_DEFAULTTONULL);
  if (monitor == nullptr) return ignored("off-screen");
  MONITORINFO info;
  info.cbSize = sizeof info;
  if (!GetMonitorInfoW(monitor, &info)) return ignored("GetMonitorInfoW");
  if (!saved_placement_fits(p, info.rcWork.left, info.rcWork.top, info.rcWork.right,
                            info.rcWork.bottom))
    return ignored("does-not-fit");
  if (!SetWindowPos(hwnd, nullptr, p.left, p.top, p.right - p.left, p.bottom - p.top,
                    SWP_NOZORDER | SWP_NOACTIVATE))
    return ignored("SetWindowPos");
  g_normal_rect = r;
  g_have_normal_rect = true;
  if (p.maximized && maximize) ShowWindow(hwnd, SW_MAXIMIZE);
  if (report != nullptr) {
    RECT placed;
    if (!GetWindowRect(hwnd, &placed)) return ignored("GetWindowRect after SetWindowPos");
    std::fprintf(report, "restored %ld %ld %ld %ld %d window %ld %ld %ld %ld\n", p.left, p.top,
                 p.right, p.bottom, p.maximized ? 1 : 0, static_cast<long>(placed.left),
                 static_cast<long>(placed.top), static_cast<long>(placed.right),
                 static_cast<long>(placed.bottom));
  }
  return true;
}
#endif

// HYPERION_VIEW_NO_WINDOW=1 stops hyperion-view just before it would create a window, with exit
// code 3 and a line on stderr. The view tests set it for every run they make on a developer's
// machine, so a test that reaches webview_create by mistake fails there instead of opening a
// window on someone's screen; only the CI-only real-window tests clear it (#521). The modes that
// never create a window (--help, --placement, --saved-placement, and every refusal) ignore it.
static bool window_forbidden() {
  const char *value = std::getenv("HYPERION_VIEW_NO_WINDOW");
  if (value == nullptr || std::strcmp(value, "1") != 0) return false;
  std::fprintf(stderr, "hyperion-view: HYPERION_VIEW_NO_WINDOW=1 is set, so no window is created\n");
  return true;
}

// TEXT as a long, in *OUT. False unless all of TEXT is a decimal number that fits.
static bool parse_long(const char *text, long *out) {
  errno = 0;
  char *end = nullptr;
  long value = std::strtol(text, &end, 10);
  if (end == text || *end != '\0' || errno == ERANGE) return false;
  *out = value;
  return true;
}

// TEXT as a positive int, in *OUT. False unless all of TEXT is a decimal number from 1 to
// INT_MAX: std::atoi reads "1280px" as 1280 and "x" as 0, and says nothing about either.
static bool parse_positive_int(const char *text, int *out) {
  errno = 0;
  char *end = nullptr;
  long value = std::strtol(text, &end, 10);
  if (end == text || *end != '\0' || errno == ERANGE || value <= 0 || value > INT_MAX)
    return false;
  *out = static_cast<int>(value);
  return true;
}

static void print_usage(std::FILE *out) {
  std::fprintf(out,
               "usage: hyperion-view URL [TITLE] [WIDTH] [HEIGHT] [--icon PATH]\n"
               "                     [--placement-file PATH]\n"
               "\n"
               "  URL      the address to open      (default http://127.0.0.1:8080/)\n"
               "  TITLE    the window title         (default \"App\")\n"
               "  WIDTH    window width in pixels   (default 1200)\n"
               "  HEIGHT   window height in pixels  (default 800)\n"
               "  --icon   path to a window icon    (optional, may appear anywhere)\n"
               "  --placement-file PATH\n"
               "           Windows: open the window where it was last time, if that still fits\n"
               "           a monitor, and keep PATH up to date (optional, may appear anywhere)\n"
               "\n"
               "  --help, -h   print this and exit\n"
               "\n"
               "  With HYPERION_VIEW_NO_WINDOW=1 in the environment, it exits 3 instead of\n"
               "  creating a window.\n"
               "\n"
               "  --placement WL WT WR WB CW CH DPI FW FH\n"
               "               print, as X Y WIDTH HEIGHT, where a window with a client area of\n"
               "               CW x CH logical pixels, at DPI, with a frame adding FW x FH, is\n"
               "               put in the work area WL,WT-WR,WB; then exit (#485)\n"
               "  --report-placement WIDTH HEIGHT [PLACEMENT-FILE]\n"
               "               Windows: create the window, size and place it as a launch does,\n"
               "               print the work area, DPI, frame, placement and the window's\n"
               "               rectangle, then exit without running it. Start it hidden. With\n"
               "               PLACEMENT-FILE, restore from it first and save to it after.\n"
               "  --saved-placement PATH WL WT WR WB\n"
               "               print \"use L T R B MAXIMIZED\" if the placement saved at PATH would\n"
               "               be restored into the work area WL,WT-WR,WB, else \"ignore REASON\"\n"
               "\n"
               "Hyperion's native webview launcher. hyperion/desktop:run-app starts a\n"
               "server on localhost and launches this pointed at it.\n");
}

#if defined(_WIN32)
// The command line as UTF-8 strings (#116). On Windows the C runtime builds main's argv in
// the ANSI code page, while everything below treats the strings as UTF-8: webview.h widens
// the title with CP_UTF8, and set_window_icon does the same for the icon path. A non-ASCII
// character therefore emptied the window title and stopped the icon loading, with no error.
// Measured before this change on Windows 11 (code page 1252): a title containing an e with
// an acute accent, an em dash, two Japanese characters and a Greek omega came back empty from
// GetWindowTextW, and an .ico under a directory whose name had a u-umlaut and Japanese
// characters in it was not set, while an all-ASCII title and icon path worked.
//
// So the arguments are read as UTF-16 from the command line the process was given and
// converted to UTF-8 once, here, leaving the rest of the file unchanged.
static std::vector<std::string> utf8_argv() {
  std::vector<std::string> out;
  int n = 0;
  LPWSTR *wide = CommandLineToArgvW(GetCommandLineW(), &n);
  if (wide == nullptr) {
    return out;
  }
  for (int i = 0; i < n; i++) {
    int len = WideCharToMultiByte(CP_UTF8, 0, wide[i], -1, nullptr, 0, nullptr, nullptr);
    std::string s(len > 0 ? static_cast<size_t>(len - 1) : 0, '\0');
    if (len > 1) {
      WideCharToMultiByte(CP_UTF8, 0, wide[i], -1, &s[0], len, nullptr, nullptr);
    }
    out.push_back(s);
  }
  LocalFree(wide);
  return out;
}
#endif

int main(int argc, char **argv) {
#if defined(_WIN32)
  // Static so the pointers stay valid for the life of the process: the title and the icon
  // path are read after webview_run starts.
  static std::vector<std::string> utf8_args = utf8_argv();
  static std::vector<char *> utf8_ptrs;
  if (!utf8_args.empty()) {
    for (std::string &s : utf8_args) {
      utf8_ptrs.push_back(&s[0]);
    }
    utf8_ptrs.push_back(nullptr);
    argc = static_cast<int>(utf8_args.size());
    argv = utf8_ptrs.data();
  }
#endif
  const char *icon = nullptr;
  const char *placement_file = nullptr;
  const char *positional[4] = {nullptr, nullptr, nullptr, nullptr};
  int n = 0;

  // Positional URL TITLE WIDTH HEIGHT is the established contract (hyperion/desktop builds
  // it), so --icon is scanned out of argv wherever it appears rather than claiming a fifth
  // slot -- an unrecognised flag must never silently become the window title.
  //
  // THAT LAST CLAUSE WAS A CLAIM THE CODE DID NOT KEEP. Any unrecognised --flag, and a
  // trailing --icon with no path after it, fell into the positional branch: `hyperion-view
  // URL --icon` set the TITLE to the literal string "--icon". Refused now, loudly, on
  // stderr with a non-zero exit -- a launcher that silently retitles your window when you
  // mistype a flag is worse than one that stops.
  for (int i = 1; i < argc; i++) {
    if (std::strcmp(argv[i], "--help") == 0 || std::strcmp(argv[i], "-h") == 0) {
      print_usage(stdout);
      return 0;
    } else if (std::strcmp(argv[i], "--report-placement") == 0) {
      // The real calls, on a real window, which --placement cannot reach: it returns before
      // webview_create. The window is shown by webview.h when it is created; a caller that
      // starts this with a hidden show state (STARTF_USESHOWWINDOW, SW_HIDE) keeps it hidden,
      // because Windows applies that to a process's first ShowWindow. Exactly WIDTH and
      // HEIGHT, and nothing else, for the reason given for --placement below.
      if (i != 1 || (argc != 4 && argc != 5)) {
        std::fprintf(stderr, "hyperion-view: --report-placement takes WIDTH and HEIGHT, and "
                             "optionally a placement file, and nothing else\n\n");
        print_usage(stderr);
        return 2;
      }
      int rw = 0;
      int rh = 0;
      if (!parse_positive_int(argv[2], &rw) || !parse_positive_int(argv[3], &rh)) {
        std::fprintf(stderr,
                     "hyperion-view: --report-placement: WIDTH and HEIGHT must be positive integers\n\n");
        print_usage(stderr);
        return 2;
      }
      if (window_forbidden()) return 3;
      webview_t rv = webview_create(0, nullptr);
      if (rv == nullptr) {
        // No window was created (no display, or no WebView2), so there is nothing to place.
        std::printf("placement-failed webview_create\n");
        std::fflush(stdout);
        return 1;
      }
      webview_set_size(rv, rw, rh, WEBVIEW_HINT_NONE);
      const char *file = argc == 5 ? argv[4] : nullptr;
      bool ok = true;
#if defined(_WIN32)
      if (file == nullptr || !restore_placement(rv, file, stdout, false))
        ok = place_window(rv, rw, rh, stdout);
      if (ok && file != nullptr) {
        set_placement_path(file);
        bool saved = save_placement(static_cast<HWND>(webview_get_window(rv)));
        std::printf(saved ? "saved\n" : "save-failed\n");
        ok = saved;
      }
#else
      (void)file;
      ok = place_window(rv, rw, rh, stdout);
#endif
      std::fflush(stdout);
      webview_destroy(rv);
      return ok ? 0 : 1;
    } else if (std::strcmp(argv[i], "--saved-placement") == 0) {
      // The restore decision on its own, with no window, so the tests check it on every OS.
      long work[4];
      bool numbers = i == 1 && argc == 7;
      for (int k = 0; numbers && k < 4; k++) numbers = parse_long(argv[3 + k], &work[k]);
      if (!numbers) {
        std::fprintf(stderr,
                     "hyperion-view: --saved-placement takes a path and 4 integers and nothing "
                     "else\n\n");
        print_usage(stderr);
        return 2;
      }
      saved_placement p;
      const char *reason = nullptr;
      if (!load_saved_placement(argv[2], &p, &reason)) {
        std::printf("ignore %s\n", reason);
      } else if (!saved_placement_fits(p, work[0], work[1], work[2], work[3])) {
        std::printf("ignore does-not-fit\n");
      } else {
        std::printf("use %ld %ld %ld %ld %d\n", p.left, p.top, p.right, p.bottom,
                    p.maximized ? 1 : 0);
      }
      return 0;
    } else if (std::strcmp(argv[i], "--placement") == 0) {
      // The placement arithmetic on its own, with no window: for the tests, which check it on
      // every OS, and for anyone asking why a window opened where it did. It is a mode of its
      // own, so it must be the only option and have exactly nine values: anything before it or
      // after them would otherwise be ignored without a word, as surplus arguments never are.
      if (i != 1 || argc != 11) {
        std::fprintf(stderr,
                     "hyperion-view: --placement takes exactly 9 integers and nothing else\n\n");
        print_usage(stderr);
        return 2;
      }
      long v[9];
      for (int k = 0; k < 9; k++) {
        char *end = nullptr;
        v[k] = std::strtol(argv[i + 1 + k], &end, 10);
        if (end == argv[i + 1 + k] || *end != '\0') {
          std::fprintf(stderr, "hyperion-view: --placement: not an integer: %s\n\n",
                       argv[i + 1 + k]);
          print_usage(stderr);
          return 2;
        }
      }
      window_placement p =
          place_in_work_area(v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8]);
      std::printf("%ld %ld %ld %ld\n", p.x, p.y, p.width, p.height);
      return 0;
    } else if (std::strcmp(argv[i], "--icon") == 0) {
      if (i + 1 >= argc) {
        std::fprintf(stderr, "hyperion-view: --icon needs a path\n\n");
        print_usage(stderr);
        return 2;
      }
      icon = argv[++i];
    } else if (std::strcmp(argv[i], "--placement-file") == 0) {
      if (i + 1 >= argc) {
        std::fprintf(stderr, "hyperion-view: --placement-file needs a path\n\n");
        print_usage(stderr);
        return 2;
      }
      placement_file = argv[++i];
    } else if (argv[i][0] == '-' && argv[i][1] != '\0') {
      std::fprintf(stderr, "hyperion-view: unknown option %s\n\n", argv[i]);
      print_usage(stderr);
      return 2;
    } else if (n < 4) {
      positional[n++] = argv[i];
    } else {
      std::fprintf(stderr, "hyperion-view: too many arguments (%s)\n\n", argv[i]);
      print_usage(stderr);
      return 2;
    }
  }

  const char *url = positional[0] != nullptr ? positional[0] : "http://127.0.0.1:8080/";
  const char *title = positional[1] != nullptr ? positional[1] : "App";
  int width = positional[2] != nullptr ? std::atoi(positional[2]) : 1200;
  int height = positional[3] != nullptr ? std::atoi(positional[3]) : 800;

  // Before webview_create: that is where NSApplication is first created, and AppKit reads
  // the application name once, early.
  set_app_name(title);

  if (window_forbidden()) return 3;
  webview_t w = webview_create(0, nullptr);
  webview_set_title(w, title);
  webview_set_size(w, width, height, WEBVIEW_HINT_NONE);
#if defined(_WIN32)
  if (placement_file == nullptr || !restore_placement(w, placement_file, nullptr, true))
    place_window(w, width, height);
  if (placement_file != nullptr) watch_placement(w, placement_file);
#else
  place_window(w, width, height);
#endif
  set_window_icon(w, icon);
  // After webview_create (NSApp exists), before webview_run ([NSApp run]).
  install_main_menu(title);
  webview_navigate(w, url);
  webview_run(w);
  webview_destroy(w);
  return 0;
}
