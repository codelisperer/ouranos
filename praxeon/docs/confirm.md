# Holding a call until the user confirms it

A means can require the user's confirmation before it runs (#531, part of #64). It matters most for tools the framework did not write and for tools that spend money: an MCP server's tools, or a paid API. The shape follows the OpenAI Agents SDK:
- A tool says it needs approval.
- The run stops with the call held, and the app stores what it needs.
- The app continues the run later with the user's decision.

LangGraph's `interrupt()` re-runs the interrupted node when it resumes, which a Praxeon turn must never do: a call that may have run is never run again (#527).

## Marking a means

```lisp
(actor:register-means agent "order" "Places an order" #'place-order
                      :confirm (lambda (args) (list :credits (estimate-credits args))))
```

`:confirm` is one of:
- **NIL**, the default, which runs the means as always.
- **T**, which holds every call.
- **A function of the arguments**, which holds every call and returns an estimate plist to show the user.
  - An estimate's values may be strings, integers, floats, `T` or NIL.
  - An estimate function that signals, or returns anything else (a ratio included), means the call is not run. It runs on arguments the model wrote.

`praxeon/mcp:grant-tools` takes `:confirm`, a list of the server's tool names to hold, or `:all`. Any other value, or a name that is not among the granted tools, signals an error and registers nothing, because a misspelt name would let the tool it meant run without confirmation. A tool's `readOnlyHint` or `destructiveHint` annotation is untrusted and never decides this; the app does.

## What a turn does with a held call

`run-turn :on-hold` is the app's policy. When it is not given, a turn uses the enclosing turn's (see Delegated turns below).

| `:on-hold` | What happens |
|---|---|
| NIL (default) | No confirmation is available. The call is not run, and the model is told so. `workflow`, praxeon/web's chat, `studio` and `converse-repl` pass no `:on-hold`, so a held means is never run through them. |
| a function | It is called on the turn's thread with a plist describing the call (`:principal :agent :name :source :arguments :estimate`) and returns `:approve`, `:decline` or `:hold`. A REPL or a desktop app can ask the user here and wait. |
| `:hold` | The turn ends: `run-turn` returns `(values nil :held held-turn)`. A server-rendered app uses this, stores the held turn, and asks the user. |

