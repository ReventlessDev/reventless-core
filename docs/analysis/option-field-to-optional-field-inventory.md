# `option<'a>` Record Fields That Could Become Optional Fields — Inventory

**Scope.** Every record field declared `field: option<X>` across all packages in this repo, with an
assessment of whether it could be written `field?: X` instead, what that would change, and what it
would not. Measured 2026-09-06 against the working tree at `alpha`.

**Method.** All 1,699 tracked `.res`/`.resi` files scanned for record-field declarations of the form
`[@attrs] [mutable] name: option<…>`, excluding labelled arguments. Each hit classified by its
enclosing type declaration. Mechanics verified by compiling probe files with the repo's own
`bsc.exe` and by reading the committed `Plugin.res.mjs`.

---

## 1. Headline

| | count |
|---|---|
| `field: option<X>` record fields | **240**, in 87 files |
| `field?: X` optional fields already in the tree | **~1,400** |
| Explicit `field: None` construction sites that would disappear | **~416** |

The optional-field form is already the house style by roughly 6:1. The 240 are stragglers, and they
cluster: **45 of them are in one file** (`reventless/spec/src/components/Plugin.res`), which already
mixes both forms inside the same record.

234 of the 240 are *convertible*. Fewer are worth converting.

## The recommendation

| verdict | fields | what |
|---|---|---|
| ✅ **Refactor** | **125** | §8 lists them as five independent steps. Every one meets at least one of the four inclusion tests in §8.1. |
| ⚠️ **Real bug, different fix** | 16 | `option<Pulumi.Output.t<'a>>` silently destroys the value at runtime — but **`?:` does not fix it** (§4). These need one of three other treatments and do not belong in this refactor. |
| 🟡 **Opportunistic** | 62 | Tier-3 fields that meet none of the four tests — no mirror, no repeated shape, no behavioural consequence. Convert when you are already in the file; a dedicated sweep costs more review than it returns. |
| ⏸️ **Decide first** | 7 | The example *view state* fields. Safe on the wire, but a convention decision already went the other way — §3. |
| ❌ **Leave** | 30 | 24 inbound binding fields (no behavioural difference at all), 4 healer regression-test fields, 2 doc-comment samples — §6, §7. |

---

## 2. The mechanics, measured

Three facts decide every row in this inventory. All three were compiled, not assumed.

**(a) For a `@schema` type the two forms are wire-identical.** sury-ppx compiles them to the same
call. From the committed `reventless/spec/src/components/Plugin.res.mjs:100-102` — three adjacent
fields of `commandDef`, two written `option<…>` and one written `?`:

```js
allowedStates:       s.m(Sury.$option(Sury.array(Sury.string))),  // allowedStates: option<array<string>>
targetState:         s.m(Sury.$option(Sury.string)),              // targetState: option<string>
allowedStatesSource: s.m(Sury.$option(Sury.string)),              // allowedStatesSource?: string
```

Identical. So for schema types the conversion changes no JSON, no emitted JSON Schema, no SDL, and
no golden. This only became true after the per-field `@s.matches(...OptionSchema)` annotations were
removed — see [`sury-per-field-optional-annotation.md`](./sury-per-field-optional-annotation.md) §6.2,
where the same equivalence was measured through the repo's own emitter.

**(b) For a plain ReScript record the emitted JS object differs.** Key present-and-`undefined` versus
key absent:

```rescript
type a = {x: option<string>, y: string}   let u: a = {x: None, y: "1"}
type b = {x?: string, y: string}          let v: b = {y: "1"}
```
```js
let u = { x: undefined, y: "1" };
let v = { y: "1" };
```

`JSON.stringify` erases the difference (it drops `undefined`), so this matters only where JS code
does `"x" in obj`, `Object.keys`, or a spread merge. Nothing in the AWS write paths does — DynamoDB
`unmarshall` is inbound-only here, and outbound rows go through sury first.

**(c) `mutable f?: X` is legal and its setter still takes `option<X>`.** Compiled:

```rescript
type t = {mutable a?: string}
let x: t = {}          // → let x = {};
x.a = None             // → x.a = undefined;   (accepted; `x.a = "hi"` is rejected)
```

Note the asymmetry: construction omits the key, but a later mutation writes `undefined` back, so
optionality is not a durable absence guarantee for a mutable field.

