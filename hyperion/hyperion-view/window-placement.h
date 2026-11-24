// window-placement.h --- where hyperion-view puts its window on the screen (#485).
//
// webview.h sets only the window's size; on Windows the window then opens wherever
// CW_USEDEFAULT puts it, a cascade point that moves down and to the right with each new
// window. On a 2560x1600 display at 150% scaling the work area is 1528 physical pixels high,
// and a 1280x860 window is 1346 pixels high with its frame, so it fits only when the cascade
// point is in the top 182 pixels; often it is not, and the bottom of the window opens below
// the work area.
//
// So hyperion-view centres the window in the work area of the monitor it opened on, and
// shrinks it to fit that work area when it is larger. This file is the arithmetic, with no
// platform calls in it, so `hyperion-view --placement' can print it and a test can check it on
// every OS (hyperion/tests/view-tests.lisp). hyperion-view.cc supplies the real work area,
// DPI and frame on Windows and macOS.

#pragma once

#include <cerrno>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>

struct window_placement {
  long x, y, width, height;
};

// The values place_in_work_area is defined for, when they come from a command line rather than
// from Windows (--placement, review of train 22). Within them the arithmetic cannot overflow a
// long, which is 32 bits on Windows: the largest product, client size times DPI, is 10^9. A
// screen coordinate a million pixels from the origin, or a window 100000 logical pixels wide,
// is not one any display has.
const long kMaxCoordinate = 1000000;
const long kMaxClientSize = 100000;
const long kMaxDpi = 10000;
const long kMaxFrame = 10000;

inline bool placement_inputs_in_range(long work_left, long work_top, long work_right,
                                      long work_bottom, long client_width, long client_height,
                                      long dpi, long frame_width, long frame_height) {
  auto coordinate = [](long v) { return v >= -kMaxCoordinate && v <= kMaxCoordinate; };
  return coordinate(work_left) && coordinate(work_top) && coordinate(work_right) &&
         coordinate(work_bottom) && client_width >= 1 && client_width <= kMaxClientSize &&
         client_height >= 1 && client_height <= kMaxClientSize && dpi >= 1 && dpi <= kMaxDpi &&
         frame_width >= 0 && frame_width <= kMaxFrame && frame_height >= 0 &&
         frame_height <= kMaxFrame;
}

// The frame rectangle for a window whose client area is CLIENT_WIDTH x CLIENT_HEIGHT logical
// pixels (96 per inch), on a monitor of DPI dots per inch, whose frame adds FRAME_WIDTH x
// FRAME_HEIGHT physical pixels, in the work area WORK_LEFT..WORK_RIGHT x WORK_TOP..WORK_BOTTOM
// in physical pixels. The client size is scaled the way webview.h scales it
// (scale_value_for_dpi: value * dpi / 96, rounding down), so the size computed here is the one
// webview_set_size gave the window. Each dimension is cut to the work area's when it is larger,
// and the result is centred, rounding down.
inline window_placement place_in_work_area(long work_left, long work_top, long work_right,
                                           long work_bottom, long client_width,
                                           long client_height, long dpi, long frame_width,
                                           long frame_height) {
  long work_width = work_right - work_left;
  long work_height = work_bottom - work_top;
  long width = client_width * dpi / 96 + frame_width;
  long height = client_height * dpi / 96 + frame_height;
  if (width > work_width) width = work_width;
  if (height > work_height) height = work_height;
  return {work_left + (work_width - width) / 2, work_top + (work_height - height) / 2, width,
          height};
}

// --- the last placement, saved and restored (#485, part 2) -------------------------------
//
// With --placement-file, hyperion-view saves where the window is, in one line of this form:
//
//     hyperion-view-placement 1 LEFT TOP RIGHT BOTTOM MAXIMIZED
//
// On Windows the rectangle is the window's frame in physical pixels, in screen coordinates, as it
// was before it was maximised; MAXIMIZED is 1 or 0. At the next start the window is put back
// there if the rectangle still fits a monitor's work area, and otherwise placed as above. macOS
// uses the same line in its own coordinates, and its own rule for a frame that no longer fits
// (RESTORE_INTO_SCREENS, below). A monitor
// that was unplugged or rearranged, or a file that is not this format, is not an error: the
// window opens centred.

