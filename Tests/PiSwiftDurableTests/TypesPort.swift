/*
# Upstream type tests

Source: `v1.1.0:packages/durable/test/types.test.ts`.

1. Numeric brands: the runtime JSON assertion is in `upstreamRuntimeTypes`.
   Swift phantom kinds keep conversation, entry, task, submission, and document IDs separate.
   `Seq` is a separate type. The TaskId result phantom is N/A by the work-order decision.
2. Discriminator fields: the runtime values are in `upstreamRuntimeTypes` and the
   upstream fixture. Swift enums require the fields of each selected state. The
   TypeScript `expectTypeOf` assertions and `@ts-expect-error` declarations are
   compile-time-only and are N/A as runtime tests. SubmissionCreate is a Session
   input type for D4, and is N/A in D1.
3. Submissions, task waits, compaction, and extension erasure: all assertions are
   TypeScript type assertions. The case does not execute a task or harness call.
   SubmissionDraft, task definitions, hooks, extensions, waits, and compaction
   are outside D1. These parts are N/A until their respective orders.
*/