**(d) None of this touches a value whose runtime representation is a `Proxy`.** For
`option<Pulumi.Output.t<'a>>` the corruption is not in the field declaration at all — it is in the
generic option combinators that run over the field — so *both* forms are equally exposed and `?:`
fixes nothing. That is §4, and it is the one place in this inventory where the obvious refactor is
the wrong one.

---

## 3. Tier 1 — `@schema` types · 67 matches · **54 recommended**

Free by fact (a): no wire change, no `check:graphql` movement, no consumer impact.

| | file | fields | note |
|---|---|---|---|
| ✅ | [reventless/spec/src/components/Plugin.res](../../reventless/spec/src/components/Plugin.res) | **45** | `pluginStructure` / `pluginDefinition` and everything reachable from them. Already mixes styles (`allowedStatesSource?`). Highest-value single file in the repo. |
| ✅ | [reventless/core/src/plugin/lifecycle/PluginsReadModelSpec.res](../../reventless/core/src/plugin/lifecycle/PluginsReadModelSpec.res) | 4 | `apiSchemaFragment`, `structure`, `dcbEventLog`, `kind` on `type state`. Its `queryResult` mirror (4 more, Tier 3) converts with it — 8 in the file. |
| ✅ | [examples/…/ordering/…/Orders.res](../../examples/online-shop-hybrid/ordering/src/Order/StateViewSliceStream/Orders.res) `consumedEvent` | 2 | `deliveryWindow`, `firstProductName`. **Event** fields — the convention below already says these should be `?`. |
| ✅ | [reventless/core/src/plugin/lifecycle/PluginBehavior.res](../../reventless/core/src/plugin/lifecycle/PluginBehavior.res) | 1 | `current: option<version>` |
| ✅ | [reventless/local/src/LocalPlatformRegistry.res](../../reventless/local/src/LocalPlatformRegistry.res) | 1 | `path` on `type store` |
| ✅ | [reventless/core/tests/fixtures/TaggedUnionFixtures.res](../../reventless/core/tests/fixtures/TaggedUnionFixtures.res) | 1 | `lastSeen: option<geolocation>` |
| ⏸️ | [examples/…/ordering/…/Customer_Behavior.res](../../examples/online-shop-hybrid/ordering/src/Customer/Aggregate/Customer_Behavior.res) | 4 | `location`, `locationResolvedFrom` × 2 `type state` — see caveat |
| ⏸️ | [examples/…/ordering/…/Orders.res](../../examples/online-shop-hybrid/ordering/src/Order/StateViewSliceStream/Orders.res) `state` | 2 | same two fields on the view state |
| ⏸️ | [examples/…/catalog/…/Products.res](../../examples/online-shop-hybrid/catalog/src/Product/StateViewSliceStream/Products.res) | 1 | `@groupBy categoryName` on `type state` |
| ❌ | — *excluded* — | 6 | §6 |

**Caveat on the example view states.** [`semantic-date-range.md`](../plans/semantic-date-range.md)
set a deliberate convention while adding `deliveryWindow`: *the command/event field is an optional
field (`?`); the view state stays `option<>`*. Seven of the Tier-1 example rows (`Customer_Behavior`
×4, `Orders` state ×2, `Products` ×1) are exactly those view states. Converting them is safe on the
wire but contradicts a decision already made — treat as a convention question, not a cleanup.

That plan also records the one behavioural trap this change ever sprang: making a command/event
field `?` exposed that `Behavior_GWT`'s `AssertionCore` compared events with raw structural
equality, which distinguishes present-but-`undefined` from absent even though both serialize
identically. **Already fixed** — GWT now compares on the encoded wire form (`encEvents`) — so the
trap is closed, but it is the failure mode to watch for in any DSL that compares records directly.

---

## 4. Tier 2 — `option<Pulumi.Output.t<'a>>` · 16 fields · ⚠️ **real bug, but `?:` is not the fix**

`CLAUDE.md` and `.claude/rules/component-guidelines.md` both list `option<Pulumi.Output.t<'a>>` as a
type combination that "doesn't work correctly". It is the most serious thing in this inventory — and
it is the one thing here that **converting to an optional field does not fix.** Measured, not assumed.

### 4.1 What actually goes wrong

