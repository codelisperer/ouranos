// dialog-request.h --- the request a page makes for a native file dialog, checked (#986).
//
// hyperion-view binds one function into the app's page. The page calls it with a per-launch
// token and a request object: which dialog, its title, the file filters, the starting folder and,
// for save, a suggested name. Everything here is checked before any dialog is shown, and the
// checks are pure, so `hyperion-view --dialog-request TOKEN PARAMS` can print what a request
// parses to, and the tests can run them on every OS with no window.
//
// It uses webview.h's JSON reader (webview::detail::json_parse_c), so include webview.h first.

#pragma once

#include <cstddef>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

struct dialog_filter {
  std::string label;
  std::vector<std::string> patterns;  // each "*" or "*.ext"
};

struct dialog_request {
  std::string id;      // the page's id for the call: 1 to 9 digits, no leading zero
  std::string kind;    // "open", "open-many", "save" or "folder"
  std::string title;   // may be empty: the OS's own title is used
  std::string folder;  // may be empty: the dialog's remembered folder, else Documents
  std::string name;    // save only, may be empty
  std::vector<dialog_filter> filters;
};

const size_t kMaxDialogTitle = 200;
const size_t kMaxDialogFolder = 4096;
const size_t kMaxDialogName = 260;
const size_t kMaxDialogFilters = 32;
const size_t kMaxFilterLabel = 100;
const size_t kMaxFilterPatterns = 32;
const size_t kMaxPatternExtension = 16;
const size_t kMaxDialogParams = 65536;

// The raw JSON of element INDEX of the array S (KEY null), or of member KEY of the object S, in
// *OUT. False when it is not there.
inline bool dialog_json_member(const std::string &s, const char *key, int index,
                               std::string *out) {
  const char *value = nullptr;
  size_t size = 0;
  if (key == nullptr) {
    webview::detail::json_parse_c(s.c_str(), s.size(), nullptr, static_cast<size_t>(index),
                                  &value, &size);
  } else {
    webview::detail::json_parse_c(s.c_str(), s.size(), key, std::strlen(key), &value, &size);
  }
  if (value == nullptr) return false;
  out->assign(value, size);
  return true;
}

// RAW, the JSON of a string value, decoded into *OUT. False unless RAW is a JSON string.
inline bool dialog_json_string(const std::string &raw, std::string *out) {
  if (raw.size() < 2 || raw.front() != '"') return false;
  int n = webview::detail::json_unescape(raw.c_str(), raw.size(), nullptr);
  if (n < 0) return false;
  std::string decoded(static_cast<size_t>(n), '\0');
  if (n > 0) webview::detail::json_unescape(raw.c_str(), raw.size(), &decoded[0]);
  *out = decoded;
  return true;
}

inline bool dialog_text_ok(const std::string &s, size_t max) {
  if (s.size() > max) return false;
  for (unsigned char c : s)
    if (c < 0x20 || c == 0x7f) return false;
  return true;
}

// PATTERN is "*" or "*." followed by 1 to kMaxPatternExtension letters, digits, '_', '+' or '-'.
inline bool dialog_pattern_ok(const std::string &pattern) {
  if (pattern == "*") return true;
  if (pattern.size() < 3 || pattern.size() > 2 + kMaxPatternExtension) return false;
  if (pattern[0] != '*' || pattern[1] != '.') return false;
  for (size_t i = 2; i < pattern.size(); i++) {
    char c = pattern[i];
    bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
              c == '_' || c == '+' || c == '-';
    if (!ok) return false;
  }
  return true;
}

// ID is 1 to 9 decimal digits with no leading zero, so it can be written into a script as is.
inline bool dialog_id_ok(const std::string &id) {
  if (id.empty() || id.size() > 9 || id[0] == '0') return false;
  for (char c : id)
    if (c < '0' || c > '9') return false;
  return true;
}

