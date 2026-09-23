;;;; aion.asd --- system definitions for Aion
;;;;
;;;; Aion (Αἰών, "the eternal"): a Coalton-first functional standard library for
;;;; Common Lisp -- persistent collections, a consistent sequence/collection
;;;; protocol, and the Clojure-goodness (transducers, optics, lazy-seq, threading)
;;;; that Coalton's already-strong core doesn't yet cover. Two faces: a typed
;;;; Coalton layer and a pure-CL layer. The name = immutability (values that never
;;;; change). See docs/roadmap.md, docs/coalton-gap-analysis.md, docs/aion-vision.md.

(defsystem "aion"
  :description "A Coalton-first functional standard library for Common Lisp."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  :depends-on ("coalton"
               "alexandria")
  :serial t
  :components ((:module "src"
                :serial t
                :components ((:file "packages")
                             (:file "aion"))))
  :in-order-to ((test-op (test-op "aion/tests"))))

;;; aion/csv --- the CSV face. A separate, dependency-free system on purpose: the
;;; portable scalar-DFA backend loads on bare SBCL/CCL/ECL/ABCL with no toolchain
;;; and no Coalton compile. Native/SIMD backends (zsv, duckdb, sb-simd) will be
;;; further opt-in systems behind the same neutral protocol. See docs/csv-design.md.
(defsystem "aion/csv"
  :description "Backend-neutral CSV: dialects, a scalar-DFA reader/writer, and reducible row streams (the dependency-free `portable` backend + conformance oracle)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  :depends-on ()
  :serial t
  :components ((:module "src/csv"
                :serial t
                :components ((:file "packages")
                             (:file "reduced")
                             (:file "conditions")
                             (:file "dialect")
                             (:file "parse")
                             (:file "write"))))
  :in-order-to ((test-op (test-op "aion/csv/tests"))))

;;; aion/csv/types --- the typed core of the CSV reader (Coalton). A SEPARATE, OPT-IN
;;; system: `aion/csv` above is dependency-free on purpose, so it must not gain Coalton.
;;; This holds the state machine as a checked type plus a reference parser built from it;
;;; the conformance test requires the shipping parser to agree with that reference.
(defsystem "aion/csv/types"
  :description "The typed core of aion/csv: a total ParseState transition and a provably-distinct Dialect, in Coalton."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  :depends-on ("coalton")
  :serial t
  :components ((:module "src/csv"
                :serial t
                :components ((:file "types-packages")
                             (:file "types"))))
  :in-order-to ((test-op (test-op "aion/csv/types/tests"))))

(defsystem "aion/csv/types/tests"
  :description "Totality of the CSV transition, the Dialect invariant, and conformance between the typed reference parser and the shipping one."
  :depends-on ("aion/csv/types" "aion/csv" "fiveam")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "csv-types"))))
  :perform (test-op (o c) (uiop:symbol-call :aion/csv/types/tests :run-tests)))

(defsystem "aion/csv/tests"
  :description "Conformance tests for aion/csv (RFC 4180 + edge cases)."
  :depends-on ("aion/csv" "fiveam")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "csv"))))
  :perform (test-op (o c) (uiop:symbol-call :aion/csv/tests :run-tests)))

;;; aion/uv --- libuv for Common Lisp. A separate, OPT-IN system: core aion stays pure
;;; and toolchain-free, while consumers that want an event loop, async/sync filesystem
;;; operations, timers or filesystem watching depend on aion/uv explicitly.
;;;
;;; The shared library is NOT a build-time dependency of loading this system -- it is
;;; located and loaded on first use (see src/uv/library.lisp), so a machine without it
;;; can still compile and inspect the code. Build it with:
;;;   sbcl --script scripts/build-libuv.lisp        (needs a C compiler; no cmake/make)
;;; That is ADR-0011's lesson applied: Woo bound libev at LOAD time, which is why every
;;; desktop bundle died on a clean machine.
(defsystem "aion/uv"
  :description "libuv bound for Common Lisp: an event loop, synchronous and asynchronous filesystem operations, timers, and filesystem watching, with a typed Coalton core."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  :depends-on ("cffi" "coalton")
  :serial t
  :components ((:module "src/uv"
                :serial t
                :components ((:file "packages")
                             (:file "library")
                             (:file "ffi")
                             (:file "types")
                             (:file "conditions")
                             (:file "loop")
                             (:file "fs")
                             (:file "timer")
                             (:file "watch")
                             (:file "introspect"))))
  :in-order-to ((test-op (test-op "aion/uv/tests"))))

