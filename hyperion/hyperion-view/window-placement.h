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
// DPI and frame on Windows.

#pragma once

#include <cerrno>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>

struct window_placement {
  long x, y, width, height;
};

// The frame rectangle for a window whose client area is CLIENT_WIDTH x CLIENT_HEIGHT logical
// pixels (96 per inch), on a monitor of DPI dots per inch, whose frame adds FRAME_WIDTH x
// FRAME_HEIGHT physical pixels, in the work area WORK_LEFT..WORK_RIGHT x WORK_TOP..WORK_BOTTOM
// in physical pixels. The client size is scaled the way webview.h scales it
// (scale_value_for_dpi: value * dpi / 96, rounding down), so the size computed here is the one
// webview_set_size gave the window. Each dimension is cut to the work area's when it is larger,
// and the result is centred, rounding down.
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
// The rectangle is the window's frame in physical pixels, in screen coordinates, as it was
// before it was maximised; MAXIMIZED is 1 or 0. At the next start the window is put back there
// if the rectangle still fits a monitor's work area, and otherwise placed as above. A monitor
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

// Whether P can be restored into the work area WORK_LEFT..WORK_RIGHT x WORK_TOP..WORK_BOTTOM:
// the whole rectangle is inside it, and it is at least the minimum size.
inline bool saved_placement_fits(const saved_placement &p, long work_left, long work_top,
                                 long work_right, long work_bottom) {
  return p.right - p.left >= kMinSavedWidth && p.bottom - p.top >= kMinSavedHeight &&
         p.left >= work_left && p.top >= work_top && p.right <= work_right &&
         p.bottom <= work_bottom;
}
