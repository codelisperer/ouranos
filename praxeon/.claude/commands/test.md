---
description: Load and run the Praxeon fiveam test suite (network-free).
---
Run the Praxeon test suite and report results.

Prefer a running REPL if one is attached; otherwise run from the shell:

```sh
sbcl --non-interactive \
     --eval '(ql:quickload :praxeon/tests)' \
     --eval '(uiop:quit (if (fiveam:run! (quote praxeon/tests:praxeon)) 0 1))'
```

Summarize failures with the offending test name and the `is` form that failed.
Do not touch the network; these tests must stay hermetic.