(defsystem "aion/uv/tests"
  :description "Tests for aion/uv. Requires a built libuv (scripts/build-libuv.lisp)."
  :depends-on ("aion/uv" "fiveam")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "uv"))))
  :perform (test-op (o c) (uiop:symbol-call :aion/uv/tests :run-tests)))

;;; aion/uv/net --- streams: TCP, pipes and DNS. A sub-system of aion/uv rather than a
;;; system of its own, because it reuses that loop, pointer registry, callback guard and
;;; error decoding wholesale -- and a sub-system is how granularity is taken here, so a
;;; consumer takes only what it needs without the shared substrate being duplicated.
;;;
;;; It lives in aion, not hyperion, because everything that wants a socket sits to aion's
;;; RIGHT in the DAG: cons wants subprocess pipes, hermes depends on aion alone and will
;;; want an HTTP client, mnemosyne's Postgres wire is a named target. HTTP parsing and the
;;; request/response model stay in hyperion -- binding here, decisions there. See the
;;; ECOSYSTEM decisions log, 2026-08-04 (pre-publication issue 117).
(defsystem "aion/uv/net"
  :description "Stream transport over libuv for Common Lisp: TCP, pipes and asynchronous DNS, with backpressure designed in and a typed Coalton core."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  :depends-on ("aion/uv")
  :serial t
  :components ((:module "src/uv/net"
                :serial t
                :components ((:file "packages")
                             (:file "ffi")
                             (:file "types")
                             (:file "stream")
                             (:file "tcp")
                             (:file "dns"))))
  :in-order-to ((test-op (test-op "aion/uv/net/tests"))))

(defsystem "aion/uv/net/tests"
  :description "Tests for aion/uv/net. Requires a built libuv (scripts/build-libuv.lisp)."
  :depends-on ("aion/uv/net" "aion/uv" "fiveam")   ; uv-net.lisp calls uv: directly
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "uv-net"))))
  :perform (test-op (o c) (uiop:symbol-call :aion/uv/net/tests :run-tests)))

;;; aion/uv/process --- subprocesses and signals. Depends on aion/uv/net, and that is the
;;; point rather than an accident: a child's stdio is uv_pipe_t, which is a uv_stream_t,
;;; so it arrives as an ordinary CONNECTION with the stream layer's backpressure already
;;; attached. The consumer is `cons` at DAG position 2, which runs build and test targets
;;; as subprocesses and today blocks on uiop:run-program -- orchestration stays there,
;;; the binding lives here (ECOSYSTEM decisions log, 2026-08-04, pre-publication issue 117; pre-publication issue 119).
(defsystem "aion/uv/process"
  :description "Subprocesses and signals over libuv for Common Lisp: uv_spawn with streamed stdio, exit status decoded together with the terminating signal, and signal handling on a real Lisp stack."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  :depends-on ("aion/uv/net"
               "aion/uv")         ; process.lisp and signal.lisp call uv: and uv/ffi: directly
  :serial t
  :components ((:module "src/uv/process"
                :serial t
                :components ((:file "packages")
                             (:file "ffi")
                             (:file "types")
                             (:file "process")
                             (:file "signal"))))
  :in-order-to ((test-op (test-op "aion/uv/process/tests"))))

(defsystem "aion/uv/process/tests"
  :description "Tests for aion/uv/process. Requires a built libuv (scripts/build-libuv.lisp)."
  :depends-on ("aion/uv/process" "aion/uv" "aion/uv/net" "fiveam")  ; uv-process.lisp calls both
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "uv-process"))))
  :perform (test-op (o c) (uiop:symbol-call :aion/uv/process/tests :run-tests)))

