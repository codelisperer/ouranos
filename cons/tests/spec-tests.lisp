;;;; spec-tests.lisp --- cons/spec parsing + cons/run param resolution.
;;;;
;;;; Pure and network-free: parse a fixture manifest via install-spec (the target of
;;;; the `cons:project` macro) and check the parsed shape, then exercise cons/run's
;;;; param map / arg resolution / ${...} interpolation without running any target.

(in-package #:cons/tests)
(in-suite all)

(defun %fixture-spec ()
  "Parse a representative manifest, mirroring praxeon/cons.lisp."
  (cons/spec:install-spec
   "demo"
   '(:system "demo"
     :dynamic-space-size 4096
     :env (".env")
     :params ((host "127.0.0.1" :doc "bind address"))
     :default (build test)
     :targets
     ((build :doc "compile"        :load "demo")
      (test  :doc "suite"          :test "demo/tests")
      (dev   :doc "hot reload" :interactive t
             :load "demo/web"      :call ("demo/web:dev" :host host))
      (elise :doc "dump binary"    :sh ("sbcl" "--load" "b.lisp"))
      (paper :cwd "paper"          :sh ("./build.sh"))))))

(test spec-parses-top-level
  "install-spec reads system / heap / env / default off the options plist."
  (let ((s (%fixture-spec)))
    (is (string= "demo" (cons/spec:spec-name s)))
    (is (string= "demo" (cons/spec:spec-system s)))
    (is (= 4096 (cons/spec:spec-dss s)))
    (is (equal '(".env") (cons/spec:spec-env s)))
    (is (equal '(:build :test) (cons/spec:spec-default s)))
    (is (= 5 (length (cons/spec:spec-targets s))))))

(defun %tgt (spec name)
  (find name (cons/spec:spec-targets spec) :key #'cons/spec:target-name))

(test spec-parses-targets
  "Target clauses normalize: names -> keywords, :load -> a string list, :sh kept,
:interactive / :cwd carried, :call kept as (fn . args) data."
  (let ((s (%fixture-spec)))
    (is (equal '("demo") (cons/spec:target-load (%tgt s :build))))
    (is (string= "demo/tests" (cons/spec:target-test (%tgt s :test))))
    (is (cons/spec:target-interactive (%tgt s :dev)))
    (is (equal '("demo/web:dev" :host host)      ; the framework fn stays a string
               (cons/spec:target-call (%tgt s :dev))))
    (is (equal '("sbcl" "--load" "b.lisp") (cons/spec:target-sh (%tgt s :elise))))
    (is (string= "paper" (cons/spec:target-cwd (%tgt s :paper))))))

(test run-resolves-params-and-args
  "A CLI HOST=0.0.0.0 overrides the declared default; a bare param symbol in :call
resolves to that value, keywords pass through, and ${NAME} interpolates."
  (let* ((s (%fixture-spec))
         (pmap (cons/run::%param-map s '(("host" . "0.0.0.0")))))
    (is (string= "0.0.0.0" (cons/run::%param "host" pmap)))
    (is (equal '(:host "0.0.0.0")
               (cons/run::%resolve-args '(:host host) pmap)))
    (is (string= "bind 0.0.0.0"
                 (cons/run::%interpolate "bind ${host}" pmap)))))

(test run-param-default-when-absent
  "With no CLI override the declared default is used."
  (let* ((s (%fixture-spec))
         (pmap (cons/run::%param-map s '())))
    (is (string= "127.0.0.1" (cons/run::%param "host" pmap)))))

(test run-splits-fn-names
  "PACKAGE:NAME and PACKAGE::NAME split into upcased package + symbol strings."
  (multiple-value-bind (pkg sym) (cons/run::%split-fn "praxeon/elise:dev")
    (is (string= "PRAXEON/ELISE" pkg))
    (is (string= "DEV" sym)))
  (multiple-value-bind (pkg sym) (cons/run::%split-fn "pkg::internal")
    (is (string= "PKG" pkg))
    (is (string= "INTERNAL" sym))))
