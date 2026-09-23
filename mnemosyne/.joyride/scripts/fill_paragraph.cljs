(ns fill-paragraph
  "Emacs M-q / vim gwip for VS Code: reflow the paragraph at the cursor to
   `editor.wordWrapColumn`. Splits on blank lines, preserves indentation, and
   honors Markdown blockquote (`> `) and list (`- `, `1.`) prefixes — reflowing a
   single list item at a time so separate items aren't merged. Bound to Alt+Q.

   Returns nil on purpose: returning the vscode `edit` Promise makes Joyride
   recurse while printing it (\"Maximum call stack size exceeded\")."
  (:require ["vscode" :as vscode]
            [clojure.string :as str]))

(defn- fill-column []
  (or (.get (.getConfiguration vscode/workspace "editor") "wordWrapColumn") 80))

(defn- line-text [doc i] (.-text (.lineAt doc i)))
(defn- blank? [doc i] (str/blank? (line-text doc i)))
(defn- marker? [doc i] (some? (re-find #"^[ \t]*(?:[-*+]|\d+[.)])\s+" (line-text doc i))))

(defn- para-bounds
  "[start end] lines to reflow: a blank-line-delimited block, narrowed to the
   single list item under the cursor when the block is a list."
  [doc cur n]
  (let [b-start (loop [i cur] (if (and (pos? i) (not (blank? doc (dec i)))) (recur (dec i)) i))
        b-end   (loop [i cur] (if (and (< i (dec n)) (not (blank? doc (inc i)))) (recur (inc i)) i))]
    (if (some #(marker? doc %) (range b-start (inc b-end)))
      [(loop [i cur] (if (and (> i b-start) (not (marker? doc i))) (recur (dec i)) i))
       (loop [i cur] (if (and (< i b-end) (not (marker? doc (inc i)))) (recur (inc i)) i))]
      [b-start b-end])))

(defn- prefixes
  "[first-prefix cont-prefix strip-re] for a paragraph starting with `first-line`.
   Blockquotes repeat the marker; list items keep it on line 1 and hang-indent."
  [first-line]
  (let [lead (re-find #"^[ \t]*" first-line)
        body (subs first-line (count lead))]
    (cond
      (re-find #"^(?:>\s?)+" body)
      (let [m (re-find #"^(?:>\s?)+" body)]
        [(str lead m) (str lead m) #"^[ \t]*(?:>\s?)+"])

      (re-find #"^(?:[-*+]|\d+[.)])\s+" body)
      (let [m (re-find #"^(?:[-*+]|\d+[.)])\s+" body)]
        [(str lead m)
         (str lead (str/join (repeat (count m) " ")))
         #"^[ \t]*(?:(?:[-*+]|\d+[.)])\s+)?"])

      :else [lead lead #"^[ \t]*"])))

(defn- strip [line re]
  (let [m (re-find re line)] (if m (subs line (count m)) line)))

(defn- wrap [words width fp cp]
  (loop [ws words, line nil, out []]
    (if (empty? ws)
      (if line (conj out line) out)
      (let [w (first ws)]
        (cond
          (nil? line)                             (recur (rest ws) (str (if (empty? out) fp cp) w) out)
          (<= (+ (count line) 1 (count w)) width) (recur (rest ws) (str line " " w) out)
          :else                                   (recur ws nil (conj out line)))))))

(defn fill-paragraph! []
  (when-let [editor (.-activeTextEditor vscode/window)]
    (let [doc (.-document editor)
          cur (.. editor -selection -active -line)
          n   (.-lineCount doc)]
      (when-not (blank? doc cur)
        (let [[start end] (para-bounds doc cur n)
              [fp cp re]  (prefixes (line-text doc start))
              words   (-> (->> (range start (inc end))
                               (map #(strip (line-text doc %) re))
                               (str/join " "))
                          str/trim
                          (str/split #"\s+"))
              wrapped (str/join "\n" (wrap words (fill-column) fp cp))
              rng     (vscode/Range. (vscode/Position. start 0)
                                     (vscode/Position. end (count (line-text doc end))))]
          (.edit editor (fn [b] (.replace b rng wrapped)))))))
  nil)

(fill-paragraph!)
