# Codemode v1.3.0 test inventory

Source: `/Users/miguel/cvs/pi/pi-mono`, tag `v1.3.0` (`71023aec1546d6d677a65669c5665c0927ce0dd0`). Read with `git show`; do not change the upstream tree.

This is the test plan. “Applicable” requires a Swift test or a recorded gap in the task report. It does not mean that the test has passed. “N/A engine” applies only to the stated engine behavior. A fake sandbox cannot verify JavaScript execution.

There are 68 test declarations: 40 durable, 7 models, 5 describe, and 16 deterministic. The first 14 deterministic declarations run for both worker and remote backends, for 82 upstream test instances.

The frozen `codemode-v130.json` document fixture uses the exact upstream `CodemodeRunDoc`, `CodemodeJournalDoc`, and `CodemodeStoreDoc` definitions. It runs Session commits, records storage writes and four snapshots, and checks a store fork at an earlier entry. Its payloads are constructed host records; it does not execute a sandbox.

## v1.4.0 fixture evidence

The tables below keep the v1.3.0 test inventory and line numbers. They do not claim to list all v1.4.0 tests.

`generate-codemode-fixtures.mjs` now reads tag v1.4.0 and writes `codemode-v140.json`. It uses the exact tagged document definitions, Session and MemoryStorage. The original four snapshots, commits and fork values are equal to the frozen v1.3.0 fixture. The payloads are constructed host records; no JavaScript sandbox runs.

The added `checkpointEvidence` follows v1.4.0 `packages/durable/test/codemode-checkpoints.test.ts:14`. It records 64 deltas at counter 64, a base at counter 65 with zero deltas, the historical and fork counter 32, and one delta at counter 66. The policy is in `packages/durable/src/codemode/codemode.ts:170`. The run and journal policies at lines 130 and 156 return false. `D4CurrentFixtureTests.codemodeBaseKeepsHistoricalAndForkValues` replays and reads these exact storage records. Native Swift policy selection has a separate test in the D4 source fix; storage replay alone does not prove policy selection.

## packages/durable/test/codemode.test.ts