struct saved_placement {
  long left, top, right, bottom;
  bool maximized;
};

// The smallest window restored, in physical pixels. A smaller saved rectangle is ignored,
// because it is far more likely a corrupted file than a choice.
const long kMinSavedWidth = 200;
const long kMinSavedHeight = 150;

// TEXT, one saved placement line, in *OUT. False unless TEXT is exactly the format above: the
// fields separated by spaces, each a decimal number with an optional minus sign, optionally
// followed by whitespace at the end, and each coordinate within kMaxCoordinate of the origin, so
// that the subtractions in saved_placement_fits cannot overflow. strtol alone would accept
// "100-50" as two numbers and skip tabs and newlines between them (review of #521).
inline bool parse_saved_placement(const char *text, saved_placement *out) {
  const char *tag = "hyperion-view-placement 1 ";
  size_t tag_len = std::strlen(tag);
  if (std::strncmp(text, tag, tag_len) != 0) return false;
  const char *p = text + tag_len;
  long v[5];
  for (int k = 0; k < 5; k++) {
    if (k > 0 && *p != ' ') return false;
    while (*p == ' ') p++;
    if (*p != '-' && (*p < '0' || *p > '9')) return false;
    char *end = nullptr;
    errno = 0;
    v[k] = std::strtol(p, &end, 10);
    if (end == p || errno == ERANGE) return false;
    p = end;
  }
  while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
  if (*p != '\0' || (v[4] != 0 && v[4] != 1)) return false;
  for (int k = 0; k < 4; k++)
    if (v[k] < -kMaxCoordinate || v[k] > kMaxCoordinate) return false;
  *out = {v[0], v[1], v[2], v[3], v[4] == 1};
  return true;
}

// P as one saved placement line, with its newline, in BUF of SIZE bytes. Returns what
// snprintf returns.
inline int format_saved_placement(const saved_placement &p, char *buf, size_t size) {
  return std::snprintf(buf, size, "hyperion-view-placement 1 %ld %ld %ld %ld %d\n", p.left,
                       p.top, p.right, p.bottom, p.maximized ? 1 : 0);
}

// The largest invisible border allowed for on one side of a window. Windows 10 and 11 add
// about 7 pixels at 100% scaling and 11 at 150%.
const long kMaxInvisibleBorder = 100;

// The largest window-frame width allowed for, in pixels, when converting a border from one
// monitor's scaling to another's.
const long kMaxFrameMetric = 1000;

// An invisible border of BORDER pixels, measured on a monitor where the window's resizing frame
// is FRAME_FROM pixels wide, as it is on a monitor where that frame is FRAME_TO pixels wide.
// Windows draws the frame 1 pixel wide and leaves the rest invisible, so the invisible part
// grows by as much as the frame does: 8 px of frame and 7 invisible at 100%, 12 and 11 at
// 150%, 16 and 15 at 200%. A side with no invisible border (the top, on Windows 10 and 11)
// stays at 0. Never negative (review of #521).
inline long border_for_frame(long border, long frame_from, long frame_to) {
  if (border <= 0) return 0;
  long converted = border + (frame_to - frame_from);
  return converted < 0 ? 0 : converted;
}

// Whether P can be restored into the work area WORK_LEFT..WORK_RIGHT x WORK_TOP..WORK_BOTTOM:
// the whole rectangle is inside it, and it is at least the minimum size.
//
// BORDER_LEFT, BORDER_TOP, BORDER_RIGHT and BORDER_BOTTOM are the window's invisible resize
// borders, which GetWindowRect includes and which are not drawn. The saved rectangle may extend
// past the work area by that much on each side, so that a window snapped to half the screen, or
// dragged until its visible edge touches the screen's edge, is restored where it was instead of
// centred (review of #521). Each is from 0 to kMaxInvisibleBorder; the caller checks that.
inline bool saved_placement_fits(const saved_placement &p, long work_left, long work_top,
                                 long work_right, long work_bottom, long border_left = 0,
                                 long border_top = 0, long border_right = 0,
                                 long border_bottom = 0) {
  return p.right - p.left >= kMinSavedWidth && p.bottom - p.top >= kMinSavedHeight &&
         p.left >= work_left - border_left && p.top >= work_top - border_top &&
         p.right <= work_right + border_right && p.bottom <= work_bottom + border_bottom;
}