`Pulumi.Output.t` is a JS `Proxy` that answers *any* property access with a new `Output` (that is how
`output.foo.bar` lifting works). ReScript's option boxing probes exactly one property to detect a
nested option — `@rescript/runtime/lib/js/Primitive_option.js`:

```js
function some(x) {
  if (x === undefined) return {BS_PRIVATE_NESTED_SOME_NONE: 0};
  else if (x !== null && x.BS_PRIVATE_NESTED_SOME_NONE !== undefined)
    return {BS_PRIVATE_NESTED_SOME_NONE: x.BS_PRIVATE_NESTED_SOME_NONE + 1 | 0};
  else return x;                                    // ← the only branch that keeps the value
}
```

The Proxy makes that probe truthy, so the middle branch fires. `Output + 1 | 0` is `NaN | 0` = `0`.
Run live against the real `@pulumi/pulumi`:

```
o = pulumi.output("real-table-name")
o.BS_PRIVATE_NESTED_SOME_NONE !== undefined  : true          ← the Proxy answers the probe
Primitive_option.some(o)                     : {"BS_PRIVATE_NESTED_SOME_NONE":0}
valFromOption(some(o))                       : undefined      ← the Output is simply gone
```

Whenever that helper runs over an Output the value is replaced by the sentinel for *nested `None`*,
and reading it back yields `None` — silently, at deploy time, into stack state.

`Stdlib_Option.map` runs **both** halves — `Primitive_option.some(f(Primitive_option.valFromOption(opt)))` —
so it corrupts on unwrap *and* on rewrap; `getOr` corrupts via `valFromOption`.

### 4.2 Where the corruption actually happens — and why `?:` is not the fix