;;; aion/examples/uv-probe --- the clean-room subject for ADR-0013. Dumped by
;;; scripts/build-desktop-app.lisp and run by scripts/verify-bundle.sh on a machine with no
;;; toolchain, no repo and no libuv, to prove the bundle carries and resolves its own copy.
;;; A console app on purpose: the desktop example would drag in a display and the WebKitGTK
;;; stack, so a failure there would not tell you which question had failed.
(defsystem "aion/examples/uv-probe"
  :description "A dumpable probe that exercises a bundled libuv: resolve, verify the ABI, run a timer, round-trip a file."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  :depends-on ("aion/uv")
  :serial t
  :components ((:module "examples/uv-probe"
                :serial t
                :components ((:file "app")))))

;;; aion/clock --- a monotonic Gregorian-100ns clock and the time-ordered v6 ids built on
;;; it. Dependency-free ON PURPOSE, and not merely by accident of being small: hermes may
;;; depend on aion and nothing else, and it is one of the consumers (pre-publication issue 96). Core aion stays
;;; coalton + alexandria; this adds neither.
;;;
;;; Extracted from mnemosyne/id, where it was DAG-legal but wrong: a monotonic clock is a
;;; floor primitive, not a persistence concern, and taking a data layer as a dependency to
;;; obtain one is the coupling aion exists to prevent. mnemosyne keeps TOUCH! and the
;;; entity-stamping convention and calls NEW-ID from here.
;;; aion/http-client --- an interceptor-shaped HTTP client for one outbound call (pre-publication issue 202).
;;; Lives here for the reason aion/interceptor does: the shape is request-response, not web.
;;; It had already been reimplemented twice before it moved -- internal to hermes, and three
;;; raw dex:post calls in praxeon -- which is the same evidence that settled pre-publication issue 177.
(defsystem "aion/http-client"
  :description "An interceptor-shaped HTTP client: enter stages, one round-trip, leave stages."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  :depends-on ("dexador")
  :serial t
  :components ((:module "src/http-client"
                :serial t
                :components ((:file "packages")
                             (:file "client"))))
  :in-order-to ((test-op (test-op "aion/http-client/tests"))))

(defsystem "aion/http-client/tests"
  :description "Tests for aion/http-client: stage order, the effect seam, and failure."
  :depends-on ("aion/http-client" "fiveam")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "http-client"))))
  :perform (test-op (o c) (uiop:symbol-call :aion/http-client/tests :run-tests)))

;;; aion/secret --- a credential that cannot be printed by accident (pre-publication issue 209).
;;; DEPENDENCY-FREE on purpose, exactly like aion/csv: `cons` must be able to hold a DB
;;; password opaquely without its core gaining Coalton. The typed view is the opt-in
;;; aion/secret/types below.
(defsystem "aion/secret"
  :description "An opaque credential wrapper: plaintext in, REVEAL out, #<SECRET REDACTED> on every print path."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  :depends-on ()
  :serial t
  :components ((:module "src/secret"
                :serial t
                :components ((:file "packages")
                             (:file "secret"))))
  :in-order-to ((test-op (test-op "aion/secret/tests"))))

(defsystem "aion/secret/tests"
  :description "Tests for aion/secret: that printing redacts, that REVEAL still returns the value, and that the printed form is unreadable."
  :depends-on ("aion/secret" "fiveam")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "secret"))))
  :perform (test-op (o c) (uiop:symbol-call :aion/secret/tests :run-tests)))

;;; aion/secret/types --- SECRET as an opaque Coalton field type. SEPARATE and opt-in so
;;; aion/secret stays Coalton-free (see aion/csv vs aion/csv/types for the same split).
(defsystem "aion/secret/types"
  :description "SECRET as a Coalton type (repr :native), so a DEFINE-TYPE can hold a credential without a printable String field."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  :depends-on ("aion/secret" "coalton")
  :serial t
  :components ((:module "src/secret"
                :serial t
                :components ((:file "types-packages")
                             (:file "types"))))
  :in-order-to ((test-op (test-op "aion/secret/types/tests"))))

(defsystem "aion/secret/types/tests"
  :description "Tests for aion/secret/types: a Coalton DEFINE-TYPE holding a Secret redacts it in both compilation modes' printers."
  :depends-on ("aion/secret/types" "fiveam")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "secret-types"))))
  :perform (test-op (o c) (uiop:symbol-call :aion/secret/types/tests :run-tests)))

