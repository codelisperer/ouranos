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
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>
#include "webview.h"
#include "window-placement.h"
#include "dialog-request.h"

#if defined(_WIN32)
#include <windows.h>
#include <shellapi.h>  // CommandLineToArgvW; webview.h includes windows.h in lean mode, without it
#include <bcrypt.h>    // BCryptGenRandom, for the dialog binding's token (#986)
#include <shobjidl.h>  // IFileOpenDialog, IFileSaveDialog (#986)
#elif defined(__APPLE__)
#include <dlfcn.h>
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

// The CGRect that SELECTOR returns from OBJECT. On x86_64 a CGRect is returned through
// objc_msgSend_stret; on arm64 objc_msgSend returns it, and the _stret form does not exist.
static CGRect rect_of(id object, const char *selector) {
#if defined(__x86_64__)
  CGRect r;
  reinterpret_cast<void (*)(CGRect *, id, SEL)>(objc_msgSend_stret)(&r, object,
                                                                     sel_registerName(selector));
  return r;
#else
  return reinterpret_cast<CGRect (*)(id, SEL)>(objc_msgSend)(object, sel_registerName(selector));
#endif
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
// when it is larger (window-placement.h, #485). Windows and macOS; on Linux the window
// manager places it.
//
// With REPORT, it also prints one line there: the work area, the DPI, what the frame adds, the
// placement computed, and the window's rectangle as the system reports it after placing it --
// for --report-placement, which is how a test sees the real calls (review of train 20). On
// macOS the rectangles are in points, measured upwards from the bottom of the main screen, so
// each is printed as left, bottom, right, top. A step that fails is reported as
// "placement-failed STEP" and nothing is moved.
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
#elif defined(__APPLE__)
  // webview_set_size has set the frame, title bar included, to WIDTH x HEIGHT points and
  // centred it with [NSWindow center], which does not shrink a window taller than the screen.
  // So the window gets the same arithmetic as on Windows, in points: the visible frame (the
  // screen less the menu bar and the Dock) is the work area, the content view's size is the
  // client size at 96 "dpi", which leaves it unscaled, and the frame adds the title bar. Cocoa
  // measures y upwards from the bottom of the main screen; centring is the same either way.
  (void)width;
  (void)height;
  auto failed = [report](const char *step) {
    if (report != nullptr) std::fprintf(report, "placement-failed %s\n", step);
    return false;
  };
  id window = static_cast<id>(webview_get_window(w));
  if (window == nullptr) return failed("webview_get_window");
  id screen = reinterpret_cast<id (*)(id, SEL)>(objc_msgSend)(window, sel_registerName("screen"));
  if (screen == nullptr)
    screen = reinterpret_cast<id (*)(id, SEL)>(objc_msgSend)(
        reinterpret_cast<id>(objc_getClass("NSScreen")), sel_registerName("mainScreen"));
  if (screen == nullptr) return failed("NSScreen");
  id view = reinterpret_cast<id (*)(id, SEL)>(objc_msgSend)(window,
                                                            sel_registerName("contentView"));
  if (view == nullptr) return failed("contentView");
  CGRect visible = rect_of(screen, "visibleFrame");
  CGRect outer = rect_of(window, "frame");
  CGRect client = rect_of(view, "frame");
  long work_left = std::lround(visible.origin.x);
  long work_top = std::lround(visible.origin.y);
  long work_right = std::lround(visible.origin.x + visible.size.width);
  long work_bottom = std::lround(visible.origin.y + visible.size.height);
  long client_width = std::lround(client.size.width);
  long client_height = std::lround(client.size.height);
  long frame_width = std::lround(outer.size.width) - client_width;
  long frame_height = std::lround(outer.size.height) - client_height;
  if (!placement_inputs_in_range(work_left, work_top, work_right, work_bottom, client_width,
                                 client_height, 96, frame_width, frame_height))
    return failed("out-of-range");
  window_placement p = place_in_work_area(work_left, work_top, work_right, work_bottom,
                                          client_width, client_height, 96, frame_width,
                                          frame_height);
  reinterpret_cast<void (*)(id, SEL, CGRect, BOOL)>(objc_msgSend)(
      window, sel_registerName("setFrame:display:"), CGRectMake(p.x, p.y, p.width, p.height),
      YES);
  if (report != nullptr) {
    CGRect placed = rect_of(window, "frame");
    long left = std::lround(placed.origin.x), bottom = std::lround(placed.origin.y);
    std::fprintf(report,
                 "work %ld %ld %ld %ld dpi 96 frame %ld %ld placement %ld %ld %ld %ld "
                 "window %ld %ld %ld %ld\n",
                 work_left, work_top, work_right, work_bottom, frame_width, frame_height, p.x,
                 p.y, p.width, p.height, left, bottom,
                 left + std::lround(placed.size.width), bottom + std::lround(placed.size.height));
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
// window-placement.h. Windows and macOS: on Linux the option is accepted and does nothing.
//
// The file is written when a move or resize made by dragging ends, when the window is
// maximised or restored, and when it is closed, not only at the end: hyperion/desktop:run-app
// ends this process with TerminateProcess (on macOS, SIGKILL) when the app closes the window
// itself, and a save left for the end would then never happen. On macOS the same events are
// the window's notifications, and a move is saved when it is made (see watch_placement there). A move made without dragging and without a change of
// size, such as Win+Shift+Arrow between two monitors at the same scaling, or a move made by
// another program, is saved at the next of those, or not at all if the process is ended first. Each write goes to PATH.tmp and is renamed over PATH, so a process ended
// part-way through leaves the previous line, not half of a new one.

#if defined(_WIN32)
// TEXT (UTF-8) as UTF-16, in *OUT. False when it does not convert. The buffer has room for the
// terminator MultiByteToWideChar writes, which is removed afterwards (review of #521).
static bool widen_utf8(const char *text, std::wstring *out) {
  int len = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, nullptr, 0);
  if (len <= 0) return false;
  std::wstring wide(static_cast<size_t>(len), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, &wide[0], len) != len)
    return false;
  wide.resize(static_cast<size_t>(len - 1));
  *out = wide;
  return true;
}
#endif

// The longest placement file read. A placement line is about 60 bytes.
const size_t kMaxPlacementFile = 256;

// The file at PATH (UTF-8), up to one byte more than kMaxPlacementFile so that a longer file
// can be told from one that fits, or "" if it cannot be read.
static std::string read_small_file(const char *path) {
  std::string out;
#if defined(_WIN32)
  std::wstring wide;
  if (!widen_utf8(path, &wide)) return out;
  std::FILE *f = _wfopen(wide.c_str(), L"rb");
#else
  std::FILE *f = std::fopen(path, "rb");
#endif
  if (f == nullptr) return out;
  char buf[kMaxPlacementFile + 1];
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
  // Validation covers the whole file, so a valid line followed by anything else is refused
  // rather than read as its first 256 bytes (review of #521).
  if (text.size() > kMaxPlacementFile) {
    *reason = "too-long";
    return false;
  }
  if (text.find('\0') != std::string::npos || !parse_saved_placement(text.c_str(), out)) {
    *reason = "malformed";
    return false;
  }
  return true;
}

#if defined(_WIN32) || defined(__APPLE__)
static std::string g_placement_path_utf8;
// A save that fails is reported on stderr once per run, so an app that asked for the placement
// to be kept learns that it is not, without a line for every move (review of #521).
static bool g_save_failure_reported = false;
// How many times the file has been written in this run. --exercise-placement prints it, so the
// test can tell a move saved once, at the end of the move loop, from one saved on every WM_SIZE
// inside it (review of #521). On macOS, at the end of a live resize rather than on every resize.
static int g_save_count = 0;
// True from the start of a move or resize made by dragging to its end: WM_ENTERSIZEMOVE to
// WM_EXITSIZEMOVE on Windows, NSWindowWillStartLiveResize to NSWindowDidEndLiveResize on macOS.
static bool g_in_size_move = false;

