# Plan: an inbound translation is gated the same way at every door, and sends commands encoded by their schema

**Status:** Proposed 2026-10-09. Nothing built.<br/>
**Repos:** `reventless-core` only. `reventless/core` (`Dcb_Builder`, `Plugin_Helpers`,
`InboundTranslationSlice_Callback`, `Plugin_Structure`), `reventless/local`
(`InboundTranslationResolvers_GraphQL`, `Platform`), `reventless/aws`
(`InboundTranslationResolvers_AppSync`, the resolver function `invokeInboundTranslation`,
`DcbCommandTopicEntryPoint_Ops`), `reventless/spec` (`InboundTranslationSlice`).<br/>
**Found by:** [analysis/testing-translation-slices.md §3](../analysis/testing-translation-slices.md#3-two-findings-that-are-not-about-tests).<br/>
**Before:** [the-sidecars-read-automations-and-translations.md](done/the-sidecars-read-automations-and-translations.md),
so that its door tests test a gate that exists everywhere.

## Goal

1. An inbound translation slice's `commandAuthorization` means one thing. The local server
   and AWS enforce it alike, and the plugin structure reports what they enforce.
2. The commands an inbound translation publishes are encoded with `Spec.commandSchema`, as
   every other command is.

## The defects

### A. Three readings of one rule

`commandAuthorization: command => rule` is documented as "evaluated at the GraphQL resolver
entry before any external input is translated". At the entry there is no command yet. The
three readers each pick a different answer:

| Reader | Reading |
|---|---|
| AWS door (`Dcb_Builder.mutationEntriesFromInboundSlices` → `AppSync_Adapter`) | the **first** constructor's rule (`permissionForFirstConstructor`), stamped as a Cognito group directive on the mutation field |
| Local door (`InboundTranslationResolvers_GraphQL`) | **none**: the resolver ignores its context, and `inboundMutationResolverHook` is not handed the rule, while the state change hook is (`~commandAuthorization`) |
| Plugin structure (`requiredRoles`) | the **union** over all constructors |

The comment above `permissionForFirstConstructor` says that where constructors differ,
"resolver-level enforcement still fires inside the per-slice handler". That holds for state
change slices. For an inbound slice `receive` checks nothing, and on AWS it cannot: the
resolver forwards `{__inboundTranslation, fieldName, arguments}` with no caller identity.

The spec's `lifecycleState` and `commandTransition` are read by nothing.

**Impact today.** Every example's inbound command has one constructor, so AWS gates
`ImportProduct` correctly. Locally it is open to any caller, so a local test of the gate cannot
fail. A command type with two constructors and different rules is gated on AWS by whichever is
written first.

### B. Commands encoded without their schema

`InboundTranslationSlice_Callback.receive` encodes each command as
`cmd->JSON.stringifyAny->Option.getOrThrow->JSON.parseOrThrow`. This is the ReScript runtime
value, not `Spec.commandSchema`. The outbound callback uses `Util_Sury.toJson(schema)`, and the
target decodes with its own schema. The two encodings agree for the examples' plain records.
They need not agree for a semantic type with a custom codec, an `option` the schema writes as
`null`, or a variant with a custom tag.

## Design

### The rule at the door, and the rule per command

Two checks, because there are two moments:

1. **At the door**, before `translate`: the caller must satisfy **at least one** constructor's
   rule. This is the union the plugin structure already reports. It is one gate per field,
   which is all AppSync can express, and the local resolver applies the same gate.
2. **After `translate`**, per produced command: the caller must satisfy **that** command's rule.
   A command that fails is not published. The whole message is rejected with
   `CommandRejected{errorCode: "Unauthorized"}` and a `Failure` audit row, so a partly
   authorized message never publishes half its commands.

Where every constructor shares one rule (every slice today), check 2 can never fail after
check 1. It only matters for mixed rules, and that is the case that is wrong today.

**System callers.** A slice marked `systemCallable` keeps the IAM path. An IAM caller has no
Cognito groups, so check 2 treats a system caller as satisfying every rule. Step 3 confirms
this matches how the state change path treats an IAM caller before it is built.

### Carrying the caller

- **AWS:** `invokeInboundTranslation` adds `identity: {sub, groups}` from `ctx.identity` to the
  payload. `DcbCommandTopicEntryPoint_Ops` passes it to `receive`. An IAM caller arrives as
  `system`.
- **Local:** the resolver reads the caller from `ctx` the way `CommandGeneratorResolvers_GraphQL`
  does, and passes it to `receive`.
- **`receive` gains `~caller`**: an optional argument, absent meaning *system*. Existing direct
  callers (the S3 import task, tests) keep compiling and keep their meaning.

### `lifecycleState` and `commandTransition`

An inbound slice moves nothing itself; the target owns the lifecycle. **Remove both from the
inbound `Spec`** (and from what the PPX injects for it) rather than read them. No example sets
them. Whether a command arriving from a translation is checked against the **target's**
transition is the target's business, and outside this plan ([Open question 2](#open-questions)).

### Encoding

Encode with `Util_Sury.toJson(Spec.commandSchema)`. An encode failure keeps today's path: a
`Failure` audit row, nothing published.

## Steps

| # | Step | Where |
|---|---|---|
| 1 | One helper, `inboundDoorPermission(~commandSchema, ~commandAuthorization)`, returning the union over all constructors; used by `Dcb_Builder` (replacing `permissionForFirstConstructor` for inbound) and by `Plugin_Structure` | `reventless/core` |
| 2 | Hand the rule to `inboundMutationResolverHook` (`~commandAuthorization`); the local resolver checks the door permission against `ctx` | `Plugin_Helpers`, `Dcb_Builder`, `reventless/local` |
| 3 | `receive(~caller=?)`; the per-command check after `translate`; `Unauthorized` rejection and `Failure` audit row | `InboundTranslationSlice_Callback` |
| 4 | AWS: identity into the payload, through the entry point into `receive` | `reventless/aws` |
| 5 | Encode with `commandSchema` | `InboundTranslationSlice_Callback` |
| 6 | Remove `lifecycleState` / `commandTransition` from the inbound spec and its PPX injection | `reventless/spec`, `packages/reventless-ppx` |
| 7 | Correct the comment above `permissionForFirstConstructor`, the spec's doc comment, and the webhook plan's [Consequences of two doors](Backlog/webhook-infrastructure.md#consequences-of-two-doors) | docs and comments |

Step 6 changes the PPX, so it goes out with the next PPX release by the usual procedure. Steps
1 to 5 do not depend on it, and can ship first.

## Tests

- **Local door** (`InboundTranslationMutationTest`): a caller without the role is refused; one
  with it is accepted; an unauthenticated call is refused.
- **AWS schema:** the decorated SDL for a two-constructor fixture with rules `AllowRoles([A])`
  and `AllowRoles([B])` carries the groups of both. Today it carries only `A`'s.
- **Per command** (`InboundTranslationSliceCallbackTest`): a caller with `A` only whose message
  translates into a `B` command gets `Unauthorized` and a `Failure` row, and nothing is
  published. A caller absent (system) publishes.
- **AWS entry point** (`DcbInboundTranslationRoutingTest`): the identity in the payload reaches
  `receive`.
- **Encoding:** a fixture command with an `option` field and a semantic-type field round-trips
  through the target's decoder. The test fails with `stringifyAny`.
- **Plugin structure:** `requiredRoles` equals the door permission's roles, from the same
  helper.

## Decisions (proposed)

| # | Decision | Why |
|---|---|---|
| D1 | Door = union of the constructors' rules; each published command checked against its own | the door cannot know the command; the union is the only gate that refuses nobody the slice would accept |
| D2 | A message with one unauthorized command publishes nothing | a half-applied external message is worse than a refused one; the audit row says why |
| D3 | `lifecycleState` / `commandTransition` leave the inbound spec | nothing reads them, and the lifecycle belongs to the target |
| D4 | `receive`'s caller is optional, absent meaning *system* | the S3 task and tests call `receive` directly |

## Open questions

1. **The webhook door.** A webhook caller has no Cognito groups. Its authentication (signature,
   key) replaces check 1. Is check 2 then skipped, or does the webhook config name the roles
   it stands for? Leaning: the webhook config names a role, and check 2 runs against it. Decide
   in [webhook-infrastructure](Backlog/webhook-infrastructure.md).
2. **Does the target check its own authorization and transition** when a command arrives from a
   translation rather than from its own mutation? Today a published command bypasses the
   target's resolver. This plan does not change that.

## Acceptance

- The local server refuses an inbound mutation from a caller without the role, as AWS does.
- A two-constructor fixture is gated on AWS by the union of both rules, and each published
  command by its own.
- `requiredRoles` and the deployed gate come from one helper.
- Inbound commands are encoded with `commandSchema`; the round-trip test passes.
- Full build and root `pnpm test` pass.
