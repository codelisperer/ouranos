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
