# Plan: a rejected command says why it was rejected

**Status:** 📋 Planned 2026-10-21. Not started.<br/>
**Derived from:** [framework-vocabulary-behavior-chapter-and-doubled-terms.md](../analysis/framework-vocabulary-behavior-chapter-and-doubled-terms.md),
[§8.3](../analysis/framework-vocabulary-behavior-chapter-and-doubled-terms.md#83-alternatives-for-telling-a-client-which-no-it-got),
decision [D11](../analysis/framework-vocabulary-behavior-chapter-and-doubled-terms.md#15-decisions).<br/>
**Touches:** `reventless/core` (command outcomes, the SDL fragment), `reventless/local` (the
GraphQL resolvers), `reventless/aws` (the AppSync side), `reventless/seed` (its client),
`packages/reventless-ppx` (the reserved-name check), the GraphQL contract goldens, the docs.

## In plain words

When a command does not go through, a client gets `CommandRejected {errorCode, errorDetail}`.
That one answer covers three different situations:

- **the model said no**: `decide` returned one of the spec's declared errors, such as
  `CategoryNotFound`. Showing the reason is right; retrying is pointless;
- **the caller may not act**: the access check refused before `decide` ran. The code is
  `Forbidden`;
- **the platform failed**: the event log rejected the append (`AppendFailed`) or the retries
  could not absorb the contention (`Conflict`). Retrying later is right; the model never said no.

The platform knows which one it is: every rejection carries a `refusalCause` internally. It just
never tells the client, whose only clue is `errorCode`, and a spec is free to declare an error
named `Conflict` or `Forbidden`. This plan sends the cause and reserves the platform's codes.

## Goal

- `CommandRejected` gains `cause: CommandRejectionCause!`, an enum `DOMAIN | ACCESS |
  INFRASTRUCTURE`, on both platforms and in every subscription that carries a command outcome.
- A spec cannot declare an error variant named like a platform code. The PPX refuses it at
  compile time.
- The change is additive: every existing query and fragment keeps working, and a client that
  does not select `cause` sees nothing new.

Not in scope: a separate `CommandFailed` member of the result union, or prefixing the
platform's codes. Both are breaking for existing clients
([§8.3 of the analysis](../analysis/framework-vocabulary-behavior-chapter-and-doubled-terms.md#83-alternatives-for-telling-a-client-which-no-it-got)).

## Phases

### C1. The cause travels with the outcome

- `CommandTopic_Helpers.res`: the producer-facing `Rejected({msgId, errorCode, errorDetail})`
  gains `cause: refusalCause`, filled from the `OutcomeRejected` that already carries it, and
  its JSON encoding writes `"cause"`.
- The synthesized rejection for a handler that failed outright (`errorCode: "Conflict"` when
  the handler's effect errored) is `InfrastructureFailure`.
- The aggregate and slice callbacks already classify their arms; check each producer of a
  rejected result sets the cause it means: `decide` → `DomainRejection`, the ownership and
  role check → `AccessRefusal`, `Conflict` and `AppendFailed` → `InfrastructureFailure`.
- Asynchronous dispatch: where a pending command's outcome reaches a subscriber
  (`Plugin_SubscriptionSchema.res`), the rejected outcome carries the cause too.

### C2. The schema and the resolvers

- `GraphQL_FragmentGenerator.res`: `type CommandRejected` gains `cause:
  CommandRejectionCause!`, and the enum is declared once beside the result union. On AWS it
  joins the shared type names in `AppSync_SdlDecorate.res` so the merged API declares it once.
- The local resolvers (`CommandGeneratorResolvers_GraphQL.res`) and the AppSync resolver map
  `refusalCause` to the enum.
- Refresh the GraphQL contract goldens in the same commit (`pnpm run check:graphql:update`).
- `Seed_Client.res` selects `cause` and reports an infrastructure rejection as retryable
  rather than as the model refusing.

### C3. The platform's codes are reserved

- One list of the codes the platform puts on `CommandRejected`, in `reventless-spec`
  (`CommandOutcome.platformErrorCodes = ["Forbidden", "Conflict", "AppendFailed"]`), read by
  the handlers that emit them, so a new code cannot be added in one place only.
- The PPX refuses a `@schema type error` variant with one of those names, in any spec or
  decision file: *"`Conflict` is a code the platform uses for its own rejections; name this
  error for what the model means, such as `AlreadyBooked`"*. The PPX is OCaml and cannot read
  the ReScript list, so it holds a copy, and a spec test asserts the two lists agree.
- Webhook statuses (`Unsigned`, `InvalidBody`, `PublishFailed`) are HTTP answers, not
  `CommandRejected`, and are not reserved.

### C4. Docs

- The command-outcome section of the API docs: the three causes, what a client should do with
  each, and that `errorCode` is the declared error's name only when the cause is `DOMAIN`.
- The glossary's *Rejection* entry names the cause.
- `CLAUDE.md`: the owner-marker paragraph says the access refusal travels with cause `ACCESS`.

## Verification

- GWT and handler tests: a `decide` error arrives with `DOMAIN`, an ownership refusal with
  `ACCESS`, an exhausted retry loop and a failing store with `INFRASTRUCTURE`, on both the
  in-memory and the SQLite backend.
- A live local round trip selects `cause` on a mutation and on a subscription.
- An existing query that does not select `cause` returns exactly what it returned before.
- A fixture spec declaring `| Conflict` fails to compile with the message.
- `pnpm run check:graphql`, `check:fresh-outputs`, zero build warnings, `pnpm test`.

## Risks

- **A non-null field on a shared type.** On AWS the merged API declares `CommandRejected` once
  for every plugin; a plugin built before this change would declare it without `cause`. Every
  plugin of a platform must be built against the same core version before the field reaches
  the merged schema; check how the shared type names are reconciled before [C2](#c2-the-schema-and-the-resolvers) lands.
- **A spec that already declares a reserved name.** None in this repo does. A downstream
  application that does gets a compile error with a rename suggestion, which is the point, but
  the release notes must say it.