| Line | Upstream case | Plan and reason | Swift test |
| --- | --- | --- | --- |
| 193 | runs a script that calls tools as nested calls, and journals each result before delivering it | Applicable: durable replay and scheduler test with a fake sandbox. | CodemodeDurableTests.nestedCallsAreJournaledAndFinishedCallsDoNotRunAgain; failedJournalCommitPreventsDelivery |
| 207 | resumes a script after a restart without running its finished calls again | Applicable: durable replay and scheduler test with a fake sandbox. | CodemodeDurableTests.nestedCallsAreJournaledAndFinishedCallsDoNotRunAgain |
| 224 | replays results in the order they arrived, not the order the calls were made | Applicable: durable replay and scheduler test with a fake sandbox. | CodemodeDurableTests.parallelResultsReplayInArrivalOrder |
| 240 | journals globals with their results and hands a replay the recorded ones | Applicable: durable replay and scheduler test with a fake sandbox. | CodemodeDurableTests.globalsReplayRecordedValuesIncludingUndefined(false) |
| 254 | keeps the script's clock and randomness across a restart | Applicable: preserve start clock and seed across replay. N/A engine: actual Date, performance, and RNG values require JavaScript execution. | CodemodeDurableTests.startClockSeedStoreAndDeclarationsRemainFixed |
| 269 | ends the call when a resumed script made a different number of calls than before | Applicable: durable replay and scheduler test with a fake sandbox. | CodemodeDurableTests.detectsJournalDivergence(count) |
| 286 | ends the call at once when a resumed script waits without making a call it made before | Applicable: durable replay and scheduler test with a fake sandbox. | CodemodeDurableTests.detectsJournalDivergence(missing) |
| 305 | ends the call when a resumed script calls a global with other arguments | Applicable: durable replay and scheduler test with a fake sandbox. | CodemodeDurableTests.detectsJournalDivergence(globalArgs) |
| 318 | admits no call of a diverging replay, even one the script never made before | Applicable: durable replay and scheduler test with a fake sandbox. | CodemodeDurableTests.rejectsAddedCallsAndEarlyCompletion(extra) |
| 347 | ends the call when a resumed script ends where it went on before | Applicable: durable replay and scheduler test with a fake sandbox. | CodemodeDurableTests.rejectsAddedCallsAndEarlyCompletion(early) |
| 370 | ends the call when a resumed script ends before calls the live run made, even without a recorded count | Applicable: durable replay and scheduler test with a fake sandbox. | CodemodeDurableTests.rejectsAddedCallsAndEarlyCompletion(earlyNoAck) |
| 390 | ends the call when a resumed script makes a call an earlier attempt admitted with other arguments | Applicable: durable replay and scheduler test with a fake sandbox. | CodemodeDurableTests.noJournalRerunChecksArgumentsAndFirstCount(false) |
| 412 | records a count the live run never recorded as soon as a replay acknowledges it | Applicable: durable replay and scheduler test with a fake sandbox. | CodemodeDurableTests.missingReplayCountIsRecordedAtOnce |
| 441 | lists the script's tool calls in its result's details | Applicable: durable replay and scheduler test with a fake sandbox. | CodemodeDurableTests.detailsIncludeFailedAndCancelledCalls |
| 467 | stores no outcome when the host closes the sandbox, and replays the script after a restart | Applicable: durable replay and scheduler test with a fake sandbox. | CodemodeDurableTests.hostSandboxCloseLeavesNoOutcomeAndCanReplay |
| 497 | aborts a call still running when the script ends | Applicable: durable replay and scheduler test with a fake sandbox. | CodemodeDurableTests.detailsIncludeFailedAndCancelledCalls |
| 515 | admits no call once the script has ended, even one it made before ending | Applicable: durable replay and scheduler test with a fake sandbox. | CodemodeDurableTests.terminalDrainAdmitsNoFireAndForgetCall |
| 533 | checks a rerun's calls against an earlier attempt's before admitting any later call | Applicable: durable replay and scheduler test with a fake sandbox. | CodemodeDurableTests.noJournalRerunChecksArgumentsAndFirstCount(true) |
| 559 | ends the call when a rerun makes a global call where an earlier attempt made a tool call | Applicable: durable replay and scheduler test with a fake sandbox. | CodemodeDurableTests.heldRerunCallsAreCheckedBeforeRelease(target) |
| 577 | ends the call when a rerun's first run makes fewer calls than an earlier attempt admitted | Applicable: durable replay and scheduler test with a fake sandbox. | CodemodeDurableTests.heldRerunCallsAreCheckedBeforeRelease(fewer) |
| 605 | ends the call when a rerun without journal entries ends in its first run, where it went on before | Applicable: durable replay and scheduler test with a fake sandbox. | CodemodeDurableTests.heldRerunCallsAreCheckedBeforeRelease(early) |
| 625 | checks every call a rerun holds before launching any of them | Applicable: durable replay and scheduler test with a fake sandbox. | CodemodeDurableTests.heldRerunCallsAreCheckedBeforeRelease(all) |
| 656 | keeps a global's undefined result undefined, live and replayed | Applicable: durable replay and scheduler test with a fake sandbox. | CodemodeDurableTests.globalsReplayRecordedValuesIncludingUndefined(true) |
| 666 | rejects a failed tool call with its error text and structured output | Applicable: durable replay and scheduler test with a fake sandbox. | CodemodeDurableTests.nestedResultMapping(plainError) |
| 686 | resolves a schema tool's error result that carries its value, and rejects one without with its text | Applicable: durable replay and scheduler test with a fake sandbox. | CodemodeDurableTests.nestedResultMapping(structuredError, missingStructured) |
| 732 | resolves a schema-less tool with its text, as its declaration says, also when it returned images | Applicable: durable replay and scheduler test with a fake sandbox. | CodemodeDurableTests.nestedResultMapping(images) |
| 760 | delivers a result only after its journal commit | Applicable: durable replay and scheduler test with a fake sandbox. | CodemodeDurableTests.failedJournalCommitPreventsDelivery |
| 791 | refuses to resume when the sandbox's fingerprint or the code mode version changed | Applicable: durable replay and scheduler test with a fake sandbox. | CodemodeDurableTests.incompatibleOrExpiredStartsAdmitNoNewCalls(fingerprint, version) |
| 812 | times a script out across a restart, without admitting new calls | Applicable: durable replay and scheduler test with a fake sandbox. | CodemodeDurableTests.incompatibleOrExpiredStartsAdmitNoNewCalls(deadline) |
| 827 | returns a decided outcome after a restart without running the script again | Applicable: durable replay and scheduler test with a fake sandbox. | CodemodeDurableTests.decidedOutcomeIsReturnedAfterRestartWithoutStartingSandbox |
| 857 | keeps store() values per conversation, as of a fork's entry | Applicable: conversation store and asOf fork test; also covered at the document boundary by codemode-v130.json. | CodemodeDurableTests.storeWritesAreAtomicAndForksUseEntryValues; CodemodeFixtureTests.upstreamDocumentCommitsKeepJournalOrderAndForkValues |
| 882 | journals results that finish together in one commit | Applicable: durable replay and scheduler test with a fake sandbox. | CodemodeDurableTests.concurrentGlobalResultsUseBatchedJournalCommits |
| 936 | lays out text items, console lines, and the returned value under a header | Applicable: host output, discovery, or result test with a fake sandbox. | CodemodeOutputTests.textConsoleAndReturnLayout |
| 943 | cuts text past the token budget to its start and end, with the full text in a file | Applicable: host output, discovery, or result test with a fake sandbox. | CodemodeOutputTests.tokenBudgetSpillsHeadAndTail |
| 956 | keeps a result inside the tool's output limits whatever max_output_tokens says, spilling the rest | Applicable: host output, discovery, or result test with a fake sandbox. | CodemodeOutputTests.byteAndLineLimitsSpillWithinHarnessLimits |
| 975 | writes the result's files to the same paths when it reruns after a crash | Applicable: host output, discovery, or result test with a fake sandbox. | CodemodeOutputRestartTests.outputFilePathStaysTheSameAfterRestart |
| 1009 | saves images to files and names them next to the image | Applicable: host output, discovery, or result test with a fake sandbox. | CodemodeOutputTests.savesImagesWithAdjacentPathsAndDeduplicatesBytes |
| 1018 | calls a deferred tool the model is not offered, and finds it in ALL_TOOLS | Applicable: host output, discovery, or result test with a fake sandbox. | CodemodeOutputTests.deferredToolRemainsCallableAndInCatalog |
| 1037 | reports a failed script with its error and the calls already made | Applicable: host output, discovery, or result test with a fake sandbox. | CodemodeOutputTests.failureShowsPriorCalls |
| 1045 | finds tools with searchTools(), describeTool(), and describeNamespace(), and lists them in ALL_TOOLS | Applicable: host output, discovery, or result test with a fake sandbox. | CodemodeOutputTests.discoveryUsesTheSavedCatalog |