- **No principal, no hold.** A turn with no principal cannot hold a call, because there is no user to ask. The call is not run, and a blocking function is not called.
- **The other calls in the same model response** run at once, before the turn ends. Their results are kept in the held turn and are not run again. For an agent that keeps results outside the prompt (#319), what is kept is the stand-in the history would carry.
- **Several held calls** in one response are held together, in one held turn.
- **Delegated turns.**
  - A blocking function passes down to a sub-agent's turn (`register-agent-as-means`), so the same user is asked.
  - `:hold` does not pass down, and neither does a blocking function's `:hold` answer inside the sub-turn. A sub-agent's hold cannot end the coordinator's turn, so there it counts as no confirmation available.
- **`run-turn-through`** takes `:on-hold`, `:held` and `:claim`. When the turn holds, its second value is `:held` and its third the held turn.

## Storing and continuing

- **Storing.** `held-turn-to-json` gives the held turn as JSON text, and `held-turn-from-json` reads it back. Store the text as it is; it never goes through the Lisp reader.
  - A call's arguments are written as the JSON object the model sent.
  - An estimate's and a source's keys are written as lower-case names. An integer or a float is a JSON number and reads back as an integer or a double-float; `T` is `true` and NIL is `false`.
  - The principal must be a string or an integer.
  - The conversation itself is the agent's history, which the app keeps as it does now.
  - The app may set `held-turn-expires-at`, a universal time.
- **Continuing.** `(actor:continue-turn agent held decision :principal p :permit permit :on-hold on-hold :claim claim)` continues the turn.
  - `decision` is `:approve` or `:decline` for every held call, or an alist `((tool-call-id . decision) ...)` with one entry per held call.
  - It returns `run-turn`'s values, `(values nil :held held-turn)` again if a later call holds, or `(values nil :already-decided decision)`.

`continue-turn` checks, in order:
1. **Principal:** it is the one the calls were held for. If not, it signals `wrong-principal` and changes nothing.
2. **Agent:** it is the one that held them, by name (`held-turn-mismatch`).
3. **History:** the agent's history has the model message that holds these calls.
   - If a result follows it for every held call, the turn was decided before, and `:already-decided` is returned with the decision the claim recorded.
   - If the message is missing, it signals `held-turn-mismatch`.
4. **Calls:** the held turn's calls are the model message's calls, in the model's order and once each, and each held call names the means the model message names. Otherwise it signals `held-turn-mismatch`, because the held turn decides which means runs and the order in which results are written.
5. **Arguments:** the arguments that run are the ones in the history, which the model wrote. If the held turn's copy, which is what the user was shown, differs, it signals `held-turn-mismatch`.

Then it records the decision through the claim, and runs what was approved:
- **The claim.** `:claim` is the app's function of the held turn's id and the decision. It records the decision as one step, returns true the first time, and after that returns NIL and the decision recorded first. For a database it is `UPDATE … SET decision = ? WHERE id = ? AND decision IS NULL`.
  - Without `:claim`, a table in this process is used, which covers one process only and keeps one entry per held turn for the life of the process. An app with several processes, a long-running server, or an app that must survive a crash between running a call and saving the history, supplies `:claim`.
- **A refused claim** means another request decided first. The results that the recorded decision calls for are written, and nothing runs:
  - an approval gives "the tool may have run; its outcome is unknown", with outcome `:unknown`, because it may have run before the history was saved;
  - a decline gives "the user declined";
  - an unanswered or expired turn gives that.
- **Expiry.** A held turn past its `expires-at` is declined, as "not run: the user did not confirm in time".
- **The last step.** If the call was held on the turn's last step (`:max-steps`), the decided calls run and the turn then signals `deliberation-failure`, as an ordinary turn does after its last step. The model is not asked again.
- **A changed means.** An approved call whose means is no longer registered with the same `:source`, for example after `revoke-tools`, is not run. The two sources are compared as they come back from JSON, so a keyword or a list in a source does not make a stored held turn's call look changed.

## When the user moves on

When the history ends with held calls that have no results, `run-turn` needs the held turn, as `:held`, or an earlier `(actor:abandon-held-turn agent held :principal p :claim claim)`. Without either, it signals `held-turn-required`, naming the held call ids, and writes nothing.

With the held turn, it records `:unanswered` through the claim, and writes the other calls' real results and "not run: the user did not confirm" for the held ones, before the new message. An approval that arrives later finds the claim taken and runs nothing.

- When the claim was already taken, the results the recorded decision calls for are written instead, and `abandon-held-turn` returns `(values nil :already-decided decision)`.
- When the held turn passed is not the one the history ends with, for example an older one that was already answered, nothing is written and `run-turn` signals `held-turn-required`.

## When a means fails in the same step

When a failure leaves the step, the turn first writes a result for every call of the step (#546), and the failure wins over a hold. This happens when nothing handles the failure, and also when the app handles it outside the turn, for example with a `handler-case` around `run-turn`, because that handler unwinds through the step. Only a handler that takes one of `act`'s restarts (`substitute-result`, `abandon-action`, `retry-action`) keeps the step going, and then nothing extra is written. The results are added to the history before their events are emitted and before they are kept in the result store, so an observer or a store that fails, even on every call, does not leave the history incomplete. A call whose `:tool-result` event was already emitted, or whose not-run text was already decided, keeps that text in the history, or its stand-in when the result store already offloaded it, and gets no second event. Each call therefore has one `:tool-call` and one `:tool-result` event.
- `run-turn` signals the failure and returns no held turn.
- A call held earlier in the step gets "Not run: the turn ended before this call was run." and a `:tool-decided` event with decision `:turn-failed`. Nothing is recorded through the claim, because the held turn never reached the app.
- The next `run-turn` needs no `:held`.

When an approved call fails inside `continue-turn`, it is written as may-have-run. A held call that ran nothing, such as a declined one, keeps the text its decision calls for, even when the failure came while its result was being written. An approved call that `act` refused because `continue-turn`'s permit no longer allows it is written as "Not run: no such tool is available." An approved held call after it is written as not run, with a `:tool-decided` event whose decision is `:turn-failed`, and a declined one keeps the declined text, with its own `:tool-decided` event. The history is complete, so the next `run-turn` needs no `:held`, and a later `continue-turn` for that held turn returns `:already-decided`.

## Events

- `:tool-held` is emitted when a call is held. It carries:
  - the tool-call `:id`, as `:tool-call` and `:tool-result` do, and the held turn's id as `:held`;
  - `:principal`, `:agent` and `:conversation`;
  - the means `:name`, its `:source` and the `:estimate`;
  - `:at`, a universal time.
- `:tool-decided` is emitted when a decision is applied, once per call. It carries the same fields, plus `:decision`, one of `:approve`, `:decline`, `:expired`, `:unanswered`, `:no-confirmation`, `:may-have-run` or `:turn-failed`. For a call decided on the spot, by a blocking function or because the turn has no principal, `:held` is NIL.

The held call's `:tool-result` event follows. Its outcome is `:not-run`, or `:unknown` for a call that may have run, unless the call was approved and ran. A result that was not run is sent to the model as an error result. These events let an app keep an audit trail of what its users approved, beside the usage fields of #527.

## MCP tools after a refused token

A tool granted with `:confirm` is not sent again after the server refuses its token. The token is still refreshed for the next call, and this call fails as not run, telling the model that the server refused the call before running it and that the user can ask again. This is the rule recorded on #531 for #539. Every other refused request is still sent once more after a refresh.