static bool save_failed(const char *step) {
  if (!g_save_failure_reported) {
    g_save_failure_reported = true;
    std::fprintf(stderr, "hyperion-view: could not save the window placement to %s (%s)\n",
                 g_placement_path_utf8.c_str(), step);
    std::fflush(stderr);
  }
  return false;
}

// Print STEP and the placement file's line, without its newline.
static void print_placement_file(const char *step) {
  std::string text = read_small_file(g_placement_path_utf8.c_str());
  while (!text.empty() && (text.back() == '\n' || text.back() == '\r')) text.pop_back();
  std::printf("%s %s\n", step, text.c_str());
}
#endif

#if defined(_WIN32)
static std::wstring g_placement_path;
// The window's rectangle when it was last neither maximised nor minimised: what is saved while
// it is maximised, so that restoring it un-maximises to the right place.
static RECT g_normal_rect;
static bool g_have_normal_rect = false;
static WNDPROC g_previous_window_proc = nullptr;

static void set_placement_path(const char *path) {
  g_placement_path_utf8 = path;
  if (!widen_utf8(path, &g_placement_path)) g_placement_path.clear();
}

// Write where HWND is to the placement file. False when there is no file, the window is
// minimised, or the write failed.
static bool save_placement(HWND hwnd) {
  if (g_placement_path_utf8.empty() || IsIconic(hwnd)) return false;
  if (g_placement_path.empty()) return save_failed("the path is not valid UTF-8");
  bool maximized = IsZoomed(hwnd) != 0;
  if (!maximized) {
    RECT r;
    if (!GetWindowRect(hwnd, &r)) return save_failed("GetWindowRect");
    g_normal_rect = r;
    g_have_normal_rect = true;
  }
  if (!g_have_normal_rect) return false;
  saved_placement p = {g_normal_rect.left, g_normal_rect.top, g_normal_rect.right,
                       g_normal_rect.bottom, maximized};
  char line[128];
  int n = format_saved_placement(p, line, sizeof line);
  if (n <= 0 || n >= static_cast<int>(sizeof line)) return save_failed("format");
  std::wstring tmp = g_placement_path + L".tmp";
  std::FILE *f = _wfopen(tmp.c_str(), L"wb");
  if (f == nullptr) return save_failed("opening the temporary file");
  bool ok = std::fwrite(line, 1, static_cast<size_t>(n), f) == static_cast<size_t>(n);
  ok = (std::fclose(f) == 0) && ok;
  if (!ok) {
    _wremove(tmp.c_str());
    return save_failed("writing the temporary file");
  }
  if (MoveFileExW(tmp.c_str(), g_placement_path.c_str(), MOVEFILE_REPLACE_EXISTING) == 0) {
    _wremove(tmp.c_str());
    return save_failed("replacing the file");
  }
  g_save_count++;
  return true;
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
  // Not from a minimised window, whose rectangle is about -32000: a process started minimised
  // and then maximised from the taskbar would save that, and open centred next time (review of
  // #521).
  if (!g_have_normal_rect && !IsZoomed(hwnd) && !IsIconic(hwnd) &&
      GetWindowRect(hwnd, &g_normal_rect))
    g_have_normal_rect = true;
  g_previous_window_proc = reinterpret_cast<WNDPROC>(SetWindowLongPtrW(
      hwnd, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(placement_window_proc)));
}

// The invisible resize borders of HWND on each side: GetWindowRect includes them, and the
// visible frame DWM reports (DWMWA_EXTENDED_FRAME_BOUNDS) does not. All zero when DWM cannot say,
// which leaves the fit rule as strict as it was. dwmapi.dll is loaded when this runs, so that
// neither build has to link another library.
static RECT invisible_borders(HWND hwnd) {
  RECT none = {0, 0, 0, 0};
  typedef HRESULT(WINAPI * get_attribute_fn)(HWND, DWORD, PVOID, DWORD);
  HMODULE dwm = LoadLibraryW(L"dwmapi.dll");
  if (dwm == nullptr) return none;
  get_attribute_fn get = reinterpret_cast<get_attribute_fn>(
      reinterpret_cast<void *>(GetProcAddress(dwm, "DwmGetWindowAttribute")));
  RECT outer, frame;
  const DWORD kExtendedFrameBounds = 9;  // DWMWA_EXTENDED_FRAME_BOUNDS, from dwmapi.h
  if (get == nullptr || !GetWindowRect(hwnd, &outer) ||
      FAILED(get(hwnd, kExtendedFrameBounds, &frame, sizeof frame)))
    return none;
  RECT b = {frame.left - outer.left, frame.top - outer.top, outer.right - frame.right,
            outer.bottom - frame.bottom};
  if (b.left < 0 || b.top < 0 || b.right < 0 || b.bottom < 0 || b.left > kMaxInvisibleBorder ||
      b.top > kMaxInvisibleBorder || b.right > kMaxInvisibleBorder ||
      b.bottom > kMaxInvisibleBorder)
    return none;
  return b;
}

// The DPI of MONITOR, or 0 when Windows cannot say. shcore.dll is loaded when this runs, as
// dwmapi.dll is above, so that neither build has to link another library.
static long monitor_dpi(HMONITOR monitor) {
  typedef HRESULT(WINAPI * get_dpi_fn)(HMONITOR, int, UINT *, UINT *);
  HMODULE shcore = LoadLibraryW(L"shcore.dll");
  if (shcore == nullptr) return 0;
  get_dpi_fn get = reinterpret_cast<get_dpi_fn>(
      reinterpret_cast<void *>(GetProcAddress(shcore, "GetDpiForMonitor")));
  UINT x = 0, y = 0;
  const int kEffectiveDpi = 0;  // MDT_EFFECTIVE_DPI, from shellscalingapi.h
  if (get == nullptr || FAILED(get(monitor, kEffectiveDpi, &x, &y))) return 0;
  return static_cast<long>(x);
}

