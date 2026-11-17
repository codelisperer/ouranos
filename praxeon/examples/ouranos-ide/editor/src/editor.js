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
//
// - File tabs (#1228). A form with data-ou-editor-scope evaluates the editor of the pane that
//   is shown inside the element that attribute names, so one form serves every tab. An editor
//   built for a file carries data-ou-editor-buffer (the buffer's id on the server),
//   data-ou-editor-tab (the id of its tab element) and data-ou-editor-save (the id of the Save
//   button). Mod-S clicks that button. The tab element gets the attribute data-ou-modified
//   while the editor's text differs from what was last read or saved: at first the starting
//   text, and after a save the text that was sent, once the server's answer, an element with
//   data-ou-saved naming the editor's element, has arrived. The page's buttons read the text
//   to send through window.OuranosEditor: fieldsOf, activeFields and contentOf.

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

// The editor element of the pane shown inside the element named ID, or null.
function activeHost(id) {
  const scope = document.getElementById(id);
  return scope ? scope.querySelector(".ide-pane:not([hidden]) [data-ou-editor]") : null;
}

// The editor element FORM evaluates: the shown one in its data-ou-editor-scope when it has
// one, else the one whose data-ou-editor-form names it, or null.
function hostOf(form) {
  if (form.dataset.ouEditorScope) return activeHost(form.dataset.ouEditorScope);
  if (!form.id) return null;
  return document.querySelector('[data-ou-editor-form="' + CSS.escape(form.id) + '"]');
}

// The text each editor was last read or saved with, and the text sent by a save that has not
// been answered yet.
const baselines = new WeakMap();
const pending = new WeakMap();

function markModified(host) {
  const view = views.get(host);
  const tab = host.dataset.ouEditorTab && document.getElementById(host.dataset.ouEditorTab);
  if (!view || !tab) return;
  const base = baselines.get(host) || "";
  const doc = view.state.doc;
  if (doc.length !== base.length || doc.toString() !== base) {
    tab.setAttribute("data-ou-modified", "1");
  } else {
    tab.removeAttribute("data-ou-modified");
  }
}

// After a push or an answer: a data-ou-saved element says the save of that editor's text
// succeeded, so the text it sent becomes the baseline.
function afterChange(root) {
  const saved = [];
  if (root.matches && root.matches("[data-ou-saved]")) saved.push(root);
  if (root.querySelectorAll) saved.push(...root.querySelectorAll("[data-ou-saved]"));
  for (const el of saved) {
    const host = document.getElementById(el.dataset.ouSaved);
    if (host && pending.has(host)) {
      baselines.set(host, pending.get(host));
      pending.delete(host);
    }
    el.removeAttribute("data-ou-saved");
  }
}

// Every tab's mark is set again after a change to the page, because a pushed body brings a
// tab bar without marks.
function markAll() {
  document.querySelectorAll("[data-ou-editor-tab]").forEach(markModified);
}

// The fields a save of the editor element ID sends: its buffer's id and its text. The text is
// remembered, so a successful answer can make it the baseline.
function fieldsOf(id) {
  const host = document.getElementById(id);
  const view = host && views.get(host);
  if (!view) return {};
  const text = view.state.doc.toString();
  pending.set(host, text);
  return { tab: host.dataset.ouEditorBuffer || "", content: text };
}

// fieldsOf for the editor shown in the element ID; for the scratch buffer only an empty tab.
function activeFields(id) {
  const host = activeHost(id);
  if (!host) return {};
  if (!host.dataset.ouEditorBuffer) return { tab: "" };
  return fieldsOf(host.id);
}

// The text of the editor element ID, as the field `content', for a close.
function contentOf(id) {
  const host = document.getElementById(id);
  const view = host && views.get(host);
  return view ? { content: view.state.doc.toString() } : {};
}

function save(host) {
  const button = host.dataset.ouEditorSave && document.getElementById(host.dataset.ouEditorSave);
  if (button) button.click();
  // True in every case, so the browser's own Save Page dialog does not open.
  return true;
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
        Prec.highest(keymap.of([
          { key: "Mod-Enter", run: () => submit(host) },
          { key: "Mod-s", run: () => save(host) },
        ])),
        EditorView.updateListener.of((update) => {
          if (update.docChanged) markModified(host);
        }),
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
  baselines.set(host, host.dataset.ouEditorDoc || "");
  markModified(host);
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
    if (form.elements.tab) form.elements.tab.value = host.dataset.ouEditorBuffer || "";
  },
  true,
);

function start() {
  mountAll(document);
  new MutationObserver((records) => {
    for (const record of records) {
      for (const node of record.addedNodes) {
        if (node.nodeType === 1) {
          mountAll(node);
          afterChange(node);
        }
      }
    }
    markAll();
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
  fieldsOf,
  activeFields,
  contentOf,
};