## packages/durable/test/codemode-models.test.ts

| Line | Upstream case | Plan and reason | Swift test |
| --- | --- | --- | --- |
| 143 | reads the model catalog without credentials in headers | Applicable: model catalog, internal tool, result, or concurrency test with a fake sandbox and model provider. | CodemodeModelTests.catalogStripsCredentialHeaders |
| 155 | classifies through an internal tool: a nested call with its usage, hidden from tools and listings | Applicable: model catalog, internal tool, result, or concurrency test with a fake sandbox and model provider. | CodemodeModelTests.internalNestedClassifierUsageAndHiddenListings |
| 177 | resolves a model call that failed with its result, as the coding agent does | Applicable: model catalog, internal tool, result, or concurrency test with a fake sandbox and model provider. | CodemodeModelTests.failedModelResolvesItsProgramResult |
| 195 | rejects a bad classifier context with the expected shape, before any request | Applicable: model catalog, internal tool, result, or concurrency test with a fake sandbox and model provider. | CodemodeModelTests.badClassifierContextStopsBeforeRequest |
| 207 | runs at most four model calls at once | Applicable: model catalog, internal tool, result, or concurrency test with a fake sandbox and model provider. | CodemodeModelTests.atMostFourModelsInFlight |
| 222 | does not start a model call that waited for a slot after the script ended | Applicable: model catalog, internal tool, result, or concurrency test with a fake sandbox and model provider. | CodemodeModelTests.queuedModelsDoNotStartAfterOutcome |
| 253 | notes generated images the script did not show | Applicable: model catalog, internal tool, result, or concurrency test with a fake sandbox and model provider. | CodemodeModelTests.generatedImagesNoteAndShownImages |

## packages/durable/test/codemode-describe.test.ts

