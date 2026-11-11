# Watch fixtures

Run these commands with Node 22:

```sh
node Scripts/chord-fixtures/generate-watch-fixtures.mjs
node Scripts/chord-fixtures/generate-watch-fixtures.mjs --check
```

Set `PI_MONO_ROOT` if the upstream Git repository is not at
`/Users/miguel/cvs/pi/pi-mono`. The script reads `v1.5.2` from Git. It does not
load source from the upstream work tree. It copies the full watch, context,
delta, and telemetry dependencies to a temporary directory. It removes that
directory when the script ends. The script does not change the source.

The output is `Tests/PiSwiftChordTests/Fixtures/watch-v152-fixtures.json`.
The script checks the shared decimal 3.5 MB fixture limit before it writes.
`--check` runs the oracle again and compares all output bytes. It does not
write the fixture. Each case is on one line, as in the tracker fixtures.

## Data format

The root object has `upstream`, `source`, `seed`, `counts`, and `cases`.
The fixed xorshift32 seed is `0x7a15c032`. There are 327 cases: 320 seeded
cases and seven cases for specified limits and lifecycle conditions.

Each case has these fields:

- `name` and `category`: case labels.
- `kind`: `json` or `native`.
- `initial`: the acquisition value.
- `replacement`, if present: the value returned by the native overflow callback.
- `steps`: the input operations, in order.
- `events`: one observation per input operation.

Each event has `step` (a zero-based input index) and `value` (the handle value).
The other fields are omitted when empty:

- `calls`: calls that started during this step. Each has `call` (the upstream
  call data), `context` (the source frame label), and `abortRemoved` (whether
  the listener context has no abort signal).
- `detached`: the total number of detach calls, when greater than zero.
- `reports`: all reported listener errors, as message strings.
- `closed`: the terminal result, after its promise has resolved. It has `kind`
  and, for a failure or listener error, `error` as a string.
- `error`: an error thrown by this input operation, as a message string.

An absent `calls` or `reports` means an empty array. An absent `detached` means
zero. An absent `closed` means that its promise has not resolved at this step.
A source failure string stays a string. A listener throws an `Error`; the
fixture records its message.

## Input operations

- `advance`: sends `value`, with `context` as its frame label (default `frame`).
  JSON frames also use `ops` (default empty) and `retired` (default false).
- `burst`: sends `count` frames without a yield. Frame `i` has value
  `{"n":from+i}` and the specified `context`. For JSON, its ops are
  `[["s",["n"],from+i]]`, or `[["t",["n"],1]]` if `increment` is true.
  `retiredAt`, if present, is the one zero-based frame with `retired: true`.
- `fail`: sends the `error` string with the `context` frame label.
- `start`: installs a listener. If `block` is true, its first call waits for
  `release`. If `throw` is present, each call throws that error message after
  the gate, if any, opens.
- `release`: opens the listener gate, if one exists.
- `flush`: waits for one event-loop turn with `setImmediate`. All ready promise
  jobs run. A listener held at a gate stays blocked.
- `stop`: awaits the terminal result returned by `stop()`.
- `abort`: directly aborts the watch.
- `observeAbort`: installs the case's abort controller. If `aborted` is true,
  the script aborts that controller before it installs it.
- `cancel`: aborts the case's controller.
- `endAfterDelivery`: requests a source end after the remaining calls return.
- `end`: ends at once, with `kind`. Only `failed` and `listener_error`
  can have an `error` field.

All source frame contexts contain the same case controller and a separate
label. The listener must retain the newest applicable label and remove the
abort signal. Only `flush` and `stop` yield between input operations. Thus an
empty `calls` field on `start` also checks that no listener runs inline.

## Scope

The cases cover JSON folding, native frame order, source failures and recovery,
retirement, busy listeners, deferred source end, cancellation, listener errors,
start errors, terminal precedence, native overflow, and JSON operation overflow.
They use explicit gates and no elapsed-time assumptions.

These fixtures use JSON-compatible native values. They do not test native
function or object identity, memory retention, telemetry spans, or every
possible task schedule. Error stacks and platform error types are not part of
the comparison. A replay needs separate checks for Swift task isolation and
for schedules that the explicit gates do not represent.