The decisive detail is *when the compiler emits that helper at all*.
[`Output.res:4`](../../rescript/pulumi-pulumi/src/Output.res#L4) declares

```rescript
type t<'a> = {}
```

— an **empty record, not an abstract type**. The compiler can therefore prove an `Output` is not
itself an option and skips the defensive boxing entirely. Compiled against that exact definition:

```js
mkOption(o)   { return {a: o, y: "1"}; }   // {a: option<out<string>>}  — bare, no boxing
mkOptional(o) { return {a: o, y: "1"}; }   // {a?: out<string>}         — bare, no boxing
refStore(o,r) { r.contents = o; }          // r := Some(o)              — bare, no boxing
switchIt(r)   { let x = r.a; if (x !== undefined) return x; }   // safe
mapIt(r)      { return Stdlib_Option.map(r.a, x => x); }        // ← corrupts
getOrIt(r,d)  { return Stdlib_Option.getOr(r.a, d); }           // ← corrupts
```

**Construction is safe in both forms.** The corruption lives entirely in the *generic* combinators —
`Option.map`, `Option.flatMap`, `Option.getOr`, or passing to a labelled `=?` argument — where `'a`
is a type variable inside `Stdlib_Option` and the runtime helpers must be used.

That is why `?:` fixes nothing: **it changes the declaration, and the declaration was never the site
of the bug.** Both forms compile identically and safely at construction, and both stay equally
exposed to whatever combinator runs downstream. These 16 fields are **excluded from the §8 plan** —
converting them would be motion without a fix, and would look like the bug had been addressed.

It also explains the field-by-field inconsistency: whether a given `option<Output>` has ever
misbehaved depends solely on whether a generic combinator happens to run over it — a property of the
*call sites*, not of the type. `pluginReadModelTableName` never crashed because its producer was
already a plain ternary; `auditTableName`, the same type, did.

### 4.3 The three fixes the repo actually uses

| fix | where | shape |
|---|---|---|
| **Wrapper record** | `Plugin_Helpers.res:7` | `type hookedValue<'a> = {val: 'a}` — a plain record has no `BS_PRIVATE_NESTED_SOME_NONE`, so `some()` returns it verbatim. `option<hookedValue<Output>>` is safe. Verified: `some({val: o})` keeps the Output. |
| **Sentinel instead of option** | `Plugin_Helpers.res:1143`, and the `auditTableName` fix | `ref<Pulumi.Output.t<JSON.t>> = ref(%raw("null"))` with `%raw("v === null")` checks, or a plain `Pulumi.Output.t<string>` where `""` means absent. No option over the Output at all. |
| **Avoid the generic combinators** | surgical, no type change | Replace `->Option.map(r => r.name)` with `switch opt { Some(r) => Some(r.name) \| None => None }`, which compiles to a plain ternary. Verify the `.mjs` emits `x !== undefined ? x.name : undefined`, not `Primitive_option.some(...)`. |

### 4.4 The guard — `pnpm run check:pulumi-option`

Audited 2026-09-07: **none of the 30 option-wrapped Outputs in the tree is currently corrupted.** Every
`Stdlib_Option.*` call in the five deploy-time builder modules lands on a string, a record, a dict
lookup or an `isSome`/`isNone` (which only compare against `undefined` and never unwrap). `baseUrl`
routes through `Output.allOpt`, whose `Primitive_option.some` runs on the *resolved* string inside the
`.apply`, not on the Proxy. Safe — but safe by call-site accident, not by construction.

Nothing was defending that. Jest, GWT and the goldens all sit at the domain layer, where no Pulumi
runtime exists and the Proxy cannot be constructed; exactly one test in the repo drives Pulumi under
mocks (`EventCollectorConnectLambdaPreviewTest`), written after a *different* deploy-time escape. The
corruption is type-correct, so nothing looks wrong, and it escaped to production twice.

[`scripts/check-pulumi-option.mjs`](../../scripts/check-pulumi-option.mjs) closes it with two rules:

- **Rule 1 — declaration ratchet.** Any `option<Pulumi.Output.t<_>>` outside the allowlist of the 30
  existing sites fails. Shrink the list; never grow it.
- **Rule 2 — the hazard.** Any of the 15 `Stdlib_Option` members that call `Primitive_option.some` /
  `valFromOption` (`map`, `getOr`, `flatMap`, `forEach`, `mapOr`, `filter`, `getOrThrow`, `equal`,
  `compare`, `all`…`all6` — derived by reading the runtime, not guessed) applied to a name declared as
  an Output option and never as an option of anything else.

It reads `.res` rather than the compiled output, because the emitted JS has no types —
`Stdlib_Option.getOr(x, "")` is identical whether `x` is an Output or a string — and it needs no
build, so it runs even when compilation is broken.

Rule 2 covers 18 of the names; 7 are excluded as ambiguous and reported on every run rather than
hidden, since the runtime entry points carry records with the same field names typed `option<string>`
where `Option.getOr("")` is correct. Both rules were negative-tested: reintroducing the historical
shape (`r.dcbPublishJsons->Option.map(...)`) and adding a fresh declaration each fail as intended.

Note the third fix above: a field *typed* `option<Output>` only corrupts when a `some()`-producer or
`valFromOption`-consumer actually runs over it. A direct `Some(x)` literal on a concretely-typed
`Output` can compile unboxed and be safe — which is why some of these 16 have never misbehaved while
others have. That asymmetry is what makes the bug so hard to spot, and why the type is banned
outright rather than audited case by case.

### 4.5 The 16 record-field sites

These are the 16 that fall inside this inventory's scope — *record fields*, the thing being counted
everywhere else in this document. The guard's population is larger (**30**), because it also picks up
`ref<option<Pulumi.Output.t<_>>>` bindings, `let` bindings and labelled arguments (`~x: option<…>=?`),
which carry the identical hazard but are not record fields and so never entered the §1 count.

| file | fields |
|---|---|
| [reventless/aws/src/plugin/runtime/PluginRuntime_Builder.res](../../reventless/aws/src/plugin/runtime/PluginRuntime_Builder.res) | 8 — `eventTopicArn`, `pluginReadModelTableName`, `schedulerRoleArn`, `schedulerQueueArn`, `schedulerQueueName`, `appSyncApiId`, `dcbTableName`, `epQueueUrl` |
| [reventless/aws/src/adapter/EventLog/EventLogBackend.res](../../reventless/aws/src/adapter/EventLog/EventLogBackend.res) | 2 — `mutable collectorQueueUrl` / `collectorQueueArn` |
| [reventless/aws/src/adapter/DcbEventLog/DcbBackend.res](../../reventless/aws/src/adapter/DcbEventLog/DcbBackend.res) | 2 — same pair, `mutable` |
| [reventless/aws/src/plugin/runtime/PluginExtensionPointRuntime_Builder.res](../../reventless/aws/src/plugin/runtime/PluginExtensionPointRuntime_Builder.res) | 2 — `pluginReadModelTableName`, `schedulerRoleArn` |
| [reventless/aws/src/Platform.res](../../reventless/aws/src/Platform.res) | 1 — `baseUrl` |
| [reventless/core/src/components/Dcb/Dcb_Builder.res](../../reventless/core/src/components/Dcb/Dcb_Builder.res) | 1 — `dcbPublishJsons` |

The four `mutable` ones are the whole of the repo's `mutable … : option<…>` usage.

**Known casualties**, both traced back to this: `apiFragmentRegistryTableName` in the reactive-push
config threading, and `auditTableName` in `PluginRuntime_Builder` / `StateChangeSliceRuntime_Builder_Single`
— the latter doubly silent, because the audit save resolves `Error` rather than throwing, so the
audit view stayed empty while every import command returned `Accepted`. The runtime breadcrumb is
`value.split is not a function` thrown inside a DynamoDB `PutCommand.send`: a non-string `TableName`
is almost always a corrupted `option<Output>`.

---

## 5. Tier 3 — internal plain records · 129 fields · **67 recommended, 62 opportunistic**

No wire, no schema, no infrastructure meaning. The payoff is the ~416 `field: None` lines that go
away and the `{...r, ?field}` punning that becomes available. That payoff is real where the fields
cluster and negligible where they don't, which is the whole split:

**✅ Recommended — 67, in five clusters:**

- **`reventless/aws/src/adapter/Runtime/*` — 39 fields.** The Lambda entry-point config records:
  `ReadModelEntryPoint_Ops` (7), `StateViewSliceEntryPoint_Ops` (5), `EventCollectorEntryPoint_Ops`
  (4), `PgQueryResolverEntryPoint_Ops` (3), and singles and pairs across the rest. Same handful of
  names repeated — `pgConnection`, `stateTopicName`, `subIdConfig`, `config`, `plugin`, `comp`.
  `eventCollectorChannelSpec` alone is declared **7×** across the six `AggregateRuntime_Builder_*`
  variants plus `AggregateRuntime_Builder_Common` — one shape, seven copies, converts as a unit.
- **[`reventless/spec/src/components/StateAnnotations.res`](../../reventless/spec/src/components/StateAnnotations.res) — 6.**
  `lifecycle`, `groupBy`, `visibility`, `live`, `retired`, `values`. Between them these account for
  ~60 of the `: None` sites (`visibility` 16, `values` 16, `live` 12, `groupBy` 11) — the densest
  ergonomic win outside `Plugin.res`.
- **[`scripts/CheckLifecycleModel.res`](../../scripts/CheckLifecycleModel.res) — 4.**
  `declaredCommand` mirrors `Plugin.commandDef` field-for-field; convert **with** Tier 1 to keep the
  two in step, not separately.
- **[`…/DcbEventLogStorage_DynamoDb_Runtime.res`](../../reventless/aws/src/adapter/DcbEventLog/DcbEventLogStorage_DynamoDb_Runtime.res) — 4.**
  `scanFilter` (`filterExpression`, `expressionAttributeNames`, `expressionAttributeValues`) is
  handed to the AWS SDK. The only Tier-3 entry recommended for a reason other than tidiness: by
  fact (b), DynamoDB rejects an empty `ExpressionAttributeValues`, so key-absent is the safer shape
  than key-`undefined`.

- **Duplicated config shapes — 10, in four files.** Two records declared twice, in full, in different
  packages: `retiredField` + `retiredValues` in both
  [`PgQueryResolver_Lambda.res`](../../reventless/aws/src/adapter/QueryDb/PgQueryResolver_Lambda.res)
  (with `subIdField`, `ownerField`) and
  [`StateTopic_AppSync.res`](../../reventless/aws/src/adapter/StateTopic/StateTopic_AppSync.res); and
  `memorySize` + `timeout` in both [`RuntimeHints.res`](../../reventless/infra/src/types/RuntimeHints.res)
  and [`Config.res`](../../reventless/spec/src/generator/Config.res) `runtimeHints` — same two fields,
  same doc comment, same cited plan. Converting one copy and not the other is how two declarations of
  one shape start to drift.

Plus the 4 `queryResult` fields in `PluginsReadModelSpec.res`, counted with that file in §3.

**🟡 Opportunistic — 62, across 37 files.** One to three fields each, no mirror elsewhere, nothing
structural: `reventless/gwt/` (7 — `Flow_GWT` 3, `Query_GWT` 2, `Hint`, `Outcome`),
`Platform_BakedManifest` (3), `Plugin_Helpers` (3), `Semantic` (3), `DemoData` (3) — 19 fields in 8
files — then **43 fields across 29 more files**, one or two apiece, in `core`, `infra`, `postgres`,
`local`, `graphql-server`, `seed-aws`, `traits` and package tests. Each is a two-line change carrying
a full review, compile and test run — worth doing while you are already in the file, not worth a
sweep of its own.

---

## 6. ❌ Do not convert · 6 fields

| file | fields | why |
|---|---|---|
| [reventless/spec/tests/MessageHealTest.res:19-22](../../reventless/spec/tests/MessageHealTest.res) | 4 | `healOptionals` exists **to exercise the `option<>` decode/heal path** — `optStr`, `optArr`, `optRec`, `optEnum`, one per shape the healer branches on. `option<record>` and `option<enum>` are precisely the two the healer got wrong once (`sury-per-field-optional-annotation.md` §6.1). Converting deletes the regression test. |
| [reventless/spec/src/semantic/GeoPoint.res:54](../../reventless/spec/src/semantic/GeoPoint.res) | 1 | inside a module doc comment, not code |
| [reventless/spec/src/semantic/DateRange.res:57](../../reventless/spec/src/semantic/DateRange.res) | 1 | ditto |

Both doc samples would be worth updating anyway if the surrounding convention moves — they teach the
form readers copy.

---

## 7. Tier 4 — binding packages · 28 fields · **4 recommended, 24 left alone**

The tier where the value is lowest, because most of these records are **inbound**: `type output`,
`type message`, `sendMessageBatchResultEntry` — decoded from a JS value the framework never builds.
On a read, a missing key and a key holding `undefined` both give `None`, so the two declarations
behave *identically*. Converting them buys accuracy of intent and nothing else, and touching a
published binding package for nothing else is not worth the version churn.

| | file | fields | direction |
|---|---|---|---|
| ✅ | [rescript/pulumi-pulumi/src/Resource.res](../../rescript/pulumi-pulumi/src/Resource.res) | 2 | **outbound** — `@as("__name")`, `@as("__parentResource")` |
| ✅ | [rescript/pulumi-aws/src/S3/S3_Bucket.res](../../rescript/pulumi-aws/src/S3/S3_Bucket.res) | 1 | **outbound** — `opts: option<Pulumi.CustomResourceOptions.t>` |
| ✅ | [rescript/mcp-sdk/src/McpSdk.res](../../rescript/mcp-sdk/src/McpSdk.res) | 1 | **outbound** — `arguments: option<JSON.t>` on `callToolParams` |
| ❌ | [rescript/aws-sdk/src/SQS.res](../../rescript/aws-sdk/src/SQS.res) | 9 | inbound |
| ❌ | [rescript/pulumi-aws/src/SNS/SNS_Topic.res](../../rescript/pulumi-aws/src/SNS/SNS_Topic.res) | 9 | inbound (`type message`) |
| ❌ | [rescript/aws-sdk/src/SecretsManager.res](../../rescript/aws-sdk/src/SecretsManager.res) | 3 | inbound |
| ❌ | [rescript/aws-sdk/src/Kinesis.res](../../rescript/aws-sdk/src/Kinesis.res) | 1 | inbound |
| ❌ | [rescript/pulumi-aws/src/SecretsManager/GetSecretVersion.res](../../rescript/pulumi-aws/src/SecretsManager/GetSecretVersion.res) | 1 | inbound |
| ❌ | [rescript/pulumi-aws/src/Lambda/Lambda.res](../../rescript/pulumi-aws/src/Lambda/Lambda.res) | 1 | inbound (`clientContext`) |

Those four outbound fields, across three files, are the only Tier-4 rows where fact (b) has teeth — a Pulumi resource option
or an MCP `arguments` reaching the JS side as a present-`undefined` key rather than an absent one.
`rescript/pulumi-aws` and `rescript/aws-sdk` already carry 529 and 344 optional fields respectively,
so they are outliers within their own files.

---

## 8. The recommended refactor — 125 fields, five steps

### 8.1 What makes a field recommended rather than opportunistic

Every one of the 240 fields is the same two-line edit. What differs is not the edit's cost but
**whether leaving it undone costs anything.** A field is recommended if at least one of these holds:

1. **Behaviour** — the emitted JS actually differs in a way something downstream can see (§2b). Fully
   objective; applies to 8 fields.
2. **Same record** — it sits in a type graph where the rest is being converted anyway, so the marginal
   cost is zero and a partial conversion leaves one record in two styles.
3. **Repeated shape** — the same field, in the same shape, is declared in more than one file
   (`eventCollectorChannelSpec` ×7, `retiredField`/`retiredValues` ×2, `memorySize`/`timeout` ×2).
   Converting one copy and not the others is how duplicated declarations start to drift.
4. **Category closure** — it is one of the last few of an otherwise-finished class, so one commit
   removes the class entirely instead of leaving a residue nobody will come back for.

Opportunistic means **none of the four applies**: a field or a pair in a file with no mirror, no
repeated shape, and no behavioural consequence, where the only gain is local tidiness. That gain is
real but small, and it is bought with a review, a compile, a test run and a line in someone's
`git blame`. Bundled into a change you were making anyway, it is free; on its own it is not.

**What is deliberately *not* the criterion:** fields-per-file. It looks like it should be the answer
and it is not — recommended averages 3.8 fields/file against opportunistic's 1.7, but the
distributions overlap heavily (13 recommended files hold a single field; one opportunistic file holds
four). The `Runtime/*` cluster is the reason: most of its files carry one or two fields each, and it
qualifies on test 3, not on density.

Tests 1–3 are checkable. Test 4 is a judgment call, and it is the weakest — it admits 5 fields on
tidiness alone. Two files were reclassified *into* recommended on test 3 after this section was
written, which is the honest measure of how soft the boundary is: the tests are a defensible sort,
not a derivation.

### 8.2 The steps

Each step is independently compilable, independently revertible, and worth a commit of its own.

| # | step | fields | test | why this one |
|---|---|---|---|---|
| 1 | **`Plugin.res` + `PluginsReadModelSpec.res` + `CheckLifecycleModel.res`** | 57 | 2, 3 | The largest cluster in the repo, finishing a style `Plugin.res` already started. Wire-neutral by fact (a). The three move together because `queryResult` and `declaredCommand` mirror `Plugin.res` field-for-field — splitting them leaves two files disagreeing with their own source of truth. |
| 2 | **Tier 3 `Runtime/*` + `StateAnnotations.res`** | 45 | 3 | The bulk of the remaining `: None` noise, and `eventCollectorChannelSpec` × 7 converts as one shape. |
| 3 | **Duplicated config shapes** — `PgQueryResolver_Lambda` + `StateTopic_AppSync`, `RuntimeHints` + `Config.runtimeHints` | 10 | 3 | Two records each declared twice in different packages; convert both copies or neither. |
| 4 | **`DcbEventLogStorage_DynamoDb_Runtime.res` `scanFilter` + the outbound bindings** | 8 | 1 | The only entries recommended for a behavioural reason rather than tidiness — key-absent is the correct shape where the record reaches a JS SDK. |
| 5 | **Remaining Tier-1 singles** — `PluginBehavior`, `LocalPlatformRegistry`, `TaggedUnionFixtures`, `Orders.consumedEvent` | 5 | 4 | Sweep-up; the weakest case in the plan. Drop it without consequence if the appetite runs out. |

Only step 1 crosses a package boundary that matters — `reventless/spec` publishes on every alpha
push — and by fact (a) that publish carries no wire change for an installed consumer.

**Not in the plan, deliberately:** the 16 `option<Pulumi.Output.t<'a>>` fields, which need one of the
§4.3 fixes and not this one; the 62 opportunistic Tier-3 fields (§5); the 7 view-state fields awaiting
the §3 convention call; and the 30 in §6/§7. That is 115 of the 240 left where they are.

The Tier-2 sixteen are worth a **separate** piece of work, sequenced ahead of this one on severity —
they are a live correctness bug, not a style question. But it is a different refactor with a different
verification (read the emitted `.mjs` for `Primitive_option.some`, not the wire format), and folding
it in here would hide a real fix inside a cosmetic sweep.
