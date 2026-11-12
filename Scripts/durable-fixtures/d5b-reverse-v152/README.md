These files test the Swift to TypeScript direction at v1.5.2.

Run `node Scripts/durable-fixtures/generate-d5b-reverse-v152.mjs --check` from the package directory. The command runs the Swift export test, makes a source mirror of the unmodified tag, and resumes each fresh Swift file. It also resumes each saved pre-event file. Run the command without `--check` to replace these fixtures after all comparisons pass.

Each of the six cases has a compressed SQLite file (`pre.sqlite.gz`) and a JSONL directory (`pre`). The driver expands each SQLite file into a temporary file before it opens it:

- `continue`: A real model error ends the first run. The second host submits `continue` and gets an answer.
- `turn-limit`: A real tool round reaches the one-turn limit. The second host submits `continue` and gets an answer.
- `model-error-retry`: A real model error saves a sleeping retry checkpoint. The second host opens the file at the retry deadline and gets an answer.
- `host-death-request`: Swift saves a running request checkpoint and a committed partial. The second host charges the interrupted attempt. Retry is off. The partial becomes an aborted assistant entry.
- `interrupted-poll`: Swift saves a running poll checkpoint and a deferred handle. The second host charges the interrupted fetch, cancels the handle, and ends the run. Retry is off.
- `handoff`: Swift saves a placed input and a pending prepare checkpoint. The second host runs a tool, writes the handoff reset, and answers in the same run.

The request and poll images represent host death. The test writes their running states after it closes the first harness. The handoff image starts before the first request, so the tagged host must perform the complete handoff flow.

The manifest stores Swift's pre-event records, its own final records, and its final submission. The tagged runtime must produce the same final records and submission. The record comparison covers the root conversation, all tasks, all submissions, all entries, all root documents, and each current document value. It checks that each scan fits in one page. All final tasks must be terminal.

The fixture fixes wall time and monotonic time. Thus model and tool durations remain exact.

The comparison replaces only provider session UUIDs and ephemeral faux assistant API identifiers. It removes a null optional tool result `details` field to match the TypeScript absent field. It does not remove IDs, timestamps, document versions, usage, task states, submission states, or run failure details.

The handoff uses the existing D5b `fresh-16` input. This input avoids a known difference between the Swift test model and tagged faux provider when they round cache-write token counts after a changed prompt prefix.