// The width of a resizable window's frame at DPI, horizontally (left and right) or vertically
// (top and bottom): the sizing frame plus the padded border, as Windows lays them out.
static long frame_metric(long dpi, bool horizontal) {
  UINT d = static_cast<UINT>(dpi);
  return GetSystemMetricsForDpi(horizontal ? SM_CXSIZEFRAME : SM_CYSIZEFRAME, d) +
         GetSystemMetricsForDpi(SM_CXPADDEDBORDER, d);
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
  // The borders are measured on the window as it is now, on the monitor it was created on.
  // When the saved rectangle is on a monitor with other scaling, they are converted to that
  // monitor's frame size, so a window snapped on a 150% monitor and started from a 100% one
  // is allowed the 11 pixels it has there, not the 7 it has here (review of #521).
  RECT border = invisible_borders(hwnd);
  long from_dpi = static_cast<long>(GetDpiForWindow(hwnd));
  long to_dpi = monitor_dpi(monitor);
  if (from_dpi > 0 && to_dpi > 0 && from_dpi != to_dpi) {
    long h_from = frame_metric(from_dpi, true), h_to = frame_metric(to_dpi, true);
    long v_from = frame_metric(from_dpi, false), v_to = frame_metric(to_dpi, false);
    border.left = border_for_frame(border.left, h_from, h_to);
    border.right = border_for_frame(border.right, h_from, h_to);
    border.top = border_for_frame(border.top, v_from, v_to);
    border.bottom = border_for_frame(border.bottom, v_from, v_to);
  }
  if (!saved_placement_fits(p, info.rcWork.left, info.rcWork.top, info.rcWork.right,
                            info.rcWork.bottom, border.left, border.top, border.right,
                            border.bottom))
    return ignored("does-not-fit");
  if (!SetWindowPos(hwnd, nullptr, p.left, p.top, p.right - p.left, p.bottom - p.top,
                    SWP_NOZORDER | SWP_NOACTIVATE))
    return ignored("SetWindowPos");
  // When the saved rectangle is on a monitor whose scaling differs from the one the window was
  // created on, Windows sends WM_DPICHANGED during that call. webview.h's handler then scales
  // the window's size by the ratio of the two DPIs and keeps its position, so the window would
  // open larger or smaller than it was saved, and be saved that way. The second call is made on
  // the monitor the window is now on, so it causes no further DPI change and the saved size
  // stands (review of #521). Not measured: CI has one monitor.
  RECT first;
  if (GetWindowRect(hwnd, &first) &&
      (first.left != r.left || first.top != r.top || first.right != r.right ||
       first.bottom != r.bottom) &&
      !SetWindowPos(hwnd, nullptr, p.left, p.top, p.right - p.left, p.bottom - p.top,
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

// --exercise-placement: what a launch does with a placement file, on the window W, with the
// window procedure that saves it, driven through a move, a maximise, a restore, a minimise and a
// close, printing the file after each. For the CI-only test: until this mode, the saves made
// while the window is open and the maximise at start had never run (review of #521). The
// window may be shown while this runs, because a maximised window is shown.
static int exercise_placement(webview_t w, const char *path) {
  HWND hwnd = static_cast<HWND>(webview_get_window(w));
  if (hwnd == nullptr) {
    std::printf("placement-failed webview_get_window\n");
    return 1;
  }
  // The launch path: restore, maximising if the file says so, and watch.
  if (!restore_placement(w, path, stdout, true)) place_window(w, 800, 600);
  watch_placement(w, path);
  std::printf("start-zoomed %d\n", IsZoomed(hwnd) ? 1 : 0);
  if (IsZoomed(hwnd)) {
    std::fflush(stdout);
    return 0;
  }
  // A move and resize made with the move loop, as a drag makes it.
  RECT r;
  if (!GetWindowRect(hwnd, &r)) {
    std::printf("placement-failed GetWindowRect\n");
    return 1;
  }
  // Two size changes inside the loop, as a drag makes many. Each sends WM_SIZE, which must not
  // save; the end of the loop saves once. "move-saves" is how many writes the move made.
  int saves_before_move = g_save_count;
  SendMessageW(hwnd, WM_ENTERSIZEMOVE, 0, 0);
  SetWindowPos(hwnd, nullptr, r.left + 20, r.top + 15, (r.right - r.left) - 10,
               (r.bottom - r.top) - 5, SWP_NOZORDER | SWP_NOACTIVATE);
  SetWindowPos(hwnd, nullptr, r.left + 40, r.top + 30, (r.right - r.left) - 20,
               (r.bottom - r.top) - 10, SWP_NOZORDER | SWP_NOACTIVATE);
  SendMessageW(hwnd, WM_EXITSIZEMOVE, 0, 0);
  std::printf("move-saves %d\n", g_save_count - saves_before_move);
  RECT moved;
  GetWindowRect(hwnd, &moved);
  std::printf("moved %ld %ld %ld %ld\n", static_cast<long>(moved.left),
              static_cast<long>(moved.top), static_cast<long>(moved.right),
              static_cast<long>(moved.bottom));
  print_placement_file("after-move");
  ShowWindow(hwnd, SW_MAXIMIZE);
  print_placement_file("after-maximize");
  ShowWindow(hwnd, SW_RESTORE);
  print_placement_file("after-restore");
  ShowWindow(hwnd, SW_MINIMIZE);
  // webview.h destroys the window on WM_CLOSE, so W is not used after this.
  SendMessageW(hwnd, WM_CLOSE, 0, 0);
  print_placement_file("after-minimize-and-close");
  std::fflush(stdout);
  return 0;
}
#endif

#if defined(__APPLE__)
// --- the last placement on macOS (#485) ------------------------------------------------
//
// The saved frame is the window's frame in points, in Cocoa's global coordinates, and it is put
// back with restore_into_screens (window-placement.h): on the screen whose visible frame it
// overlaps most, shrunk and moved into that visible frame. NSWindow's own frame autosave is not
// used: it keeps the frame in the user defaults of the running executable, which every
// Hyperion desktop app shares, it does not shrink a window to the visible frame, and it does not
// keep the zoomed state.

// NSWindowStyleMaskFullScreen, spelled out for the reason given for kCmd above.
static const unsigned long kFullScreenMask = 1UL << 14;

// The window's frame when it was last saved while neither zoomed, miniaturised nor in full
// screen: what is saved while it is zoomed, so that unzooming after a restore goes back there.
static CGRect g_normal_frame;
static bool g_have_normal_frame = false;

static bool msg_bool(id object, const char *selector) {
  return reinterpret_cast<BOOL (*)(id, SEL)>(objc_msgSend)(object, sel_registerName(selector));
}

static id msg_id(id object, const char *selector) {
  return reinterpret_cast<id (*)(id, SEL)>(objc_msgSend)(object, sel_registerName(selector));
}

static void set_frame(id window, CGRect frame) {
  reinterpret_cast<void (*)(id, SEL, CGRect, BOOL)>(objc_msgSend)(
      window, sel_registerName("setFrame:display:"), frame, YES);
}

// A miniaturised window's frame is where it was before, but a full-screen window's is the whole
// screen, and saving either would be saving a state the user did not arrange.
static bool frame_saveable(id window) {
  unsigned long mask = reinterpret_cast<unsigned long (*)(id, SEL)>(objc_msgSend)(
      window, sel_registerName("styleMask"));
  return !msg_bool(window, "isMiniaturized") && (mask & kFullScreenMask) == 0;
}

static saved_placement saved_from_frame(CGRect r, bool zoomed) {
  long left = std::lround(r.origin.x), bottom = std::lround(r.origin.y);
  return {left, bottom, left + std::lround(r.size.width), bottom + std::lround(r.size.height),
          zoomed};
}

static void set_placement_path(const char *path) { g_placement_path_utf8 = path; }

// Write where WINDOW is to the placement file. False when there is no file, the window is
// miniaturised or in full screen, or the write failed. The line goes to PATH.tmp, which is
// renamed over PATH.
static bool save_placement(id window) {
  if (g_placement_path_utf8.empty() || !frame_saveable(window)) return false;
  bool zoomed = msg_bool(window, "isZoomed");
  // A window that opens filling the visible frame, as place_window makes one larger than the
  // screen, counts as zoomed to AppKit without having been zoomed. Until a frame has been
  // recorded, the current one is the window's normal frame, and it is saved as not zoomed.
  if (!zoomed || !g_have_normal_frame) {
    g_normal_frame = rect_of(window, "frame");
    g_have_normal_frame = true;
    zoomed = false;
  }
  char line[128];
  int n = format_saved_placement(saved_from_frame(g_normal_frame, zoomed), line, sizeof line);
  if (n <= 0 || n >= static_cast<int>(sizeof line)) return save_failed("format");
  std::string tmp = g_placement_path_utf8 + ".tmp";
  std::FILE *f = std::fopen(tmp.c_str(), "wb");
  if (f == nullptr) return save_failed("opening the temporary file");
  bool ok = std::fwrite(line, 1, static_cast<size_t>(n), f) == static_cast<size_t>(n);
  ok = (std::fclose(f) == 0) && ok;
  if (!ok) {
    std::remove(tmp.c_str());
    return save_failed("writing the temporary file");
  }
  if (std::rename(tmp.c_str(), g_placement_path_utf8.c_str()) != 0) {
    std::remove(tmp.c_str());
    return save_failed("replacing the file");
  }
  g_save_count++;
  return true;
}

// The observer's methods: each notification's object is the window.
static void on_moved_or_resized(id, SEL, id note) {
  if (!g_in_size_move) save_placement(msg_id(note, "object"));
}
static void on_live_resize_started(id, SEL, id) { g_in_size_move = true; }
static void on_live_resize_ended(id, SEL, id note) {
  g_in_size_move = false;
  save_placement(msg_id(note, "object"));
}
static void on_will_close(id, SEL, id note) { save_placement(msg_id(note, "object")); }

// The notification called NAME. AppKit exports each name as a constant of that name, whose value
// has so far always been the same string; the constant is read when it can be.
static id notification_name(const char *name) {
  void *symbol = dlsym(RTLD_DEFAULT, name);
  if (symbol != nullptr && *static_cast<id *>(symbol) != nullptr) return *static_cast<id *>(symbol);
  return ns_string(name);
}

// Keep PATH up to date while the window of W is open. An observer class made at run time, as
// webview.h makes its delegates, is told when the window moves, starts and ends a live resize,
// is resized (which covers zoom: and unzooming), and closes. A resize made by dragging is saved
// once, when it ends; so is a move made while resizing from the left or bottom edge. A move made
// by dragging the title bar is saved as macOS reports it, which may be more than once per drag.
static void watch_placement(webview_t w, const char *path) {
  id window = static_cast<id>(webview_get_window(w));
  if (window == nullptr) return;
  set_placement_path(path);
  if (!g_have_normal_frame && !msg_bool(window, "isZoomed") && frame_saveable(window)) {
    g_normal_frame = rect_of(window, "frame");
    g_have_normal_frame = true;
  }
  Class cls = objc_getClass("HyperionPlacementObserver");
  if (cls == nullptr) {
    cls = objc_allocateClassPair(objc_getClass("NSObject"), "HyperionPlacementObserver", 0);
    class_addMethod(cls, sel_registerName("movedOrResized:"),
                    reinterpret_cast<IMP>(on_moved_or_resized), "v@:@");
    class_addMethod(cls, sel_registerName("liveResizeStarted:"),
                    reinterpret_cast<IMP>(on_live_resize_started), "v@:@");
    class_addMethod(cls, sel_registerName("liveResizeEnded:"),
                    reinterpret_cast<IMP>(on_live_resize_ended), "v@:@");
    class_addMethod(cls, sel_registerName("willClose:"), reinterpret_cast<IMP>(on_will_close),
                    "v@:@");
    objc_registerClassPair(cls);
  }
  id observer = msg_id(msg_id(reinterpret_cast<id>(cls), "alloc"), "init");
  id center = msg_id(reinterpret_cast<id>(objc_getClass("NSNotificationCenter")), "defaultCenter");
  auto observe = [center, observer, window](const char *selector, const char *name) {
    reinterpret_cast<void (*)(id, SEL, id, SEL, id, id)>(objc_msgSend)(
        center, sel_registerName("addObserver:selector:name:object:"), observer,
        sel_registerName(selector), notification_name(name), window);
  };
  observe("movedOrResized:", "NSWindowDidMoveNotification");
  observe("movedOrResized:", "NSWindowDidResizeNotification");
  observe("liveResizeStarted:", "NSWindowWillStartLiveResizeNotification");
  observe("liveResizeEnded:", "NSWindowDidEndLiveResizeNotification");
  observe("willClose:", "NSWindowWillCloseNotification");
}

// Put the window of W where the file at PATH says, clamped into the visible frame of the screen
// that frame overlaps most. False when it was not used, and the caller places the window
// instead. With REPORT, one line is printed there: "restored L B R T ZOOMED window L B R T", or
// "restore-ignored REASON". ZOOM false leaves a saved zoomed window unzoomed.
static bool restore_placement(webview_t w, const char *path, std::FILE *report, bool zoom) {
  auto ignored = [report](const char *why) {
    if (report != nullptr) std::fprintf(report, "restore-ignored %s\n", why);
    return false;
  };
  id window = static_cast<id>(webview_get_window(w));
  if (window == nullptr) return ignored("webview_get_window");
  saved_placement p;
  const char *reason = nullptr;
  if (!load_saved_placement(path, &p, &reason)) return ignored(reason);
  id screens = msg_id(reinterpret_cast<id>(objc_getClass("NSScreen")), "screens");
  unsigned long count = screens == nullptr
                            ? 0
                            : reinterpret_cast<unsigned long (*)(id, SEL)>(objc_msgSend)(
                                  screens, sel_registerName("count"));
  std::vector<span_rect> areas;
  for (unsigned long i = 0; i < count && areas.size() < static_cast<size_t>(kMaxScreens); i++) {
    id screen = reinterpret_cast<id (*)(id, SEL, unsigned long)>(objc_msgSend)(
        screens, sel_registerName("objectAtIndex:"), i);
    CGRect v = rect_of(screen, "visibleFrame");
    span_rect a = {std::lround(v.origin.x), std::lround(v.origin.y),
                   std::lround(v.origin.x + v.size.width), std::lround(v.origin.y + v.size.height)};
    // A screen past the range the arithmetic is defined for is left out, as no display is there.
    if (a.x0 < -kMaxCoordinate || a.y0 < -kMaxCoordinate || a.x1 > kMaxCoordinate ||
        a.y1 > kMaxCoordinate)
      continue;
    areas.push_back(a);
  }
  clamped_placement c = restore_into_screens(p, areas.data(), static_cast<int>(areas.size()));
  if (c.ignored != nullptr) return ignored(c.ignored);
  CGRect frame = CGRectMake(c.x0, c.y0, c.x1 - c.x0, c.y1 - c.y0);
  set_frame(window, frame);
  g_normal_frame = frame;
  g_have_normal_frame = true;
  if (p.maximized && zoom && !msg_bool(window, "isZoomed"))
    reinterpret_cast<void (*)(id, SEL, id)>(objc_msgSend)(window, sel_registerName("zoom:"),
                                                          nullptr);
  if (report != nullptr) {
    CGRect placed = rect_of(window, "frame");
    long left = std::lround(placed.origin.x), bottom = std::lround(placed.origin.y);
    std::fprintf(report, "restored %ld %ld %ld %ld %d window %ld %ld %ld %ld\n", c.x0, c.y0,
                 c.x1, c.y1, p.maximized ? 1 : 0, left, bottom,
                 left + std::lround(placed.size.width), bottom + std::lround(placed.size.height));
  }
  return true;
}

// --exercise-placement on macOS: what a launch does with a placement file, then a resize made
// as a drag makes it (the live-resize notifications are posted here, around two frame changes),
// a zoom, an unzoom and a close, printing the file after each. For the GitHub-only test.
static int exercise_placement(webview_t w, const char *path) {
  id window = static_cast<id>(webview_get_window(w));
  if (window == nullptr) {
    std::printf("placement-failed webview_get_window\n");
    return 1;
  }
  if (!restore_placement(w, path, stdout, true)) place_window(w, 800, 600);
  watch_placement(w, path);
  std::printf("start-zoomed %d\n", msg_bool(window, "isZoomed") ? 1 : 0);
  if (msg_bool(window, "isZoomed")) {
    std::fflush(stdout);
    return 0;
  }
  CGRect r = rect_of(window, "frame");
  id center = msg_id(reinterpret_cast<id>(objc_getClass("NSNotificationCenter")), "defaultCenter");
  auto post = [center, window](const char *name) {
    reinterpret_cast<void (*)(id, SEL, id, id)>(objc_msgSend)(
        center, sel_registerName("postNotificationName:object:"), notification_name(name),
        window);
  };
  int saves_before_move = g_save_count;
  post("NSWindowWillStartLiveResizeNotification");
  set_frame(window, CGRectMake(r.origin.x + 20, r.origin.y + 15, r.size.width - 10,
                               r.size.height - 5));
  set_frame(window, CGRectMake(r.origin.x + 40, r.origin.y + 30, r.size.width - 20,
                               r.size.height - 10));
  post("NSWindowDidEndLiveResizeNotification");
  std::printf("move-saves %d\n", g_save_count - saves_before_move);
  CGRect moved = rect_of(window, "frame");
  long left = std::lround(moved.origin.x), bottom = std::lround(moved.origin.y);
  std::printf("moved %ld %ld %ld %ld\n", left, bottom, left + std::lround(moved.size.width),
              bottom + std::lround(moved.size.height));
  print_placement_file("after-move");
  reinterpret_cast<void (*)(id, SEL, id)>(objc_msgSend)(window, sel_registerName("zoom:"),
                                                        nullptr);
  std::printf("zoomed %d\n", msg_bool(window, "isZoomed") ? 1 : 0);
  print_placement_file("after-maximize");
  reinterpret_cast<void (*)(id, SEL, id)>(objc_msgSend)(window, sel_registerName("zoom:"),
                                                        nullptr);
  print_placement_file("after-restore");
  // webview.h's delegate stops the application when its window closes, so W is not used after
  // this.
  reinterpret_cast<void (*)(id, SEL)>(objc_msgSend)(window, sel_registerName("close"));
  print_placement_file("after-close");
  std::fflush(stdout);
  return 0;
}
#endif

// --- native file dialogs (#986) --------------------------------------------
//
// With --dialogs, the app's page gets window.hyperionDialog(request), which shows a native open,
// save-as or folder dialog owned by this window and resolves to {path}, {paths}, {cancelled} or
// {error}. The page then sends the path to the app's own route.
//
// THE GATE, so a page on another origin cannot ask for a path from the user's machine or receive
// one:
// - The binding exists only in the top-level frame while it shows the app's own origin. The
//   script below runs at the start of every document, deletes the raw binding webview.h defines
//   everywhere, and defines hyperionDialog only when location.origin is the origin of the URL
//   this view was started with. Any other origin, and any iframe, has neither. A URL with a user
//   name or with its scheme's default port written out (http://h:80/) never matches
//   location.origin, so the page there gets no function.
// - The per-launch TOKEN is held only in that function's closure, and the native side refuses a
//   call without it (PARSE-DIALOG-REQUEST), so a script that reaches window.external.invoke
//   directly cannot open a dialog.
// - A call made outside a user action is refused, through navigator.userActivation, whose getter
//   is taken at document start so a page cannot replace it. WebView2 (Windows) and WebKit on macOS
//   13.3 and later have it; where a WebKitGTK does not, only the origin rule and "busy" apply.
// - THE REPLY GOES ONLY TO THE APP'S ORIGIN. webview.h's own reply (webview_return) runs
//   window._rpc[seq].resolve in whatever document is on top when it is sent, so a page on another
//   origin, navigated to while the dialog was open, could define window._rpc and receive the path.
//   So the page's call carries an id, and every answer is sent by DIALOG_REPLY: a script that does
//   nothing unless location.origin is still the app's, and then hands the answer to the function
//   the guard defined for that id. webview_return is never called for this binding.
// - One dialog at a time: a call while one is open is answered {"error": "busy"}.
//
// Every answer is sent with webview_eval, which on Windows calls ExecuteScript directly, and the
// dialog itself is started by a message posted to the window. Nothing here uses webview.h's
// dispatch, which posts a thread message: a modal loop, the dialog's own or the one Windows runs
// while the window is moved or resized, discards thread messages, so a job or an answer sent that
// way can be lost and leave "busy" set for good.
//
// HYPERION_VIEW_FAKE_DIALOG=1 is for the CI-only window tests. It skips the user-action check and
// answers {"path":"fake-path"} three seconds after a call, from a window timer, without showing a
// dialog, so a test can see "busy" and where the answer goes. It says so on stderr.
//
// Only Windows shows a dialog in this step. macOS and Linux answer {"error": "unavailable"} after
// the same checks, and their dialogs follow in their own lanes' changes.

static std::string g_dialog_token;
static std::string g_app_origin;
static bool g_fake_dialog = false;
#if defined(_WIN32)
static bool g_dialog_busy = false;  // only Windows shows a dialog in this change
#endif

// The origin of URL, as location.origin writes it: the scheme, "://", and the host with its port,
// in lower case. "" when URL has no scheme.
static std::string url_origin(const char *url) {
  std::string u(url);
  size_t scheme_end = u.find("://");
  if (scheme_end == std::string::npos) return "";
  size_t host_end = u.find_first_of("/?#", scheme_end + 3);
  std::string origin = u.substr(0, host_end == std::string::npos ? u.size() : host_end);
  for (char &c : origin)
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
  return origin;
}

// 32 hexadecimal characters from the OS's random source, or "" when it cannot give them.
static std::string random_token() {
  unsigned char bytes[16];
#if defined(_WIN32)
  if (BCryptGenRandom(nullptr, bytes, sizeof bytes, BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0)
    return "";
#else
  std::FILE *f = std::fopen("/dev/urandom", "rb");
  if (f == nullptr) return "";
  size_t got = std::fread(bytes, 1, sizeof bytes, f);
  std::fclose(f);
  if (got != sizeof bytes) return "";
#endif
  std::string out;
  char buf[3];
  for (unsigned char b : bytes) {
    std::snprintf(buf, sizeof buf, "%02x", b);
    out += buf;
  }
  return out;
}

// The script that defines window.hyperionDialog, run at the start of every document.
static std::string dialog_guard_script() {
  return std::string(
             "(function(){var raw=window.__hyperion_dialog_raw;"
             "try{delete window.__hyperion_dialog_raw;}catch(e){window.__hyperion_dialog_raw=undefined;}"
             "if(typeof raw!=='function'||window.top!==window||location.origin!==") +
         dialog_json_quote(g_app_origin) +
         ")return;"
         "var ua=null,isActive=null;"
         "try{ua=navigator.userActivation;"
         "var d=Object.getOwnPropertyDescriptor(Object.getPrototypeOf(ua),'isActive');"
         "isActive=d&&d.get;}catch(e){}"
         "var token=" +
         dialog_json_quote(g_dialog_token) +
         ",checkActivation=" + (g_fake_dialog ? "false" : "true") +
         ",next=1,pending={};"
         "Object.defineProperty(window,'__hyperion_dialog_reply',{value:function(id,r){"
         "var p=pending[id];if(p){delete pending[id];p(r);}},writable:false,configurable:false});"
         "Object.defineProperty(window,'hyperionDialog',{value:function(request){"
         "if(checkActivation&&isActive&&!isActive.call(ua))return Promise.resolve({error:'no-user-action'});"
         "var id=next++;"
         "return new Promise(function(resolve){pending[id]=resolve;raw(token,id,request||{});});"
         "},writable:false,configurable:false});"
         "})();";
}

// Send RESULT, a JSON object, to the page's call ID, but only if the top-level document is still
// on the app's origin. ID is the digits PARSE-DIALOG-REQUEST checked.
static void dialog_reply(webview_t w, const std::string &id, const std::string &result) {
  std::string js = "(function(){if(location.origin!==" + dialog_json_quote(g_app_origin) +
                   ")return;var f=window.__hyperion_dialog_reply;"
                   "if(typeof f==='function')f(" + id + "," + result + ");})();";
  webview_eval(w, js.c_str());
}

#if defined(_WIN32)
static std::string narrow_utf8(const wchar_t *wide) {
  int len = WideCharToMultiByte(CP_UTF8, 0, wide, -1, nullptr, 0, nullptr, nullptr);
  if (len <= 0) return "";
  std::string out(static_cast<size_t>(len), '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide, -1, &out[0], len, nullptr, nullptr);
  out.resize(static_cast<size_t>(len - 1));
  return out;
}

// The file-system path of ITEM, or "" when it has none.
static std::string shell_item_path(IShellItem *item) {
  PWSTR path = nullptr;
  if (FAILED(item->GetDisplayName(SIGDN_FILESYSPATH, &path)) || path == nullptr) return "";
  std::string out = narrow_utf8(path);
  CoTaskMemFree(path);
  return out;
}

// One client GUID for each kind, so Windows remembers the last folder for open, open-many, save
// and folder separately, and starts in Documents the first time.
static const GUID kDialogGuidOpen = {0x3c6e5c1a, 0x9b2d, 0x4f61, {0x8a, 0x10, 0x5e, 0x9a, 0x71, 0x0c, 0x98, 0x61}};
static const GUID kDialogGuidOpenMany = {0x3c6e5c1a, 0x9b2d, 0x4f61, {0x8a, 0x10, 0x5e, 0x9a, 0x71, 0x0c, 0x98, 0x62}};
static const GUID kDialogGuidSave = {0x3c6e5c1a, 0x9b2d, 0x4f61, {0x8a, 0x10, 0x5e, 0x9a, 0x71, 0x0c, 0x98, 0x63}};
static const GUID kDialogGuidFolder = {0x3c6e5c1a, 0x9b2d, 0x4f61, {0x8a, 0x10, 0x5e, 0x9a, 0x71, 0x0c, 0x98, 0x64}};

// Show the dialog R asks for, owned by OWNER, on this thread, and return the JSON the page gets.
// Runs on the webview's UI thread, which webview.h has already made a COM single-threaded
// apartment, from the window procedure, not inside WebView2's message handler: a modal loop
// inside a WebView2 event handler is a reentrancy WebView2 documents as unsupported.
static std::string show_file_dialog(HWND owner, const dialog_request &r) {
  bool save = r.kind == "save";
  IFileDialog *dialog = nullptr;
  HRESULT hr = save ? CoCreateInstance(CLSID_FileSaveDialog, nullptr, CLSCTX_INPROC_SERVER,
                                       IID_IFileSaveDialog, reinterpret_cast<void **>(&dialog))
                    : CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER,
                                       IID_IFileOpenDialog, reinterpret_cast<void **>(&dialog));
  if (FAILED(hr) || dialog == nullptr) return "{\"error\":\"failed\"}";
  DWORD options = 0;
  dialog->GetOptions(&options);
  options |= FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST;
  if (r.kind == "open") options |= FOS_FILEMUSTEXIST;
  if (r.kind == "open-many") options |= FOS_FILEMUSTEXIST | FOS_ALLOWMULTISELECT;
  if (r.kind == "folder") options |= FOS_PICKFOLDERS;
  if (save) options |= FOS_OVERWRITEPROMPT;
  dialog->SetOptions(options);
  dialog->SetClientGuid(r.kind == "open"        ? kDialogGuidOpen
                        : r.kind == "open-many" ? kDialogGuidOpenMany
                        : save                  ? kDialogGuidSave
                                                : kDialogGuidFolder);
  std::wstring wide;
  if (!r.title.empty() && widen_utf8(r.title.c_str(), &wide)) dialog->SetTitle(wide.c_str());
  // The filter specs must outlive SetFileTypes, which copies them; kept here until it returns.
  std::vector<std::wstring> names, specs;
  for (const dialog_filter &f : r.filters) {
    std::string spec;
    for (size_t i = 0; i < f.patterns.size(); i++) spec += (i ? ";" : "") + f.patterns[i];
    std::wstring wname, wspec;
    widen_utf8(f.label.c_str(), &wname);
    widen_utf8(spec.c_str(), &wspec);
    names.push_back(wname);
    specs.push_back(wspec);
  }
  if (!names.empty()) {
    std::vector<COMDLG_FILTERSPEC> types;
    for (size_t i = 0; i < names.size(); i++) types.push_back({names[i].c_str(), specs[i].c_str()});
    dialog->SetFileTypes(static_cast<UINT>(types.size()), types.data());
  }
  if (!r.folder.empty() && widen_utf8(r.folder.c_str(), &wide)) {
    IShellItem *folder = nullptr;
    if (SUCCEEDED(SHCreateItemFromParsingName(wide.c_str(), nullptr, IID_IShellItem,
                                              reinterpret_cast<void **>(&folder)))) {
      dialog->SetFolder(folder);
      folder->Release();
    }
  }
  if (save && !r.name.empty() && widen_utf8(r.name.c_str(), &wide)) dialog->SetFileName(wide.c_str());
  hr = dialog->Show(owner);
  std::string result;
  if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    result = "{\"cancelled\":true}";
  } else if (FAILED(hr)) {
    result = "{\"error\":\"failed\"}";
  } else if (r.kind == "open-many") {
    IFileOpenDialog *open = nullptr;
    IShellItemArray *items = nullptr;
    DWORD count = 0;
    result = "{\"error\":\"failed\"}";
    if (SUCCEEDED(dialog->QueryInterface(IID_IFileOpenDialog, reinterpret_cast<void **>(&open)))) {
      if (SUCCEEDED(open->GetResults(&items)) && SUCCEEDED(items->GetCount(&count))) {
        result = "{\"paths\":[";
        bool first = true;  // the comma goes before every item written except the first
        for (DWORD i = 0; i < count; i++) {
          IShellItem *item = nullptr;
          if (SUCCEEDED(items->GetItemAt(i, &item))) {
            result += (first ? "" : ",") + dialog_json_quote(shell_item_path(item));
            first = false;
            item->Release();
          }
        }
        result += "]}";
      }
      if (items != nullptr) items->Release();
      open->Release();
    }
  } else {
    IShellItem *item = nullptr;
    if (SUCCEEDED(dialog->GetResult(&item))) {
      result = "{\"path\":" + dialog_json_quote(shell_item_path(item)) + "}";
      item->Release();
    } else {
      result = "{\"error\":\"failed\"}";
    }
  }
  dialog->Release();
  return result;
}

struct dialog_job {
  std::string id;
  dialog_request request;
};

static webview_t g_dialog_view = nullptr;
static UINT g_dialog_message = 0;  // registered in INSTALL_DIALOGS; carries a DIALOG_JOB
static WNDPROC g_dialog_previous_proc = nullptr;
static dialog_job *g_fake_job = nullptr;
static const UINT_PTR kFakeDialogTimer = 0x4859;

static void finish_dialog_job(dialog_job *job, const std::string &result) {
  g_dialog_busy = false;
  dialog_reply(g_dialog_view, job->id, result);
  delete job;
}

static LRESULT CALLBACK dialog_window_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  if (g_dialog_message != 0 && msg == g_dialog_message) {
    dialog_job *job = reinterpret_cast<dialog_job *>(lp);
    if (g_fake_dialog) {
      g_fake_job = job;
      SetTimer(hwnd, kFakeDialogTimer, 3000, nullptr);
    } else {
      finish_dialog_job(job, show_file_dialog(hwnd, job->request));
    }
    return 0;
  }
  if (msg == WM_TIMER && wp == kFakeDialogTimer) {
    KillTimer(hwnd, kFakeDialogTimer);
    if (g_fake_job != nullptr) {
      dialog_job *job = g_fake_job;
      g_fake_job = nullptr;
      finish_dialog_job(job, "{\"path\":\"fake-path\"}");
    }
    return 0;
  }
  return CallWindowProcW(g_dialog_previous_proc, hwnd, msg, wp, lp);
}
#endif

// The native end of the binding. Every call is checked first, on every OS: the token, then the
// call's id and the request (PARSE-DIALOG-REQUEST). A call that fails the token or the id gets no
// answer, since there is no id to send one to.
static void dialog_binding(const char *seq, const char *req, void *arg) {
  (void)seq;  // answered through DIALOG_REPLY, never webview_return; see the gate above
  webview_t w = static_cast<webview_t>(arg);
  dialog_request request;
  std::string why = parse_dialog_request(req, g_dialog_token, &request);
  if (!why.empty()) {
    if (!request.id.empty())
      dialog_reply(w, request.id, "{\"error\":" + dialog_json_quote(why) + "}");
    return;
  }
#if defined(_WIN32)
  if (g_dialog_busy) {
    dialog_reply(w, request.id, "{\"error\":\"busy\"}");
    return;
  }
  HWND hwnd = static_cast<HWND>(webview_get_window(w));
  dialog_job *job = new dialog_job{request.id, request};
  g_dialog_busy = true;
  if (!PostMessageW(hwnd, g_dialog_message, 0, reinterpret_cast<LPARAM>(job))) {
    delete job;
    g_dialog_busy = false;
    dialog_reply(w, request.id, "{\"error\":\"failed\"}");
  }
#else
  dialog_reply(w, request.id, "{\"error\":\"unavailable\"}");
#endif
}

// Make the launch's token and the app's origin from URL, before any window exists. False when no
// token can be made or URL has no origin; the view then refuses to start, so a running view
// started with --dialogs always has them, and RUN-APP's DIALOGS-AVAILABLE-P is not true of a
// window that has none.
static bool prepare_dialogs(const char *url) {
  g_dialog_token = random_token();
  g_app_origin = url_origin(url);
  const char *fake = std::getenv("HYPERION_VIEW_FAKE_DIALOG");
  g_fake_dialog = fake != nullptr && std::strcmp(fake, "1") == 0;
  if (g_fake_dialog)
    std::fprintf(stderr, "hyperion-view: HYPERION_VIEW_FAKE_DIALOG=1: no dialog is shown; calls get fake-path and need no user action\n");
  return !g_dialog_token.empty() && !g_app_origin.empty();
}

// Install the binding and its guard on W. After PREPARE_DIALOGS, before the first navigation.
static void install_dialogs(webview_t w) {
#if defined(_WIN32)
  g_dialog_view = w;
  g_dialog_message = RegisterWindowMessageW(L"hyperion-view-dialog-job");
  HWND hwnd = static_cast<HWND>(webview_get_window(w));
  g_dialog_previous_proc = reinterpret_cast<WNDPROC>(SetWindowLongPtrW(
      hwnd, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(dialog_window_proc)));
#endif
  webview_bind(w, "__hyperion_dialog_raw", dialog_binding, w);
  webview_init(w, dialog_guard_script().c_str());
}

// HYPERION_VIEW_NO_WINDOW=1 stops hyperion-view just before it would create a window, with exit
// code 3 and a line on stderr. The view tests set it for every run they make on a developer's
// machine, so a test that reaches webview_create by mistake fails there instead of opening a
// window on someone's screen; only the CI-only real-window tests clear it (#521). The modes that
// never create a window (--help, --placement, --saved-placement, --restore-placement, and every
// refusal) ignore it.
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
               "                     [--placement-file PATH] [--dialogs] [--exit-after SECONDS]\n"
               "\n"
               "  URL      the address to open      (default http://127.0.0.1:8080/)\n"
               "  TITLE    the window title         (default \"App\")\n"
               "  WIDTH    window width in pixels   (default 1200)\n"
               "  HEIGHT   window height in pixels  (default 800)\n"
               "  --icon   path to a window icon    (optional, may appear anywhere)\n"
               "  --placement-file PATH\n"
               "           Windows and macOS: open the window where it was last time, and keep\n"
               "           PATH up to date (optional, may appear anywhere). Windows uses it only\n"
               "           if it still fits a monitor; macOS moves it onto the screen it overlaps\n"
               "           most\n"
               "  --dialogs\n"
               "           give the page at URL's origin window.hyperionDialog, which shows a\n"
               "           native open, save-as or folder dialog owned by this window (#986).\n"
               "           Windows only so far; elsewhere it answers {\"error\":\"unavailable\"}\n"
               "  --exit-after SECONDS\n"
               "           close the window after SECONDS, for tests\n"
               "\n"
               "  --dialog-request TOKEN PARAMS\n"
               "           print what a dialog call's PARAMS parse to, or why it is refused, with\n"
               "           no window\n"
               "  --dialog-origin URL\n"
               "           print the origin --dialogs offers the dialog to, with no window\n"
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
               "               Windows and macOS: create the window, size and place it as a\n"
               "               launch does, print the work area, DPI, frame, placement and the\n"
               "               window's rectangle, then exit without running it. On Windows,\n"
               "               start it hidden; on macOS the window is shown. With\n"
               "               PLACEMENT-FILE, restore from it first and save to it after.\n"
               "  --saved-placement PATH WL WT WR WB [BL BT BR BB [FROM TO]]\n"
               "               print \"use L T R B MAXIMIZED\" if the placement saved at PATH would\n"
               "               be restored into the work area WL,WT-WR,WB, else \"ignore REASON\".\n"
               "               BL BT BR BB are the window's invisible borders (default 0, at most\n"
               "               100), by which the rectangle may pass the work area. FROM\n"
               "               and TO are the frame widths where the borders were measured\n"
               "               and on the rectangle's monitor; each border grows by TO-FROM\n"
               "  --restore-placement PATH SL SB SR ST [SL SB SR ST ...]\n"
               "               print \"use L B R T ZOOMED screen N\" for where macOS restores the\n"
               "               placement saved at PATH, given the visible frames of up to 16\n"
               "               screens, each as left, bottom, right, top; else \"ignore REASON\"\n"
               "  --exercise-placement PATH\n"
               "               Windows and macOS, for CI: open the window as a launch with\n"
               "               --placement-file PATH does, then move, maximise, restore and\n"
               "               close it (on Windows, minimise it first), printing the file after\n"
               "               each step\n"
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
  bool dialogs = false;
  long exit_after = 0;
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
#if defined(_WIN32) || defined(__APPLE__)
      if (file == nullptr || !restore_placement(rv, file, stdout, false))
        ok = place_window(rv, rw, rh, stdout);
      if (ok && file != nullptr) {
        set_placement_path(file);
#if defined(_WIN32)
        bool saved = save_placement(static_cast<HWND>(webview_get_window(rv)));
#else
        bool saved = save_placement(static_cast<id>(webview_get_window(rv)));
#endif
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
    } else if (std::strcmp(argv[i], "--exercise-placement") == 0) {
      if (i != 1 || argc != 3) {
        std::fprintf(stderr,
                     "hyperion-view: --exercise-placement takes a path and nothing else\n\n");
        print_usage(stderr);
        return 2;
      }
#if defined(_WIN32) || defined(__APPLE__)
      if (window_forbidden()) return 3;
      webview_t ev = webview_create(0, nullptr);
      if (ev == nullptr) {
        std::printf("placement-failed webview_create\n");
        std::fflush(stdout);
        return 1;
      }
      webview_set_size(ev, 800, 600, WEBVIEW_HINT_NONE);
      // The process ends here without webview_destroy: the last step closed the window.
      return exercise_placement(ev, argv[2]);
#else
      std::printf("placement-unsupported\n");
      return 1;
#endif
    } else if (std::strcmp(argv[i], "--restore-placement") == 0) {
      // macOS's restore decision on its own, with no window, so the tests check it on every OS.
      int count = argc - 3;
      bool numbers = i == 1 && count >= 4 && count % 4 == 0 && count / 4 <= kMaxScreens;
      span_rect screens[kMaxScreens];
      for (int k = 0; numbers && k < count; k++) {
        long v = 0;
        numbers = parse_long(argv[3 + k], &v) && v >= -kMaxCoordinate && v <= kMaxCoordinate;
        long *field[4] = {&screens[k / 4].x0, &screens[k / 4].y0, &screens[k / 4].x1,
                          &screens[k / 4].y1};
        if (numbers) *field[k % 4] = v;
      }
      if (!numbers) {
        std::fprintf(stderr,
                     "hyperion-view: --restore-placement takes a path and 1 to %d screens, each "
                     "4 integers within %ld of 0, and nothing else\n\n",
                     kMaxScreens, kMaxCoordinate);
        print_usage(stderr);
        return 2;
      }
      saved_placement p;
      const char *reason = nullptr;
      if (!load_saved_placement(argv[2], &p, &reason)) {
        std::printf("ignore %s\n", reason);
        return 0;
      }
      clamped_placement c = restore_into_screens(p, screens, count / 4);
      if (c.ignored != nullptr)
        std::printf("ignore %s\n", c.ignored);
      else
        std::printf("use %ld %ld %ld %ld %d screen %d\n", c.x0, c.y0, c.x1, c.y1,
                    p.maximized ? 1 : 0, c.screen);
      return 0;
    } else if (std::strcmp(argv[i], "--saved-placement") == 0) {
      // The restore decision on its own, with no window, so the tests check it on every OS.
      long work[10] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
      int count = argc - 3;
      bool numbers = i == 1 && (count == 4 || count == 8 || count == 10);
      for (int k = 0; numbers && k < count; k++) numbers = parse_long(argv[3 + k], &work[k]);
      for (int k = 4; numbers && k < 8; k++)
        numbers = work[k] >= 0 && work[k] <= kMaxInvisibleBorder;
      for (int k = 8; numbers && k < 10; k++)
        numbers = work[k] >= 0 && work[k] <= kMaxFrameMetric;
      if (!numbers) {
        std::fprintf(stderr,
                     "hyperion-view: --saved-placement takes a path and 4 integers, or 8 with "
                     "the last 4 from 0 to %ld, or 10 with the last 2 from 0 to %ld, and "
                     "nothing else\n\n",
                     kMaxInvisibleBorder, kMaxFrameMetric);
        print_usage(stderr);
        return 2;
      }
      if (count == 10) {
        // The borders were measured where the frame is FROM wide; the rectangle is on a
        // monitor where it is TO wide. Both directions use the same widths here.
        for (int k = 4; k < 8; k++) work[k] = border_for_frame(work[k], work[8], work[9]);
      }
      saved_placement p;
      const char *reason = nullptr;
      if (!load_saved_placement(argv[2], &p, &reason)) {
        std::printf("ignore %s\n", reason);
      } else if (!saved_placement_fits(p, work[0], work[1], work[2], work[3], work[4], work[5],
                                       work[6], work[7])) {
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
        if (!parse_long(argv[i + 1 + k], &v[k])) {
          std::fprintf(stderr, "hyperion-view: --placement: not an integer a long holds: %s\n\n",
                       argv[i + 1 + k]);
          print_usage(stderr);
          return 2;
        }
      }
      if (!placement_inputs_in_range(v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8])) {
        std::fprintf(stderr,
                     "hyperion-view: --placement: a value is out of range (coordinates within "
                     "%ld of 0, client size 1 to %ld, DPI 1 to %ld, frame 0 to %ld)\n\n",
                     kMaxCoordinate, kMaxClientSize, kMaxDpi, kMaxFrame);
        print_usage(stderr);
        return 2;
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
    } else if (std::strcmp(argv[i], "--dialogs") == 0) {
      dialogs = true;
    } else if (std::strcmp(argv[i], "--exit-after") == 0) {
      // For the CI-only window tests (#986): close the window after SECONDS, so a test that
      // starts the view and waits for it to exit does not wait forever.
      long seconds = 0;
      if (i + 1 >= argc || !parse_long(argv[i + 1], &seconds) || seconds < 1 || seconds > 3600) {
        std::fprintf(stderr, "hyperion-view: --exit-after needs SECONDS from 1 to 3600\n\n");
        print_usage(stderr);
        return 2;
      }
      exit_after = seconds;
      i++;
    } else if (std::strcmp(argv[i], "--dialog-request") == 0) {
      // The checks a page's dialog call passes before any dialog is shown, on their own, with no
      // window: for the tests, which run them on every OS (#986). TOKEN stands for the launch's
      // token; PARAMS is the JSON array the binding receives, [TOKEN, REQUEST].
      if (i != 1 || argc != 4) {
        std::fprintf(stderr, "hyperion-view: --dialog-request takes TOKEN and PARAMS and nothing else\n\n");
        print_usage(stderr);
        return 2;
      }
      dialog_request r;
      std::string why = parse_dialog_request(argv[3], argv[2], &r);
      if (!why.empty()) {
        std::printf("refuse %s\n", why.c_str());
        return 0;
      }
      std::printf("ok %s", r.kind.c_str());
      if (!r.title.empty()) std::printf(" title=%s", dialog_json_quote(r.title).c_str());
      if (!r.folder.empty()) std::printf(" folder=%s", dialog_json_quote(r.folder).c_str());
      if (!r.name.empty()) std::printf(" name=%s", dialog_json_quote(r.name).c_str());
      for (const dialog_filter &f : r.filters) {
        std::printf(" filter=%s:", dialog_json_quote(f.label).c_str());
        for (size_t k = 0; k < f.patterns.size(); k++)
          std::printf("%s%s", k ? ";" : "", f.patterns[k].c_str());
      }
      std::printf("\n");
      return 0;
    } else if (std::strcmp(argv[i], "--dialog-origin") == 0) {
      // The origin the binding is offered to for URL, with no window (#986).
      if (i != 1 || argc != 3) {
        std::fprintf(stderr, "hyperion-view: --dialog-origin takes URL and nothing else\n\n");
        print_usage(stderr);
        return 2;
      }
      std::printf("%s\n", url_origin(argv[2]).c_str());
      return 0;
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

  if (dialogs && !prepare_dialogs(url)) {
    std::fprintf(stderr, "hyperion-view: --dialogs: no random token, or no origin in %s\n", url);
    return 2;
  }
  if (window_forbidden()) return 3;
  webview_t w = webview_create(0, nullptr);
  webview_set_title(w, title);
  webview_set_size(w, width, height, WEBVIEW_HINT_NONE);
#if defined(_WIN32) || defined(__APPLE__)
  if (placement_file == nullptr || !restore_placement(w, placement_file, nullptr, true))
    place_window(w, width, height);
  if (placement_file != nullptr) watch_placement(w, placement_file);
#else
  (void)placement_file;
  place_window(w, width, height);
#endif
  set_window_icon(w, icon);
  // After webview_create (NSApp exists), before webview_run ([NSApp run]).
  install_main_menu(title);
  // Before the first navigation, so the guard runs at the start of the app's first page.
  if (dialogs) install_dialogs(w);
  if (exit_after > 0) {
    // webview_dispatch is the one webview.h call that is safe from another thread.
    std::thread([w, exit_after]() {
      std::this_thread::sleep_for(std::chrono::seconds(exit_after));
      webview_dispatch(w, [](webview_t view, void *) { webview_terminate(view); }, nullptr);
    }).detach();
  }
  webview_navigate(w, url);
  webview_run(w);
  webview_destroy(w);
  return 0;
}
