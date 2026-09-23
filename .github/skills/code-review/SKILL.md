---
name: code-review
description: How to review a change in the Ouranos monorepo — what to verify rather than read, and the specific defect shapes this codebase produces. Use when reviewing a pull request, a branch, or a working diff here.
---

# Reviewing a change in Ouranos

The house rule is **green is not evidence**. A review that reads the diff and finds it
plausible has done the easy half. The half that has caught every real defect here is
checking whether the *claims* hold and whether the *tests could fail*.

Work in this order. Steps 1–3 have each caught a shipped bug; step 4 is the reading.

## 1. Verify the author's factual claims

Authors are competent and claims still decay. Two of the last four reviews here contained
a wrong one — a proposal citing a comment that had been superseded, inventing a blocker
that no longer existed; and "this symbol appears in exactly three files" when it was five.

If the description says *X appears only in these files*, or *this is unused*, or *the
upstream still requires Y* — check it. `grep`, `git log`, read the dependency. A wrong
premise usually means the design was chosen for a reason that no longer applies.

## 2. Ask whether the tests could fail

For each new test: **if the feature were broken, would this test notice?**

The canonical failure here: a handler returned `(list bytes)` — a list containing an octet
vector, which is not a valid response body — and the test asserted `(first (third res))`
equalled the bytes. It asserted the shape the implementation produced rather than the
contract it had to satisfy, so it locked the defect in. Every vendored asset served empty,
two demo apps were dead in a browser, and the suite was green throughout.

Specific things to distrust:

- A test written against the implementation's shape rather than the consumer's contract.
- **A module tested only by itself.** If the code that builds a value is the code that
  checks it, the test agrees with itself and proves nothing. Something must cross the real
  boundary — a socket, a file, a second process.
- A skipped test that reports success without announcing the skip.
- Asserting a header, a length, or a return code instead of the payload.
- New tests with no `:perform (test-op …)`. A suite that cannot be run reports success —
  this repo shipped an entire framework green while executing zero checks.

## 3. Confirm what actually ran

- Was the gate run on the **merged** state, or only on the branch?
- Did it **compile the file that changed**? Coverage of the checker matters as much as the
  checker: `scripts/verify-tree.lisp` only exercises the systems listed in `+systems+` and
  `+test-systems+`, so new systems must be added there in the same commit.
- **Interrogate the check count.** It is printed for a reason. If it moved by an amount the
  diff does not explain, find out why before merging — a merge once carried an unrelated
  feature into `main` and the only visible sign was +361 checks where ~100 were expected.
- Coalton changes need a **cold, unmuffled** build. Warm fasls hide warnings, and a warning
  is a build failure here.

## 4. Read for the shapes this codebase produces

- **Platform-conditional code.** `#+sbcl` is TRUE on Windows — guarding a POSIX-only symbol
  with it makes the file fail to READ there. Use `#+(and sbcl unix)`. Path separators
  differ (`:` vs `;`; a colon on Windows is a drive letter).
- **Silent degradation.** Any default or fallback that quietly gives less than was asked
  for — TLS off by omission, a lenient decode swallowing a malformed value, a permissive
  path. A loud error beats a quiet wrong answer.
- **DAG violations.** A framework never depends on one to its right; `hermes` depends only
  on `aion`. A new `:depends-on` can be a defect even when it compiles.
- **Undeclared dependencies.** New ones must be in `docs/dependencies.md` or
  `scripts/check-deps.lisp` fails. Ask whether an existing dependency already covers it.
- **Unescaped quotes in docstrings** — twice now — and `FORMAT` `~<newline>` continuations,
  which are illegal on a CRLF checkout.
- **A client or app name** anywhere in code, comments, docs, or a commit message.

## 5. Say what you verified

State what you checked and how, not just the verdict. "Confirmed against the branch" and
"reproduced in both directions" are the parts a later reader can rely on; "looks good" is
not. If a finding is a judgement call rather than a defect, say which.

When rejecting, give the reason and the smallest change that fixes it. When the author's
analysis is better than the reviewer's, say so plainly — that has happened here more than
once and it is worth recording.
