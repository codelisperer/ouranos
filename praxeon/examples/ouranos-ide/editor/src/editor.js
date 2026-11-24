// editor.js --- the code editor of the Ouranos IDE example, built on CodeMirror 6 (#1218).
//
// build.sh bundles this file and the CodeMirror packages it imports into
// ../ouranos-editor.min.js, which is committed. The IDE serves that file; nothing here runs
// under Node when the IDE runs.
//
// What it does on the page:
//
// - Every element with the attribute data-ou-editor gets a CodeMirror editor inside it: Common
//   Lisp syntax highlighting (which also suits Coalton source), bracket matching, line numbers
//   and undo history. The element's data-ou-editor-doc attribute is the starting text. An
//   element is set up once, when the page loads or when it is added to the page later, for
//   example when a window is opened. The server marks the element with data-ou-preserve, so
//   hyperion/desktop-ui keeps the same element, and with it the editor, when the window's body
//   is replaced by a push.
//
// - data-ou-editor-form names the form that evaluates. Before that form is submitted, its
//   hidden field `input' is set to the selected text, or to the whole document when nothing is
//   selected, and its hidden field `buffer' to the whole document. htmx then posts the form.
//
// - Mod-Enter (Ctrl-Enter, or Cmd-Enter on macOS) in the editor submits that form, as the
//   form's Evaluate button does.

import { EditorState, Prec } from "@codemirror/state";
import {
  EditorView,
  keymap,
  lineNumbers,
  drawSelection,
  highlightActiveLine,
  highlightSpecialChars,
} from "@codemirror/view";
import {
  defaultKeymap,
  history,
  historyKeymap,
  indentWithTab,
} from "@codemirror/commands";
import {
  StreamLanguage,
  bracketMatching,
  syntaxHighlighting,
  defaultHighlightStyle,
} from "@codemirror/language";
import { commonLisp } from "@codemirror/legacy-modes/mode/commonlisp";

const views = new WeakMap();

function formOf(host) {
  const id = host.dataset.ouEditorForm;
  return id ? document.getElementById(id) : null;
}

// The editor element whose data-ou-editor-form names FORM, or null.
function hostOf(form) {
  if (!form.id) return null;
  return document.querySelector('[data-ou-editor-form="' + CSS.escape(form.id) + '"]');
}

// The selected text, or the whole document when the selection is empty.
function textToEvaluate(view) {
  const range = view.state.selection.main;
  return range.empty
    ? view.state.doc.toString()
    : view.state.sliceDoc(range.from, range.to);
}

function submit(host) {
  const form = formOf(host);
  if (!form) return false;
  if (form.requestSubmit) form.requestSubmit();
  else form.dispatchEvent(new Event("submit", { cancelable: true, bubbles: true }));
  return true;
}

const theme = EditorView.theme({
  "&": { height: "100%", fontSize: "12px", backgroundColor: "#fff" },
  ".cm-scroller": { fontFamily: "ui-monospace, Consolas, monospace", overflow: "auto" },
  "&.cm-focused": { outline: "none" },
});

function mount(host) {
  if (views.has(host) || !host.isConnected) return;
  const view = new EditorView({
    parent: host,
    state: EditorState.create({
      doc: host.dataset.ouEditorDoc || "",
      extensions: [
        Prec.highest(keymap.of([{ key: "Mod-Enter", run: () => submit(host) }])),
        lineNumbers(),
        highlightSpecialChars(),
        history(),
        drawSelection(),
        highlightActiveLine(),
        bracketMatching(),
        StreamLanguage.define(commonLisp),
        syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
        keymap.of([...defaultKeymap, ...historyKeymap, indentWithTab]),
        theme,
      ],
    }),
  });
  views.set(host, view);
}

function mountAll(root) {
  if (root.matches && root.matches("[data-ou-editor]")) mount(root);
  if (root.querySelectorAll) root.querySelectorAll("[data-ou-editor]").forEach(mount);
}

// Runs before htmx's own listener on the form, because it listens on the document in the
// capture phase, so the hidden fields hold the editor's text when htmx reads the form.
document.addEventListener(
  "submit",
  (event) => {
    const form = event.target;
    if (!(form instanceof HTMLFormElement)) return;
    const host = hostOf(form);
    const view = host && views.get(host);
    if (!view) return;
    if (form.elements.input) form.elements.input.value = textToEvaluate(view);
    if (form.elements.buffer) form.elements.buffer.value = view.state.doc.toString();
  },
  true,
);

function start() {
  mountAll(document);
  new MutationObserver((records) => {
    for (const record of records) {
      for (const node of record.addedNodes) {
        if (node.nodeType === 1) mountAll(node);
      }
    }
  }).observe(document.body, { childList: true, subtree: true });
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", start);
} else {
  start();
}

// For the page's console, and for the IDE's browser test, which selects text and presses
// Mod-Enter through it. viewOf(element) is the editor built in that element, or undefined.
window.OuranosEditor = {
  viewOf: (host) => views.get(host),
  mountAll,
  textToEvaluate,
};
