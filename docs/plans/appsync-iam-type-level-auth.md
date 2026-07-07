# AppSync IAM dual-auth: type-level directives + derived query fields

**Status:** In progress — 2026-07-07
**Owner:** Martin
**Follows:** `done/appsync-iam-auth-for-deploy-callers.md` (field-level mechanism, `94037f17a`) and the `@@reventless.systemCallable` slice opt-in (`c5ed53730`).

## The gap (verified live)

With the shipped chain fully deployed (spec attribute → `~systemCallableComponents`
→ entry `systemCallable` → dual-auth FIELD directives on the pushed schema), a
SigV4 system caller still cannot use a marked field. Probing a live multi-auth API
with `Util_AppSync_Caller` itself:

```
query { Platform_PlatformOverviews { edges { node { pluginName } } } }
→ "Not Authorized to access edges on type Platform_PlatformOverviewConnection"
```

Two distinct holes:

1. **Type-level authorization.** On a multi-auth AppSync API, object TYPES without
   auth directives are accessible only via the default auth mode (Cognito). The
   field directive admits the IAM caller to the top-level field, but response
   shaping then walks `…Connection` → `…Edge` → the node type → nested state
   types → shared `PageInfo` / `CommandResult` members — every one of them
   default-mode-only today, so the traversal dies one level in. Every read fails;
   every mutation's `{ __typename }` selection on `CommandResult` fails the same
   way. This is why the deploy-time sync has never landed a row even after the
   field fix.
2. **Derived query fields.** `systemCallable` stamps only `singleFieldName` +
   `listFieldName`. The generator also derives `${singleFieldName}Items` (sub-id
   projections), `${listFieldName}ByIds`, and `${singleFieldName}By<Index>` (GSI)
   query fields — none are stamped, and reconcile callers use exactly these
   (verified live: the Items field of a composite-key view).

## Fix

All in `reventless-aws` (`AppSync_Adapter`); the API always configures AWS_IAM as
an additional auth provider, so the directives are always valid.

1. **`injectAwsAuth` — field prefixes.** For a `systemCallable` query entry, mark
   fields by PREFIX (`singleFieldName`, `listFieldName`) instead of the two exact
   names: every derived field shape starts with one of them (`…Items`, `…By<Index>`
   with the single name; `…ByIds` with the list name). Mutations keep exact names.
2. **`injectAwsAuth` — per-view type stamping.** Stamp
   `@aws_cognito_user_pools @aws_iam` onto every `type` declaration in the
   fragment whose name starts with a `systemCallable` entry's `returnTypeName`
   (covers the node type, `…Connection`, `…Edge`, and nested state types, which
   the generator names by that prefix). Only `type` declarations — `input`/`enum`
   take no auth directives. Bare `@aws_cognito_user_pools` (no groups) matches the
   pre-existing accessibility of undirectived types (any authenticated Cognito
   user); entry gating stays on the fields.
3. **`updateSchema` — shared traversal types, post-stitch.** `PageInfo` (stitcher
   relay base) and `CommandAccepted`/`CommandRejected`/`CommandPending` (fragment
   generator, deduped across fragments by the stitcher) must be stamped exactly
   once on the ASSEMBLED SDL — per-fragment stamping would be nondeterministic
   under stitcher dedupe. Pure `stampSharedIamTypes(sdl)` applied after
   `GraphQL_Stitcher.stitch`, unconditional.

Non-goals: interfaces (`Node`) and enums/inputs take no auth directives (AppSync
authorizes concrete object types); subscriptions stay single-mode; least-privilege
IAM policy remains the documented ops concern.

## Acceptance

- `AppSync_AdapterTest`: derived query fields (`Items`/`ByIds`/`By<Index>`) of a
  `systemCallable` view carry dual-auth; sibling non-callable fields do not.
- Type declarations prefixed by a callable entry's `returnTypeName` carry
  type-level dual-auth; sibling view types do not.
- Assembled SDL from `stitch` carries dual-auth on `PageInfo` + `Command*` types.
- Live verification (downstream consumer): after redeploy, a SigV4
  `Util_AppSync_Caller` list query on a marked view returns data instead of
  `Not Authorized to access edges…`, and the deploy-time sync populates its
  read models.
