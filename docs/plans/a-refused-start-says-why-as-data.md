# Plan: a refused start says why as data

> **Status:** 📋 Planned, 2026-11-21. Nothing built yet.
>
> **Questions and short answers:**
>
> 1. *What is wrong today?* **When the platform refuses to start, the reason is only a sentence.**
>    The DCB build knows which component, which slice, the key an `@partitionTag` names and the
>    key inference derives, but it puts them into a message and throws a plain error
>    ([§2](#2-what-happens-today)). A caller of `check-start` gets one line of text on stderr; a
>    program that wants to explain the refusal, or offer a fix, has to read the sentence back.
> 2. *What changes?* **A refusal to start becomes a typed value with a code and its fields, made
>    where it is found, carried by the error it throws, and printed as JSON by `check-start
>    --json`.** The message stays as it is, made from the same value
>    ([§4](#4-steps)).
> 3. *Which refusals?* **The DCB partition and scope contradictions first, with the start refusals
>    that are already their own checks (a store in use, roles nothing honours) after them**
>    ([RTS1](#4-steps) to [RTS4](#4-steps)).
> 4. *What does it not change?* **The exit codes, the messages people read, and the logger's
>    records**, which gain the refusal as their detail ([RTQ4](#3-decisions)).
>
> **Relates to:** [a-refusal-nobody-hears.md](a-refusal-nobody-hears.md), which made a command's
> refusal something a slice records; this plan does the same for the platform's own refusal to
> start.
>
> **Ids:** `RTQ` (refused to start, question) for the decisions in [§3](#3-decisions), `RTS`
> (step) for the steps in [§4](#4-steps).

---

## 1. In plain words

Before a platform runs, its DCB build checks the app: each `@partitionTag` must agree with what
inference derives from the slice graph, and each boundary's scope must hold. When a check fails,
the platform does not start, and it says why in a sentence such as:

> DCB partition contradiction (Relationships): MoveContact: @partitionTag names contactId, but
> inference derives partyId from the slice graph — contactId is read from another entity. Remove
> the annotation, or move it to partyId.

A person reads that well. A program does not: an editor that wants to mark the annotation, a CI
step that wants to group failures, or any tool that wants to say the refusal in its own words has
to take the sentence apart with a regular expression, and breaks the day the sentence is
reworded. Every value in that sentence was a variable in the build a moment before it was written.

## 2. What happens today

- **Where it is found.** [`DcbValidation.validatePartitionHintsVsInference`](../../reventless/spec/src/components/DcbValidation.res)
  returns `validationError = {sliceName, message}`. The hint (the key the annotation names) and
  the inferred key are local variables where the message is made, for each of its kinds: a hint
  inference contradicts, and a hint that decides a partition its writers do not use.
- **Where it stops the start.** [`Dcb_Builder`](../../reventless/core/src/components/Dcb/Dcb_Builder.res)
  joins the contradictions as `slice: message | …` and throws
  `DCB partition contradiction (<component>): …` with `JsError.throwWithMessage`. A scope
  contradiction (`validateCrossPartitionArms`) throws the same way, and `deriveBoundaryPartition`
  throws when a slice has no partition key.
- **Other refusals.** A reset over a store in use (`LocalPlatformStart.refusalMessage`) and roles
  that nothing honours (`AdmissionCheck`) refuse with their own sentences.
- **Who hears it.** [`LocalCheckStart`](../../reventless/local/src/LocalCheckStart.res) catches the
  error, takes its message, prints `check-start: the app would not start: <message>` on stderr,
  and exits 1. A real start ends with the uncaught error. The logger writes the message as its
  record's `message`, and nothing more.

There is no error type, no code, and no JSON form.

## 3. Decisions

Proposed, each with its reason.

| # | Question | Decision |
|---|---|---|
| **RTQ1** | Where does the type live? | In `spec`, beside `DcbValidation`, as `StartRefusal`: the validators make it, and both the platform and `check-start` read it without a new dependency. |
| **RTQ2** | How does the value reach `check-start`, across the dynamic import of the app's `Main`? | On the error it throws: a `JsError` that carries the refusal in a property of its own (`refusal`), read back by `StartRefusal.ofError`. A ReScript exception would not survive every way the app is loaded; a property on the error does. |
| **RTQ3** | What is a code? | A stable kebab-case word per kind: `partition-contradiction`, `partition-unreachable`, `scope-contradiction`, `no-partition-key`, `store-in-use`, `roles-unhonoured`. A new kind adds a code; a code is never reused for another meaning. |
| **RTQ4** | Does anything people read change? | No. The message is made from the value, word for word as today, so logs and terminals read the same; the logger's record carries the refusal as its `detail`. |
| **RTQ5** | Does `check-start` change its contract? | It gains `--json`: one JSON object on stdout, `{"starts": true}` or `{"starts": false, "refusal": {…}}`, a refusal it cannot type as `{"code": "unknown", "message": …}`. The exit codes stay 0 and 1. |

## 4. Steps

**RTS1 The validators return refusals.** `validationError` gains a typed `refusal`:
`PartitionContradiction({slice, field, named, derived, arms})` and
`PartitionUnreachable({slice, named, missed})`, the message made from it. The scope check and
`deriveBoundaryPartition` do the same (`ScopeContradiction`, `NoPartitionKey`).
*Done when* each kind's message is made from its value and the validators' tests assert the
values, not the sentences.

**RTS2 The build throws the refusal.** `Dcb_Builder` throws `StartRefusal.error(refusals,
~component)`: the same message, the refusals in its `refusal` property.
*Done when* a test of the build reads the refusal back from the error with `ofError`.

**RTS3 `check-start --json`.** `LocalCheckStart` reads the refusal from the error it catches, and
with `--json` prints it as [RTQ5](#3-decisions) says; without it, the line it prints today.
*Done when* a test starts an app with a contradicting annotation and reads the code, the
component, the slice and both keys from stdout.

**RTS4 The other start refusals.** A store in use and roles nothing honours refuse with
`StartRefusal` too, under their codes.
*Done when* `check-start --json` reports each with its code.

**RTS5 The logger's record.** The error log the build writes carries the refusal as its `detail`,
so a JSON log line says it as data.
*Done when* a JSON-format log of a refused start holds the refusal in `detail`.

## 5. Open questions

None that blocks [RTS1](#4-steps). Whether the platform's other errors (an adapter that cannot
reach its store, a schema that does not load) should become refusals with codes too is left for
when one is needed. **Recommendation:** leave them; a start refusal is about the app as written,
those are about the machine it runs on.