| Line | Upstream case | Plan and reason | Swift test |
| --- | --- | --- | --- |
| 24 | keeps the tool description the same for every conversation | Applicable: description, namespace, budget, or prompt-section test. No engine is needed. | CodemodeDescribeTests.fixedDescription |
| 33 | lists callable tools as declarations, grouped by namespace, with namespace descriptions | Applicable: description, namespace, budget, or prompt-section test. No engine is needed. | CodemodeDescribeTests.namespaceDeclarations |
| 48 | lists what fits the budget, every namespace before any is complete, and says what is left out | Applicable: description, namespace, budget, or prompt-section test. No engine is needed. | CodemodeDescribeTests.budgetRoundsAndOmissions |
| 58 | uses the longest matching namespace prefix | Applicable: description, namespace, budget, or prompt-section test. No engine is needed. | CodemodeDescribeTests.longestPrefix |
| 68 | renders the section from the conversation's callable tools into the system prompt | Applicable: description, namespace, budget, or prompt-section test. No engine is needed. | CodemodeDescribeTests.callablePromptSectionAndGrammar |

## packages/codemode/test/deterministic.test.ts

| Line | Upstream case | Plan and reason | Swift test |
| --- | --- | --- | --- |
| 108 | makes the same calls and output for the same start, seed, and results | Applicable: preserve start data and replay deliveries. N/A engine: Date, performance, seeded Math.random, pinned RNG values, and JavaScript output equality require a VM. | CodemodeSandboxProtocolTests.repeatablePlan; CodemodeFixtureTests.typedStartAndJournalReplayTheUpstreamDocumentValues (host contract only) |
| 148 | runs in UTC whatever the host's timezone, and without WeakRef or FinalizationRegistry | N/A engine: UTC Date behavior and the presence of WeakRef and FinalizationRegistry are JavaScript runtime behavior. | N/A engine |
| 159 | applies results in seq order, whatever order they are delivered in | Applicable: protocol behavior with a fake sandbox. N/A engine: execution of the source string in each actual backend. | CodemodeSandboxProtocolTests.orderedDelivery |
| 180 | reports the fingerprint before any call and the calls issued after each result | Applicable: started/call/idle event order and issued counts. N/A engine: QuickJS/prelude/heap/interrupt-budget fingerprint contents and VM configuration sensitivity. | CodemodeSandboxProtocolTests.fingerprintAndBatches, callbackDelivery |
| 209 | numbers calls to globals with tools, and answers errors as rejections | Applicable: protocol behavior with a fake sandbox. N/A engine: execution of the source string in each actual backend. | CodemodeSandboxProtocolTests.globalsAndErrorProperties |
| 236 | keeps the clock monotonic and rejects a clock value that is not finite | Applicable: reject a non-finite delivery clock at the protocol boundary. N/A engine: Date/performance monotonic clock values inside JavaScript. | CodemodeSandboxProtocolTests.clockAndJSONBoundary |
| 249 | reports the result the VM was processing when the script ended | Applicable: protocol behavior with a fake sandbox. N/A engine: execution of the source string in each actual backend. | CodemodeSandboxProtocolTests.capturesStart, scriptFailureDuring |
| 263 | leaves a call waiting when its answer cannot be serialized | Applicable: invalid JSON delivery must not consume a waiting call. Swift JSONValue cannot contain JavaScript BigInt; use non-finite JSON numbers to test the JSON boundary. | CodemodeSandboxProtocolTests.clockAndJSONBoundary, outcomeCoding |
| 275 | rejects with an Error carrying the answer's properties | Applicable: retain error properties in the outcome. N/A engine: JavaScript Error identity and reserved name/message property behavior. | CodemodeSandboxProtocolTests.globalsAndErrorProperties, outcomeCoding |
| 291 | rejects rejection properties that are not an object, and tools sharing a script name | Applicable: object-only rejection properties and duplicate script-name validation. Swift outcome properties use an object type; reject invalid JSON at decoding. | CodemodeSandboxProtocolTests.declarationValidation, outcomeCoding |
| 312 | uses the script names the run passes | Applicable: preserve explicit jsName and host tool name in start data. N/A engine: the tools object and ALL_TOOLS bindings inside JavaScript. | CodemodeSandboxProtocolTests.capturesStart |
| 327 | ends with an error the script cannot catch when the caller aborts | Applicable: caller cancellation, aborted result, and no further delivery. N/A engine: a JavaScript catch block cannot intercept host cancellation. | CodemodeSandboxProtocolTests.abort |
| 343 | is finished once it has its outcome | Applicable: protocol behavior with a fake sandbox. N/A engine: execution of the source string in each actual backend. | CodemodeSandboxProtocolTests.abort |
| 353 | rejects a call that is not waiting and a result number used twice | Applicable: protocol behavior with a fake sandbox. N/A engine: execution of the source string in each actual backend. | CodemodeSandboxProtocolTests.invalidDelivery |
| 369 | applies results in seq order when the transport reorders replies sent in order | Applicable: seq ordering at the protocol boundary. N/A engine: worker/remote RPC reply reordering requires the omitted remote transport implementation. | CodemodeSandboxProtocolTests.orderedDelivery (host sequence ordering only) |
| 386 | reads the real clock and real randomness | N/A engine: nondeterministic execute() uses the actual JavaScript clock and randomness; the Swift protocol does not execute source. | N/A engine |