// PARAMS, the JSON array a binding call carries, as a request in *OUT. PARAMS must be
// [TOKEN, ID, REQUEST] with TOKEN equal to EXPECTED_TOKEN: a call without the launch's token is
// refused here, on the native side, whatever the page's script did. ID is the page's number for
// the call, which the answer is sent to. Returns "" when the request is good, otherwise the
// reason: "token", "id", "malformed", "kind", "title", "folder", "name", "filters",
// "filter-label", "filter-patterns" or "pattern". OUT->ID is set once the token and the id are
// good, so a refusal for any later reason can still be answered.
//
// A FOLDER beginning with two slashes or two backslashes is refused: it names a network share,
// and opening the dialog there makes Windows send the user's credentials to that host.
inline std::string parse_dialog_request(const std::string &params,
                                        const std::string &expected_token,
                                        dialog_request *out) {
  if (params.size() > kMaxDialogParams || params.empty() || params.front() != '[')
    return "malformed";
  std::string raw, token;
  if (!dialog_json_member(params, nullptr, 0, &raw) || !dialog_json_string(raw, &token) ||
      expected_token.empty() || token != expected_token)
    return "token";
  std::string id;
  if (!dialog_json_member(params, nullptr, 1, &id) || !dialog_id_ok(id)) return "id";
  out->id = id;
  std::string request;
  if (!dialog_json_member(params, nullptr, 2, &request) || request.empty() ||
      request.front() != '{')
    return "malformed";
  if (dialog_json_member(params, nullptr, 3, &raw)) return "malformed";

  dialog_request r;
  r.id = id;
  if (!dialog_json_member(request, "kind", 0, &raw) || !dialog_json_string(raw, &r.kind))
    return "kind";
  if (r.kind != "open" && r.kind != "open-many" && r.kind != "save" && r.kind != "folder")
    return "kind";
  if (dialog_json_member(request, "title", 0, &raw) &&
      (!dialog_json_string(raw, &r.title) || !dialog_text_ok(r.title, kMaxDialogTitle)))
    return "title";
  if (dialog_json_member(request, "folder", 0, &raw) &&
      (!dialog_json_string(raw, &r.folder) || !dialog_text_ok(r.folder, kMaxDialogFolder) ||
       (r.folder.size() >= 2 && (r.folder[0] == '/' || r.folder[0] == '\\') &&
        (r.folder[1] == '/' || r.folder[1] == '\\'))))
    return "folder";
  if (dialog_json_member(request, "name", 0, &raw) &&
      (r.kind != "save" || !dialog_json_string(raw, &r.name) ||
       !dialog_text_ok(r.name, kMaxDialogName) || r.name.find_first_of("/\\") != std::string::npos))
    return "name";
  std::string filters;
  if (dialog_json_member(request, "filters", 0, &filters)) {
    if (r.kind == "folder" || filters.empty() || filters.front() != '[') return "filters";
    for (int i = 0;; i++) {
      std::string filter;
      if (!dialog_json_member(filters, nullptr, i, &filter)) break;
      if (static_cast<size_t>(i) >= kMaxDialogFilters) return "filters";
      if (filter.empty() || filter.front() != '[') return "filters";
      dialog_filter f;
      std::string label_raw, patterns_raw, patterns;
      if (!dialog_json_member(filter, nullptr, 0, &label_raw) ||
          !dialog_json_string(label_raw, &f.label) || f.label.empty() ||
          !dialog_text_ok(f.label, kMaxFilterLabel))
        return "filter-label";
      if (!dialog_json_member(filter, nullptr, 1, &patterns_raw) ||
          !dialog_json_string(patterns_raw, &patterns) || patterns.empty())
        return "filter-patterns";
      if (dialog_json_member(filter, nullptr, 2, &label_raw)) return "filters";
      size_t start = 0;
      while (start <= patterns.size()) {
        size_t end = patterns.find(';', start);
        if (end == std::string::npos) end = patterns.size();
        std::string pattern = patterns.substr(start, end - start);
        if (!dialog_pattern_ok(pattern)) return "pattern";
        if (f.patterns.size() >= kMaxFilterPatterns) return "filter-patterns";
        f.patterns.push_back(pattern);
        start = end + 1;
      }
      r.filters.push_back(f);
    }
  }
  *out = r;
  return "";
}

// S as a JSON string, with quotes, escaping what JSON requires. webview.h's own json_escape
// adds the quotes and escapes nothing, so a path holding a quote or a backslash would break the
// result it is put in.
inline std::string dialog_json_quote(const std::string &s) {
  std::string out = "\"";
  for (unsigned char c : s) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (c < 0x20) {
          char buf[8];
          std::snprintf(buf, sizeof buf, "\\u%04x", c);
          out += buf;
        } else {
          out += static_cast<char>(c);
        }
    }
  }
  return out + "\"";
}