;;; aion/interceptor --- a typed, protocol-agnostic interceptor pipeline (Coalton).
;;; Dependency-free apart from Coalton itself, and deliberately NOT owned by a framework:
;;; the shape is request-response, not web, and the tree had already reimplemented it twice
;;; (hyperion inbound, hermes outbound in hand-rolled CL) before it moved here.
(defsystem "aion/windows"
  :description "The Windows-specific API surface: UTF-16 marshalling, GetLastError/HRESULT as conditions, handle lifetime, and struct layouts asserted at load. Windows-only (ADR-0003)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  ;; cffi only. No C toolchain (ADR-0003 s8) and no bordeaux-threads: the tree is
  ;; SBCL-exclusive and this system is Windows-exclusive on top of that, so sb-thread is
  ;; already the only thread implementation that can run here.
  :depends-on ("cffi")
  :serial t
  :components ((:module "src/windows"
                :serial t
                :components ((:file "packages")
                             (:file "platform")
                             (:file "library")
                             (:file "layout")
                             (:file "ffi")
                             (:file "conditions")
                             (:file "string")
                             (:file "handle"))))
  :in-order-to ((test-op (test-op "aion/windows/tests"))))

(defsystem "aion/windows/tests"
  :description "Tests for aion/windows. Windows-only; the layout assertions are the headline."
  :depends-on ("aion/windows" "fiveam")
  :serial t
  :components ((:module "tests/windows"
                :serial t
                :components ((:file "packages")
                             (:file "layout-tests")
                             (:file "string-tests")
                             (:file "conditions-tests"))))
  :perform (test-op (op c) (uiop:symbol-call :aion/windows/tests :run-tests)))

(defsystem "aion/windows/registry"
  :description "Reading one registry value in a NAMED bitness view (#132). Read-only, and deliberately not a registry API -- see src/windows/registry/registry.lisp."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  :depends-on ("aion/windows")
  :serial t
  :components ((:module "src/windows/registry"
                :serial t
                :components ((:file "packages")
                             (:file "registry"))))
  :in-order-to ((test-op (test-op "aion/windows/registry/tests"))))

(defsystem "aion/windows/registry/tests"
  :description "Tests for aion/windows/registry."
  :depends-on ("aion/windows/registry" "fiveam")
  :serial t
  :components ((:module "tests/windows/registry"
                :serial t
                :components ((:file "packages")
                             (:file "registry-tests"))))
  :perform (test-op (o c) (uiop:symbol-call :aion/windows/registry/tests :run-tests)))

(defsystem "aion/windows/com"
  :description "OLE/COM automation: apartments, IDispatch, VARIANT marshalling. The meta-API COM is sequenced first for (ADR-0003 s5)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  ;; aion/windows/registry for CLASS-AVAILABLE-P alone (pre-publication issue 306): CoCreateInstance cannot tell
  ;; "not installed" from "installed for the other bitness" -- both are REGDB_E_CLASSNOTREG
  ;; under WOW64 -- and the registry can. Read-only and Windows-only, like this system.
  :depends-on ("aion/windows" "aion/windows/registry")
  :serial t
  :components ((:module "src/windows/com"
                :serial t
                :components ((:file "packages")
                             (:file "ffi")
                             (:file "typelib-ffi")
                             (:file "apartment")
                             (:file "variant")
                             (:file "dispatch")
                             (:file "typelib"))))
  :in-order-to ((test-op (test-op "aion/windows/com/tests"))))

(defsystem "aion/windows/com/tests"
  :description "Tests for aion/windows/com, including a LIVE COM round trip."
  ;; `aion/windows' is declared although `aion/windows/com' already pulls it in: this suite
  ;; uses AION/WINDOWS and AION/WINDOWS/FFI directly (apartment-tests, layout-tests), and a
  ;; system that names a package it reads must say so rather than reach it through a
  ;; neighbour's dependency (pre-publication issue 461, #162).
  :depends-on ("aion/windows" "aion/windows/com" "fiveam")
  :serial t
  :components ((:module "tests/windows/com"
                :serial t
                :components ((:file "packages")
                             (:file "layout-tests")
                             (:file "apartment-tests")
                             (:file "variant-tests")
                             (:file "naming-tests")
                             (:file "typelib-tests")
                             (:file "live-tests")
                             (:file "byref-tests")
                             (:file "put-tests")
                             (:file "capability-tests"))))
  :perform (test-op (op c) (uiop:symbol-call :aion/windows/com/tests :run-tests)))

