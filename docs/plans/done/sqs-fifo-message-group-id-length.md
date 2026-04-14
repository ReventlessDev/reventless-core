# Plan: SQS FIFO MessageGroupId Length Cap

## Problem

SQS FIFO queues reject `MessageGroupId` values longer than 128 characters:

```
Value <composite-key> for parameter MessageGroupId is invalid.
Reason: MessageGroupId can only include alphanumeric and punctuation characters. 1 to 128 in length.
```

The framework uses the composite partition key (derived from `@compositePartitionTag`
fields) directly as `MessageGroupId`. With many composite fields or long field values,
the key easily exceeds 128 characters. Example — 5 composite fields:

```
componentName:DcbEventLog#environment:alpha#platformName:online-shop-platform-aws#pluginName:Catalog#resourceName:CatalogDcbEventLog-428c0a8
→ 141 characters
```

## Fix

Add a `safeGroupId` helper to `Util_SQS_Runtime.res` that passes the id through
unchanged when it is ≤ 128 chars, and returns its SHA-256 hex digest (64 chars) when
it is longer. Apply it at the three call sites that set `MessageGroupId`/`groupId`.

**Why SHA-256 and not truncation:**
Truncation can make two different keys map to the same prefix → same FIFO group →
unnecessary serialisation and potential head-of-line blocking. SHA-256 hex (64 chars)
has negligible collision probability for the cardinalities involved.

**Why only at the SQS/SNS dispatch layer and not at the id derivation:**
`commandJson.id` is the canonical composite partition key used by DcbEventLog for
event storage and retrieval. Altering it would break the storage lookup. Only the
SQS routing parameter needs to be capped; the id in the message body and in DcbEventLog
stays as-is.

---

## Step 1 — Add `safeGroupId` to `Util_SQS_Runtime.res`

**File:** `reventless/reventless-aws/src/util/Util_SQS_Runtime.res`

```rescript
// Node.js crypto — available in all Lambda runtimes.
@module("node:crypto") external _createHash: string => 'h = "createHash"
@send external _update: ('h, string) => 'h = "update"
@send external _digest: ('h, string) => string = "digest"

/** Returns `id` unchanged if ≤ 128 chars; otherwise its SHA-256 hex digest (64 chars).
    SQS FIFO MessageGroupId is limited to 128 characters. Using a hash instead of
    truncation avoids false-grouping of distinct keys that share a long prefix. */
let safeGroupId = (id: string): string =>
  if id->String.length <= 128 {
    id
  } else {
    _createHash("sha256")->_update(id)->_digest("hex")
  }
```

---

## Step 2 — Apply `safeGroupId` in `Util_SQS_Runtime.res`

**File:** `reventless/reventless-aws/src/util/Util_SQS_Runtime.res`

Two call sites in this file:

```rescript
// send (line ~29) — before:
~messageGroupId=commandJson.id,

// send — after:
~messageGroupId=safeGroupId(commandJson.id),

// makeEntry (line ~51) — before:
SQS_Helpers.makeBatchEntryFifo(~groupId=id, ...)

// makeEntry — after:
SQS_Helpers.makeBatchEntryFifo(~groupId=safeGroupId(id), ...)
```

---

## Step 3 — Apply `safeGroupId` in `EventCollectorChannel_SQS_Runtime.res`

**File:** `reventless/reventless-aws/src/adapter/EventCollector/EventCollectorChannel_SQS_Runtime.res`

```rescript
// before (line ~85):
queue->Util_SQS_Runtime.sendFifoMessage(~delay, ~messageGroupId=id, messageBody)

// after:
queue->Util_SQS_Runtime.sendFifoMessage(~delay, ~messageGroupId=Util_SQS_Runtime.safeGroupId(id), messageBody)
```

---

## Step 4 — Apply `safeGroupId` in `EventTopicPublisher_SNS_Runtime.res`

**File:** `reventless/reventless-aws/src/adapter/EventTopic/EventTopicPublisher_SNS_Runtime.res`

SNS FIFO topics share the same 128-char limit for `MessageGroupId`.

```rescript
// before (line ~5):
topic->Util_SNS_Runtime.publishFifo(~messageGroupId=id, ~message=json->JSON.stringify)

// after:
topic->Util_SNS_Runtime.publishFifo(~messageGroupId=Util_SQS_Runtime.safeGroupId(id), ~message=json->JSON.stringify)
```

Alternatively, add the same `safeGroupId` helper directly to `Util_SNS_Runtime.res`
and use it locally — either approach is fine.

---

## Step 5 — Build

```sh
npm run build
```

Expected: clean build. No call-site signatures change; `safeGroupId` is a pure
string-to-string function.

---

## Step 6 — Deploy and verify

After deploying any stack with a StateChangeSlice whose composite key exceeds 128
characters, confirm:

- No `MessageGroupId is invalid` errors from SQS/SNS
- Commands are processed correctly by the command topic Lambda
- DcbEventLog receives events under the full (unhashed) composite key

---

## Checklist

- [ ] Step 1: Add `safeGroupId` to `Util_SQS_Runtime.res`
- [ ] Step 2: Apply at both call sites in `Util_SQS_Runtime.res` (`send`, `makeEntry`)
- [ ] Step 3: Apply in `EventCollectorChannel_SQS_Runtime.res`
- [ ] Step 4: Apply in `EventTopicPublisher_SNS_Runtime.res`
- [ ] Step 5: Build passes
- [ ] Step 6: Deploy — no MessageGroupId errors, events land correctly