## Fixture provenance and commands

```sh
node Scripts/durable-fixtures/generate-codemode-fixtures.mjs
node Scripts/durable-fixtures/generate-codemode-fixtures.mjs --check
```

The frozen v1.3.0 fixture was generated with `mirror.mjs`. That historical run read exact tag files with `git archive v1.3.0`; extracts them under `/tmp`; installs `typebox@1.3.27` and `quickjs-wasi@3.6.2` there with npm scripts disabled; and imports the unmodified source with Node type stripping. Package manifests and links exist only in the temporary mirror. The generator removes the mirror when it ends. That historical run wrote `Tests/PiSwiftDurableTests/Fixtures/codemode-v130.json` in this repository. The current generator uses v1.4.0 as stated above.

Read-only inventory command for each source path:

```sh
git -C /Users/miguel/cvs/pi/pi-mono show v1.3.0:<source-path>
```

## Swift protocol test map

`Tests/PiSwiftDurableTests/CodemodeSandboxProtocolTests.swift` has these protocol checks. They use a fake sandbox and do not verify an engine.

| Swift test | Upstream deterministic lines | Scope |
| --- | --- | --- | --- |
| orderedDelivery | 159, 369 | Sequence order at the host boundary; no remote RPC implementation. |
| fingerprintAndBatches | 180 | Fingerprint event order and issued counts; no engine fingerprint format. |
| globalsAndErrorProperties | 209, 275 | Shared call IDs and error property records; no JavaScript Error identity. |
| clockAndJSONBoundary | 236, 263 | Finite delivery clock and invalid JSON that leaves a call waiting. |
| invalidDelivery | 353 | Unknown call and repeated or zero sequence numbers. |
| abort | 327, 343 | Abort outcome, finished state, and delivery after the outcome. |
| capturesStart, scriptFailureDuring | 249, 312 | Explicit script names and success/failure during metadata as host records. |
| declarationValidation, outcomeCoding | 291 | Duplicate script names; JSON decoding rejects non-object rejection property shapes. |
| callbackDelivery | 180 | Callback delivery from the run handle. |
| repeatablePlan | 108 | Repeatability contract for a fixed plan; no actual clock or random sequence. |
| outcomeCoding | 263, 275, 291 | Exact outcome JSON; undefined and null differ; invalid property shapes fail decoding. |
| startTimeValidation | Extra boundary test | Negative/non-finite start time and maximum UInt32 seed. |
| toolNameIdentity | Extra boundary test | Tool and script names retain their Unicode scalar identity. |
| close | Extra lifecycle test | Host close aborts a run; future starts remain available. |

## P5 proof boundary

`CodemodeFixtureTests.documentDefinitionsMatchTheUpstreamTag` checks kind, version, scope, history, fork policy, and initial values. `upstreamDocumentCommitsKeepJournalOrderAndForkValues` decodes and replays all real upstream StorageWrite batches, checks four run/journal/store states, and reads the final state and historical store fork with public document tokens. `typedStartAndJournalReplayTheUpstreamDocumentValues` decodes every saved start and journal into the production typed records and checks exact JSON round trips. It starts the fake with the decoded declarations, clock, seed, and store; delivers journal records in sequence order (call IDs 2, 1, 3); checks the recorded issued counts; then continues with call 4 as live work.

The recorded global results include JavaScript undefined (no value member), error text, and own JSON properties. The fixture does not contain NestedCallDoc results. The fake test supplies a constructed tool result for call 1 and a constructed live result for call 4. The fixture does not prove JavaScript source execution, engine RNG values, Date behavior, engine fingerprint compatibility, or real engine replay. The durable restart suite must separately prove keyed nested task attachment and the journal-before-delivery scheduler.