(defsystem "aion/pool"
  :description "A bounded worker pool: N threads, a queue with a limit, and a refusal."
  ;; aion/log, for the one thing a pool must not do silently: discard a job that signalled.
  ;; The submitter is long gone by then -- no future, no result channel -- so if the pool
  ;; says nothing, nothing anywhere does. That is the doctrine this file's own header
  ;; states: consumers that want logging depend on aion/log.
  :depends-on ("aion/log")
  :pathname "src/pool"
  :serial t
  :components ((:file "packages")
               (:file "pool")))

(defsystem "aion/pool/tests"
  :description "Tests for aion/pool: FIFO order, the bound, refusal, and shutdown drain."
  :depends-on ("aion/pool" "fiveam")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "pool"))))
  :perform (test-op (o c) (uiop:symbol-call :aion/pool/tests :run-tests)))

(defsystem "aion/interceptor"
  :description "A typed, protocol-agnostic interceptor pipeline over a context (Coalton)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  :depends-on ("coalton")
  :serial t
  :components ((:module "src/interceptor"
                :serial t
                :components ((:file "packages")
                             (:file "interceptor"))))
  :in-order-to ((test-op (test-op "aion/interceptor/tests"))))

(defsystem "aion/interceptor/tests"
  :description "Tests for aion/interceptor: Proceed threading, Halt short-circuit, Failure, and leave order."
  :depends-on ("aion/interceptor" "fiveam")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "interceptor"))))
  :perform (test-op (o c) (uiop:symbol-call :aion/interceptor/tests :run-tests)))

(defsystem "aion/signature"
  :description "Ed25519 detached signatures over bytes: verify, sign, key encoding. Nothing else (pre-publication issue 208)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  ;; ironclad is already the tree's crypto library in four places, and cl-base64 already
  ;; loads with it -- so this adds no new external dependency, only a new consumer.
  :depends-on ("ironclad" "cl-base64")
  :serial t
  :components ((:module "src/signature"
                :serial t
                :components ((:file "packages")
                             (:file "signature"))))
  :in-order-to ((test-op (test-op "aion/signature/tests"))))

(defsystem "aion/signature/tests"
  :description "Tests for aion/signature -- mostly the ways it must fail."
  :depends-on ("aion/signature" "fiveam")
  :serial t
  :components ((:module "tests/signature"
                :serial t
                :components ((:file "packages")
                             (:file "signature-tests"))))
  :perform (test-op (op c) (uiop:symbol-call :aion/signature/tests :run-tests)))

(defsystem "aion/platform"
  :description "The platform key that names a build artifact -- <os>-<arch> -- and the set of platforms this project actually builds (pre-publication issue 206, pre-publication issue 145)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  ;; NO DEPENDENCIES, deliberately: only UIOP, which arrives with ASDF. That is what lets
  ;; scripts/build-desktop-app.lisp load this before Quicklisp exists in its image, so the
  ;; producer of an artifact name and the consumer of one share an implementation rather
  ;; than a resemblance.
  :depends-on ()
  :serial t
  :components ((:module "src/platform"
                :serial t
                :components ((:file "packages")
                             (:file "platform"))))
  :in-order-to ((test-op (test-op "aion/platform/tests"))))

(defsystem "aion/platform/tests"
  :description "Tests for aion/platform -- the spelling table, checked across platforms this machine is not."
  :depends-on ("aion/platform" "fiveam")
  :serial t
  :components ((:module "tests/platform"
                :serial t
                :components ((:file "packages")
                             (:file "platform-tests"))))
  :perform (test-op (op c) (uiop:symbol-call :aion/platform/tests :run-tests)))

(defsystem "aion/clock"
  :description "A monotonic Gregorian-100ns clock and time-ordered, sortable RFC-9562 v6 identities built on it."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  ;; aion/random for the 62 non-timestamp bits of a v6 id (pre-publication issue 95). This is the one dependency
  ;; aion/clock has, and it is not free: mnemosyne and hermes both depend on aion/clock, so
  ;; ironclad now loads with them. The cost is LOAD TIME ONLY -- ironclad is pure Common Lisp
  ;; (SBCL contribs + bordeaux-threads, no CFFI, no native library), so unlike the cl+ssl
  ;; case this changes nothing about deployability or bundling.
  :depends-on ("aion/random")
  :serial t
  :components ((:module "src/clock"
                :serial t
                :components ((:file "packages")
                             (:file "clock"))))
  :in-order-to ((test-op (test-op "aion/clock/tests"))))

