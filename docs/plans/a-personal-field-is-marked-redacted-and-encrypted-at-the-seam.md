# Plan: a personal field is marked, redacted, and encrypted at the seam

**Date:** 2026-10-25<br/>
**Status:** In progress. [PD1](#pd1-the-formats-written-down), [PD3](#pd3-the-envelope),
[PD4](#pd4-an-uploads-path-carries-nothing-a-person-typed), [PD5](#pd5-the-registration-ledgers-address-id)
and [PD2](#pd2-the-recording-pii) built 2026-10-29; PD1 revised the
[Design](#design) on one point, below. Steps [PD1](#steps) to [PD10](#steps) in two halves: the
first six decide formats and stop the plaintext copies, and come before any deployment holds a real
person's data; the last four close the seam so that an installed codec provider encrypts every
personal field on every transport. Code claims refer to `94466bb9c` unless a step says otherwise.<br/>
**Repos:** `reventless-core` only. `packages/reventless-ppx` (the attribute and its checks),
`reventless/spec` (the wrapper type, the provider seam, the schema marker), `reventless/core`
(the envelope, the loggers, encode-once, the caches, the append), `reventless/aws` (the presign
service, the dead-letter dump, AppSync logging, the resolver templates), `rescript/node` (the
bindings), `reventless/registration` (the address id), `reventless/conformance` (the scenario).<br/>
**Found by:** [the event-format review](../analysis/event-format-and-meta-review.md), which lists a
missing marker for personal data and proposes making `ip` and `user` optional; and the registration
ledger, whose [`ContactAddressId`](../../reventless/registration/src/Registration/ContactAddressId.res)
is the lower-cased address itself, used as tag and partition.<br/>
**Reads after:** [the identity plan](./identity-is-a-capability-not-a-cognito-handle.md)
(*the stable subject id;
[Step 2 built 2026-10-22](./identity-is-a-capability-not-a-cognito-handle.md#built-2026-10-22--the-claim-the-store-behind-it-and-minting-at-creation)*) ·
[the offload plan](./done/plugin-aggregate-event-payload-offload.md) (*the template: a field
annotation that installs a codec*) ·
[the owner plans](./done/owner-scoped-identity-and-reads.md) and
[their AppSync gaps](./done/owner-enforcement-gaps-on-appsync.md) (*the template for enforcement,
and the two per-transport defects the scenario of [PD10](#steps) replays*) ·
[the conformance kit](./conformance-test-kit.md) (*where the scenario lives*) ·
[the versioning backlog](./Backlog/sury-event-schema-versioning.md) (*an upcast must run on the
decrypted value*).

## In plain words

Some fields are about a person: a name, an email, a photo. An event log keeps them forever, and a
log line keeps them for a year. This plan gives the framework one word for such a field, `@pii`, and
makes four things follow from the word without any further code in the app. The compiler refuses the
word where it would do harm: on a tag, which cannot be encrypted, and on a read model, where a codec
would run locally and silently not on AWS. Every log line prints a placeholder instead of the value.
The field's type gains two more cases, *erased* and *forgotten*, so code that reads it must say
what it does when the value is gone. And the schema's codec for the field asks a provider; the one
the framework ships keeps the value plain, and a deployment may install one that encrypts, in which
case the framework encrypts each event once, refuses to store an event whose personal field is not
in the encrypted form, and forgets decoded state within minutes. Beside the word, three formats are
fixed now because they cannot be fixed later: the caller's IP address leaves domain events, an
upload's path carries no file name, and the registration ledger tags by a fingerprint of the address
instead of the address.

## What is there

- **Thirty-six attributes** in [`Vocabulary.ml`](../../packages/reventless-ppx/src/ppx/Vocabulary.ml),
  among them `sensitive`, inferred by `SensitiveInference.ml`, and `offload`, whose
  [`OffloadInference.ml`](../../packages/reventless-ppx/src/ppx/OffloadInference.ml) rewrites a
  field's type into `Offload.payload<'a>` and injects a sury codec with `@s.matches`; it stops the
  build when it cannot derive the inner schema. `@owner`'s
  [`OwnerInference.ml`](../../packages/reventless-ppx/src/ppx/OwnerInference.ml) marks the subject
  field a row or command belongs to.
- **`@sensitive`** in [`Sensitive.res`](../../reventless/spec/src/components/Sensitive.res) keeps a
  value out of rendered messages and lists it in the JSON schema; `impliedBySemantic` already implies
  it for `email` and `phone`. No logger reads it.
- **The envelope** in [`Message.res`](../../reventless/core/src/Message.res): `generateMeta` takes
  `~ip=?` and `~user=?`, `deriveMeta` hands both to every event and follow-up message, and the
  AppSync templates in
  [`AppSync_Resolver_Functions.res`](../../rescript/pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res)
  write `ip: id?.sourceIp`. So every event a signed-in user causes carries their IP address, flattened
  into a top-level DynamoDB attribute by `metaKeys`.
- **Two loggers, no redaction.** [`Logger.res`](../../reventless/core/src/util/Logger.res) and
  [`EffectLogger.res`](../../reventless/core/src/util/EffectLogger.res) format through
  [`LogFormat.res`](../../reventless/core/src/util/LogFormat.res) and put whole payloads in a
  `detail` field, truncated at 512 characters. Every command and event is logged in full at info by
  the aggregate, the DCB decision, the command generator, the topics, read models, state views,
  event mappers and side-effect handlers. [`Util_Sury.exnMessage`](../../reventless/spec/src/util/Util_Sury.res)
  passes a decode error that repeats the received value; a failed command decode in
  [`CommandTopic_Callback.res`](../../reventless/core/src/components/CommandTopic/CommandTopic_Callback.res)
  adds the raw JSON. [`Util_DeadLetterQueue.res`](../../reventless/aws/src/util/Util_DeadLetterQueue.res)
  prints the whole record with `console.error`. [`AppSync_Adapter.res`](../../reventless/aws/src/components/Api/AppSync_Adapter.res)
  logs at `ERROR` without `excludeVerboseContent`. [`Util_LogRetention.res`](../../reventless/aws/src/util/Util_LogRetention.res)
  keeps production logs 365 days.
- **The aggregate encodes an event three to five times**, for storage, two log lines, the owner
  check and the SNS publish ([`Aggregate_Callback.res`](../../reventless/core/src/components/Aggregate/Aggregate_Callback.res));
  the DCB path in [`DcbEventLog_Operations.res`](../../reventless/core/src/components/DcbEventLog/DcbEventLog_Operations.res)
  encodes once. The aggregate's replay cache and the DCB projection cache in
  [`StateChangeSlice_Callback.res`](../../reventless/core/src/components/StateChangeSlice/StateChangeSlice_Callback.res)
  hold 100 decoded entries with no time limit.
- **The deployed projection Lambdas** in
  [`StateViewSliceEntryPoint_Ops.res`](../../reventless/aws/src/adapter/Runtime/StateViewSliceEntryPoint_Ops.res)
  write what `project` returns without passing it through the read model's schema; the local path does
  pass it through.
- **Upload keys** are `{servedPrefix}/{sub}/{uuid}/{fileName}`
  ([`Upload_Presign_S3_Ops.res`](../../reventless/aws/src/adapter/Upload/Upload_Presign_S3_Ops.res)),
  where `fileName` is what the client sent and `sub` is the uploader.
- **The registration ledger's events** in
  [`Registrations.res`](../../reventless/registration/src/Registration/StateChange/Registrations.res)
  carry `email: ContactAddressId.t`, and the id's value is the address, lower-cased, which is the
  DCB tag that makes "this address is taken" one fact on every platform.
- **Crypto bindings** in [`NodeCrypto.res`](../../rescript/node/src/NodeCrypto.res) cover hashing,
  HMAC and random bytes. No AES-GCM, no KMS client.
- **A stable subject id**: the identity plan's Step 2 mints a domain id at creation and carries it as
  a token claim, built 2026-10-22 and not yet deployed.

## Design

**The word installs a codec; it never wraps an adapter.** Three read paths reach storage without a
ReScript adapter: AppSync resolvers read DynamoDB directly, Postgres queries compile the tag query to
SQL in the database, and subscriptions forward the stored image. A decorator around the event-log
operations would decrypt on one path and not on the others. So `@pii` follows `@offload`: the PPX
rewrites the field's type and injects a codec at the schema, and ciphertext is what is stored, on
every path, by construction.

**The codec reads; a provider seals and opens around it.** *Revised in [PD1](#pd1-the-formats-written-down),
2026-10-29.* The plan first had the field codec consult the provider. That cannot work: a sury
codec is synchronous and sees one field, while an encrypting provider fetches keys from a store,
which is asynchronous, and files a value under its subject, which is a sibling field. So the work
is split, in [`Pii.res`](../../reventless/spec/src/components/Pii.res):

- **The field codec**, `Pii.schema(inner)`, is synchronous, declarative and knows no provider. It
  reads a plain value as `Value`, and the two markers a provider leaves for a value that is gone as
  `Erased` and `Forgotten`. A stored form it was handed unopened does not decode.
- **The provider**, `Pii.Provider.current`, installed once per process, runs at the event log's
  seam on the whole encoded payload: `seal` before an append, `open_` after a read, both async,
  each given the field's subject read off the payload. The framework ships the plain provider,
  which stores values as they are. A deployment may install one that encrypts.

This is still the schema's seam and not an adapter decorator: the pass walks the event's schema for
its marked fields, and it runs in the event log's operations, which every runtime and both stores go
through. A path that skips it is loud on both sides: the append refusal of [PD9](#pd9-the-caches-expire-and-the-append-refuses)
on the way in, the field codec on the way out.

```rescript
type provider = {
  name: string,
  encrypts: bool,
  seal: (~subject: string, ~field: string, ~forgettable: bool, JSON.t) => promise<result<JSON.t, Pii.error>>,
  open_: (~field: string, JSON.t) => promise<result<JSON.t, Pii.error>>,
  release: (~subject: string, ~ref: string) => promise<result<unit, Pii.error>>,
}
```

**The stored forms sit under one reserved key.** The three forms are `enc:v1:<keyId>:<alg>:<base64>`,
`erased:v1` and `ref:v1:<ref>`, each stored as `{"$pii": "<form>"}`, as `@offload` stores under
`$offload`. A bare string form would be ambiguous: a person may well be called `erased:v1`, and the
plain provider stores names as they are. No ReScript record field encodes to a key starting with `$`,
so under the sentinel a plain value of any type cannot be taken for a form. An opened value is the
plain value, or `{"$pii": "erased:v1"}`, or `{"$pii": "forgotten:v1"}`. The decoder never fails on
the last two. Without a key id a value could never be re-keyed; without a version never migrated.

**A provider is installed per platform, and its keys are platform resources.** A subject's fields are
written by several plugins, and whatever a provider keeps about a subject must be reachable from every
plugin stack's containers, as the identity store is. So the provider is configured once on the
platform stack, every plugin runtime installs the same one at start, and a store the provider needs
is created by the platform stack and read by the plugins. A plugin is not a trust boundary here; a
tenant is, and a provider may key its material per tenant where tenancy is installed. A plugin
deployed in another region reads across the border, which the manifest allows and the provider has to
accept.

**The field's type says what the app must handle.** `@pii name: string` becomes
`name: Pii.t<string>` with `Pii.t<'a> = Value('a) | Erased | Forgotten`, as `@offload` becomes
`Offload.payload<'a>`. The compiler then lists every place that reads a personal field, which is
few: decisions work on ids and states, and projections copy the value through. Generated read models,
forms and GraphQL types unwrap at the seam; if that proves awkward in the first app, only events carry
the wrapper and the unwrapping moves to the projection, which is the one fallback this plan names
([open question 1](#open-questions)).

**On an event the word encrypts; on a command it marks; on a read model it is refused.** A command
is never stored, its handler needs the plain value, the value arrived in plain text over the API, and a
queued command lives for days at most: ciphertext there protects nothing and costs a key fetch per
command. So on a command the annotation only redacts, and the type stays plain. On a read-model type
the PPX refuses it, because the deployed projection path bypasses the schema and the codec would run
locally and not on AWS. Read models hold plaintext and are removed on erasure by a tombstone the app
appends; that is the app's job, and the rule is written down.

**A subject is anything with a lifetime of its own.** `@pii` takes `subject=field`, defaulting to the
`@owner` field, and the PPX refuses a field with neither. An invitation is its own subject, so its
values can expire with it; a help request is written under its author.

**A field whose value lives in a store is forgotten, not encrypted.** On `UploadableImage.t`,
`UploadableFile.t`, `@storageRef` and `@offload`, the event holds a reference and the personal data is
the object. The codec hands the reference to the provider's `release` on erasure instead of encrypting
the path; `@pii` on an `@offload` field means a store per subject, never deduplicated, because
content addressing shares one object between two people and hashes are an oracle over the content.
The path itself must carry nothing a person typed, which is [PD4](#steps).

**It fails at build time and at write time, never at read time.** The PPX stops the build on the four
refusals. The append refuses an event whose schema marks `@pii` when a provider other than the plain
one is installed and a marked field is not in a stored form: a call site that handed the codec the
wrong schema, or a key that could not be fetched, becomes a failed write, never plaintext in the log.
At read time a field whose key is gone decodes to `Erased`.

**A log never holds a personal value, plain or encrypted.** `LogFormat` and the `detail` field
format a payload through its schema and print `«pii»` for a `@pii` or `@sensitive` field, with no
length and no hash. Ciphertext is excluded too: it helps nobody debug, it is still personal data until
the key is gone, and a log beside a key-table backup gives the value back.

**`@pii` implies `@sensitive`, never the reverse.** A personal value leaking into a message is worse
than a masked value somebody must unmask, and a reset token is sensitive without being anybody's
personal data. The implication is one rule in the shape `impliedBySemantic` has. The two stay
separate attributes: while `@pii` only records they look identical, and a merged marker would let a
personal field become a tag.

**The ledger tags by a fingerprint.** The registration ledger needs a deterministic tag from the
address, so an opaque id with a registry does not serve it. `ContactAddressId.t` becomes an HMAC of
the lower-cased address under a key the deployment holds and never rotates; the address itself moves
into a `@pii` field of the events, so the sender translation can still address the message. The
caveats are accepted for this one type: addresses are enumerable, so a leaked key re-identifies
them, and the tags stay linkable to each other. Every other type keeps the rule that a tag is an
opaque id.

## Steps

Numbered PD1 to PD10. **PD** stands for *personal data*. The first six freeze formats and stop the
plaintext copies, and come first; the last four close the seam for an installed provider.

### PD1: the formats, written down

The three stored forms, the provider signature, the spelling (`@pii`, `@pii(subject=field)`; the
forgettable form follows the field's type and takes no argument), and two reserved optional meta
keys, a data-class marker and a key reference, declared in the schema and written by nobody yet. The
two claims this plan rests on, full-payload logging at info and `meta.ip` on every event, are
re-checked against the current commit before the note is final.

**Exit:** this section's [Design](#design) is the note; the envelope's schema declares the two keys
as optional; the GWT that pins the envelope's keys lists them.

**Built 2026-10-29.** [`Pii.res`](../../reventless/spec/src/components/Pii.res) holds the type, the
three stored forms with their printer and parser, the field codec, the provider type and the plain
provider; [`PiiTest`](../../reventless/spec/tests/PiiTest.res) pins the spellings, that a plain
string reading `erased:v1` stays a value, and that an unopened form does not decode. The envelope
declares `dataClass` and `keyRef` as optional, and `metaKeys` lists them. The two claims hold at
`0fa525a`: every command and event is logged in full at info, and `meta.ip` was on every event a
user caused until [PD3](#pd3-the-envelope). The design changed in one place, the provider's
signature; the [Design](#design) says why.

### PD2: the recording `@pii`

A new attribute in the vocabulary with a `PiiInference.ml` beside `OffloadInference.ml`. On an event
field it rewrites the type to `Pii.t<'a>` and injects `Pii.schema` with `@s.matches`, plus the marker the seal and open pass reads (the subject field, and whether the value is forgettable); on a command field
it records only. It refuses: a read-model type; a tag or partition-key field, including a member of a
`@compositePartitionTag`; a field with no `subject` and no `@owner` field to default to; a type whose
inner codec it cannot derive. It implies `@sensitive`. A build check warns when a command field has the
name and type of a `@pii` event field and no marker. The JSON schema lists the marker and the subject
field, so a tool can read the inventory. The plain provider ships with it.

**Exit:** a relationship test in the shape the owner rollout left: a codec built for a type whose
spec marks `@pii` finds those fields, with the permissive case pinned beside it. Each refusal has a
failing fixture. The template test proves a `@pii` field is withheld from a rendered message. The
examples that carry an email in an event mark it, and still run.

**Built 2026-10-29**, but for the warning. `PiiInference.ml` runs after the DCB-tag passes and before
`OwnerInference`. On an event field it rewrites `T` to `Reventless.Pii.t<T>` with
`Reventless.Pii.marked(~subject, ~forgettable?, <schema>)`; on a command field it keeps the type and
adds `Reventless.Pii.mark`. Both imply `@sensitive`, and `SuryToJsonSchema` writes
`x-reventless-pii: {subject, forgettable}`. The spelling is `@pii({subject: "memberId"})` or
`@pii("memberId")`, since a ReScript attribute payload is an expression and `subject=field` is not one.
It refuses a `state`, a tag or partition key, the `@owner` field, a missing or unknown subject, a type
it cannot name, and a field of any other type; each has a failing fixture in the PPX suite.
[`PiiPpxTest`](../../reventless/core/tests/pii/PiiPpxTest.res) is the relationship test. The ledger's
`address` is marked, with the registration as its subject (`@pii({subject: "email"})`), and a
translation writes to nobody when it reads `Erased`. **Not built:** the warning on a command field that
looks like a `@pii` event field and has no marker. It needs a warning that does not fail the
zero-warning build, and is left for the tools' personal-data card, which sees the whole app.

### PD3: the envelope

The AppSync templates stop writing `ip` into the command, `deriveMeta` stops inheriting it, and the
request's source IP is handed to the inspector's history slice as part of the request's record, where
it has a retention of its own. `meta.user` stays the opaque id. The envelope is logged without `ip`
and `headers`. Core's own event-format review proposed making both optional; this step makes `ip`
absent from domain events.

**Exit:** on the local platform and on an AWS stack, an event a signed-in user caused carries
`meta.user` and no `meta.ip`; a grep finds no reader of `meta.ip` outside the request record.

**Built 2026-10-29** (`aa9e8c7`, breaking: `generateMeta` takes no `~ip`). The AppSync command
templates send no `ip`, the generator copies none, `deriveMeta` and `deriveStableMeta` inherit none,
and nothing writes `ip: ""` any more; the key stays readable for messages written before. Two parts
are open: the address is not yet handed to the inspector's history slice (open question 3), and the
AWS half of the exit waits for a deployment with working credentials.

### PD4: an upload's path carries nothing a person typed

The presign service mints `{servedPrefix}/{sub}/{uuid}.{ext}`, the extension from the declared
content type, and never from the file name and never a content hash. The original name, when an app
wants it, is set as the object's `Content-Disposition` at signing, and the client sends exactly that
header because it is part of the signature. The uploadable types' documentation says so.

**Exit:** the presign GWT asserts the shape; an upload with a personal file name leaves it in no
event and no log line; a download keeps its name through the header.

**Built 2026-10-29** (`456c88c`), except the header. Both platforms mint `{prefix}/{sub}/{uuid}.{ext}`
through `StorageRef.objectName`, with the extension from the declared content type. Signing a
`Content-Disposition` would make every client send that header, so the download name waits until
the UI kit sends it; until then an upload is downloaded under its opaque name.

### PD5: the registration ledger's address id

`ContactAddressId.t` becomes the keyed fingerprint of the [Design](#design); the ledger's events gain
`address: Reventless.Email.t` marked `@pii` with the registration as its subject, so an unanswered
registration's values can expire with it; the sender translation builds its row keys from the
fingerprint and reads the address through the wrapper. The fingerprint key is a secret of the
deployment, through the `Secrets` capability, created once and never rotated. Alpha data is wiped on
the format change.

**Exit:** no event of the ledger carries an address outside a `@pii` field; the tag and partition are
the fingerprint; the self-registration walk runs end to end on the local platform; the enumeration-safe
answers are unchanged.

**Built 2026-10-29**, the format half. `Secrets.t` has a keyed `fingerprint(~purpose, input)`: HMAC-SHA256
under the deployment's key, refused without one. On a deployed runtime the key is
`REVENTLESS_FINGERPRINT_KEY`; the local platform resolves it as it resolves its token secret, pinned,
else `.reventless/fingerprint-key` minted once, else per process. `ContactAddressId` is the fingerprint
of the trimmed, lower-cased address under the purpose `contactAddress`, and so is every envelope id the
doors and translations give a ledger command. The address rides in `address: Reventless.Email.t` on
`Register`, `Invite` and the five events that must reach the person (requested, invited, reissued,
attempted on a taken address, proof accepted); a pending claim keeps it in its state for the later ones.
The translations' work rows are keyed by the fingerprint and carry the address beside it. The AWS key
waits for the self-registration door, which is local only; the `@pii` marker on `address` came with
[PD2](#pd2-the-recording-pii). The shared key also serves the keyed hash
of the request limit (DW6), under its own purpose. Breaking for callers of `Invite`: they now send the
address and a fingerprinted id.

### PD6: no log line holds a personal value

`LogFormat` and `detail` format through the schema and print `«pii»` for `@pii` and `@sensitive`
fields. Four fixes outside the formatter: a decode error logs the path and the expected type and never
the received value, whether thrown, logged or stored as `lastError`; the envelope is logged without
`ip` and `headers`; the dead-letter dump prints ids, type and size, AppSync sets
`excludeVerboseContent`, and the log messaging backend refuses to run on a production stack; apps
get a helper that logs a value through its schema, and the rule in writing for `decide`, `project`
and `translate`. Until it lands, the deploy manifest accepts a rule for a stack that declares real
personal data: logs 14 days or less, managed, never at debug.

**Exit:** a test that every framework logging site goes through the redacting formatter; a GWT with a
`@pii` command and event whose log output holds no value; the manifest rule refuses a stack that
breaks it.

### PD7: the bindings

`rescript/node` gains AES-256-GCM encrypt and decrypt with a random nonce and the tag, and a KMS
client with `GenerateDataKey`, `Encrypt` and `Decrypt`. Nothing in core calls them yet; an installed
provider does.

**Exit:** round-trip and tamper tests; a KMS test against a real key on the shared account.

### PD8: an event is encoded once

The aggregate encodes an event once and reuses that form for the owner check, the SNS publish and the
stored item, as the DCB path already does; its log lines print the redacted form. With a random nonce
every encode of an encrypting provider differs, so this is what makes the published copy equal the
stored one.

**Exit:** a counting codec sees one encode per event on both paths.

### PD9: the caches expire, and the append refuses

The aggregate replay cache, the DCB projection cache and any provider cache take a time limit of
minutes beside their capacity, so an erased subject's decoded state leaves a warm container within
the limit. The append on both paths refuses an event whose schema marks `@pii` when the installed
provider is not the plain one and a marked field is not in a stored form, with an error that names the
type and the field and never the value.

**Exit:** the caches expire under `TestClock`; an event handed the wrong schema is refused at append
on the DCB and the aggregate path; the refusal's message holds no value.

### PD10: the scenario every transport must pass

The conformance kit gains a scenario parameterised over the storage makers: for every slice whose
spec marks `@pii`, the codec the transport hands to the schema finds those fields, and a stored row
read back raw holds no plaintext for them when a test provider that encrypts is installed. The two
defects the owner rollout found on AWS, a call site handed `S.json` and a resolver built before its
field was computed, are its fixtures. A new transport passes it before it is accepted.

**Exit:** green on the local platform, DynamoDB and Postgres against real deployments; the kit's
README lists it among the suites a backend must pass.

## Decisions

| Decision | Taken |
|---|---|
| `@pii` is an annotation that installs a codec at the schema, never an adapter decorator | 2026-10-25 |
| `@pii` and `@sensitive` are two attributes; `@pii` implies `@sensitive`, never the reverse | 2026-10-25 |
| A `@pii` field holds one of three stored forms, fixed from the first byte: versioned ciphertext with key id and algorithm, the *erased* marker, the *forgotten* reference | 2026-10-25 |
| On an event the word encrypts, on a command it marks, on a read model it is refused | 2026-10-25 |
| An event field marked `@pii` has the type `Pii.t<'a>`, owned by the recording annotation | 2026-10-25 |
| Tags and partition keys carry only opaque ids; the PPX refuses `@pii` on them; the registration ledger is the one type that tags by a keyed fingerprint instead | 2026-10-25, the ledger's half to confirm in [PD5](#steps) |
| `meta.ip` leaves domain events; `meta.user` stays an opaque id; two optional meta keys are reserved | 2026-10-25 |
| An upload's key is `{prefix}/{sub}/{uuid}.{ext}`, never the file name, never a content hash | 2026-10-25 |
| No log line holds a personal value, as plaintext or ciphertext | 2026-10-25 |
| The append refuses, never degrades, when an installed provider did not run | 2026-10-25 |

## Open questions

1. **Does the wrapper reach read models, forms and GraphQL types, or only events?** Recommendation:
   everywhere, so that app code does not change when a provider is installed; the fallback, events
   only with the unwrapping at the projection, is taken on evidence from the first app that generates
   forms over a `@pii` field, not before.
2. **Which secret signs the ledger's fingerprint?** Recommendation: one made through the `Secrets`
   capability at the deployment's first start and never rotated, because rotation would orphan every
   tag; a deployment that must rotate it rebuilds the ledger from its events, which hold the address.
3. **Where does the request's source IP go once it leaves the event?** Recommendation: the inspector's
   history slice, which already records two audit categories, with the retention that slice has; a
   separate audit log, when one exists, takes the records over.
4. **Does the plain provider's decode ever yield `Erased`?** Recommendation: yes, when it meets the
   `erased:v1` form in a row written while another provider was installed, so a deployment that
   uninstalls a provider still reads its log without error.

## Acceptance

1. After [PD1](#steps) to [PD6](#steps): a `@pii` field compiles to the wrapper on the local platform
   and on AWS; the four refusals fail the build; an event a signed-in user caused has no `meta.ip`;
   an upload has no file name in its path; the ledger's events carry no address outside a `@pii`
   field; a log line of a `@pii` command or event holds no value.
2. After [PD7](#steps) to [PD10](#steps): with a test provider installed, a personal field is
   ciphertext in the stored row on the local platform, DynamoDB and Postgres; the aggregate encodes
   once; the caches expire; an event handed the wrong schema is refused; the conformance scenario is
   green against real deployments.