// --- restoring on macOS: clamped into the screen it overlaps most (#485) -----------------
//
// On macOS the saved line has the same form, with the frame in points in Cocoa's global
// coordinates, which are measured upwards from the bottom of the main screen: LEFT and RIGHT are
// the frame's x edges, and the two y fields hold its lower and its upper edge, in that order. So
// in both coordinate systems the first y field is the smaller one, and the arithmetic below does
// not depend on which way y runs.
//
// Displays change between launches more often on a Mac than the Windows rule allows for: a
// laptop's lid is closed, an external display is unplugged, a resolution is changed. So instead
// of using the saved frame only when it fits, as SAVED_PLACEMENT_FITS does on Windows, the frame
// is put on the screen whose visible frame (the screen less the menu bar and the Dock) it
// overlaps most, shrunk to that visible frame when it is larger, and then moved the least
// distance that puts it inside. Only a frame that overlaps no screen at all is ignored, and the
// window is then placed as PLACE_IN_WORK_AREA says.

// A rectangle with X0 < X1 and Y0 < Y1, whichever way y runs.
struct span_rect {
  long x0, y0, x1, y1;
};

// The most screens --restore-placement takes on its command line.
const int kMaxScreens = 16;

// Where RESTORE_INTO_SCREENS puts a saved frame. IGNORED is nullptr when the frame is used, and
// otherwise the reason it is not: "too-small" or "off-screen". SCREEN is the index of the screen
// chosen, or -1.
struct clamped_placement {
  const char *ignored;
  int screen;
  long x0, y0, x1, y1;
};

// The area A and B have in common, or 0 when they only touch or do not meet. A long long,
// because two coordinates within kMaxCoordinate of the origin can make a product past 32 bits.
inline long long overlap_area(const span_rect &a, const span_rect &b) {
  long w = (a.x1 < b.x1 ? a.x1 : b.x1) - (a.x0 > b.x0 ? a.x0 : b.x0);
  long h = (a.y1 < b.y1 ? a.y1 : b.y1) - (a.y0 > b.y0 ? a.y0 : b.y0);
  return (w > 0 && h > 0) ? static_cast<long long>(w) * h : 0;
}

// P put back on one of the COUNT visible frames in SCREENS, as described above. A screen with no
// width or height is passed over. When two screens overlap P equally, the first is chosen. A
// frame smaller than kMinSavedWidth x kMinSavedHeight is ignored, as on Windows. Coordinates are
// within kMaxCoordinate of the origin: parse_saved_placement checks P's, and the caller checks
// the screens'.
inline clamped_placement restore_into_screens(const saved_placement &p, const span_rect *screens,
                                              int count) {
  clamped_placement out = {nullptr, -1, 0, 0, 0, 0};
  long width = p.right - p.left;
  long height = p.bottom - p.top;
  if (width < kMinSavedWidth || height < kMinSavedHeight) {
    out.ignored = "too-small";
    return out;
  }
  span_rect saved = {p.left, p.top, p.right, p.bottom};
  long long best = 0;
  for (int i = 0; i < count; i++) {
    if (screens[i].x1 <= screens[i].x0 || screens[i].y1 <= screens[i].y0) continue;
    long long area = overlap_area(saved, screens[i]);
    if (area > best) {
      best = area;
      out.screen = i;
    }
  }
  if (out.screen < 0) {
    out.ignored = "off-screen";
    return out;
  }
  const span_rect &s = screens[out.screen];
  if (width > s.x1 - s.x0) width = s.x1 - s.x0;
  if (height > s.y1 - s.y0) height = s.y1 - s.y0;
  long x = p.left;
  if (x > s.x1 - width) x = s.x1 - width;
  if (x < s.x0) x = s.x0;
  long y = p.top;
  if (y > s.y1 - height) y = s.y1 - height;
  if (y < s.y0) y = s.y0;
  out.x0 = x;
  out.y0 = y;
  out.x1 = x + width;
  out.y1 = y + height;
  return out;
}