(defsystem "aion/test-threads"
  :description "Test support: wait for a thread a test started, with a deadline that fails the test by name."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  ;; No dependencies: sb-thread ships with SBCL. Used by the test systems of aion, hyperion
  ;; and praxeon (#178); aion is the one framework all of them may depend on.
  :components ((:file "tests/test-threads")))

(defsystem "aion/clock/tests"
  :description "Tests for aion/clock: id shape, strict monotonicity under concurrency, and v6 lexical sort order."
  :depends-on ("aion/clock" "fiveam" "aion/test-threads")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "clock"))))
  :perform (test-op (o c) (uiop:symbol-call :aion/clock/tests :run-tests)))

;;; aion/log --- a backend-neutral logging facade over log4cl. A separate opt-in system so
;;; core aion stays dependency-light (coalton + alexandria); consumers that want logging
;;; depend on aion/log. log4cl is the engine (gating, per-category levels, runtime control,
;;; SLIME); jzon renders the JSON layout for staging/prod stdout.
(defsystem "aion/random"
  :description "A cryptographically secure random source -- session ids, tokens, nonces (pre-publication issue 95)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  ;; ironclad for the OS PRNG (/dev/urandom, CryptGenRandom), bordeaux-threads for the
  ;; one lock around lazy creation. An AUX system, not part of aion core, for the same
  ;; reason mnemosyne refuses cl+ssl: nothing that merely uses aion should get a crypto
  ;; library on its load path. Anything minting a secret asks for this explicitly.
  :depends-on ("ironclad" "bordeaux-threads")
  :serial t
  :components ((:module "src/random"
                :serial t
                :components ((:file "packages")
                             (:file "random"))))
  :in-order-to ((test-op (test-op "aion/random/tests"))))

(defsystem "aion/random/tests"
  :description "Tests for aion/random: shape, range, uniqueness, and no modulo bias."
  :depends-on ("aion/random" "fiveam")
  :serial t
  :components ((:module "tests/random"
                :serial t
                :components ((:file "random-tests"))))
  :perform (test-op (o c) (uiop:symbol-call :aion/random/tests :run-tests)))

(defsystem "aion/dynamic"
  :description "Dynamic bindings that should survive a thread boundary (#158)."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  :serial t
  :components ((:module "src/dynamic"
                :serial t
                :components ((:file "packages")
                             (:file "dynamic")))))

(defsystem "aion/log"
  :description "Neutral leveled + structured logging over log4cl: pretty for dev, one-line JSON to stdout for staging/prod."
  :author "Bob <eternal.recursion@proton.me>"
  :license "MIT"
  :version "0.0.0"
  :depends-on ("coalton" "log4cl" "com.inuoe.jzon" "aion/dynamic")
  :serial t
  :components ((:module "src/log"
                :serial t
                :components ((:file "packages")
                             (:file "types")    ; Level/Layout/Event (Coalton, pure)
                             (:file "log"))))
  :in-order-to ((test-op (test-op "aion/log/tests"))))

(defsystem "aion/log/tests"
  :description "Tests for aion/log (rendering, context, level gating)."
  :depends-on ("aion/log" "fiveam")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "log"))))
  :perform (test-op (o c) (uiop:symbol-call :aion/log/tests :run-tests)))

(defsystem "aion/dynamic/tests"
  :description "Tests for aion/dynamic, and the tree-wide thread-spawn sweep (#158)."
  :depends-on ("aion/dynamic" "aion/log" "fiveam" "aion/test-threads")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "dynamic"))))
  :perform (test-op (o c) (uiop:symbol-call :aion/dynamic/tests :run-tests)))

(defsystem "aion/tests"
  :description "Umbrella test suite for Aion: runs every aion sub-suite."
  :depends-on ("aion" "aion/csv/tests" "aion/csv/types/tests" "aion/clock/tests"
               "aion/log/tests" "fiveam")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "all"))))
  :perform (test-op (o c) (uiop:symbol-call :aion/tests :run-tests)))
