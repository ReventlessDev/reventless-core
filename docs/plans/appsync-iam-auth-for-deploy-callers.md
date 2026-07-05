# AppSync: IAM auth for deploy-time system callers

Scope: let `Util_AppSync_Caller` (the IAM-SigV4 deploy-time GraphQL client) actually
invoke fields on a Cognito-primary AppSync API. Today it is `Unauthorized` for
**every** field because the SDL auth injection only emits Cognito directives.

## Status: mechanism DONE + plugin-slice opt-in plumbing DONE — downstream verification PENDING

Shipped the opt-in per-field dual-auth **mechanism** (below) and the **slice-level
opt-in plumbing** (see "Opt-in plumbing (shipped)"). A downstream plugin now opts
its StateChangeSlice / StateViewSlice fields in with the file-level attribute
`@@reventless.systemCallable` on the spec file plus a plugin regeneration. What
remains is step 3 of the former gap list: the end-to-end verification against the
live API from the downstream repo (PlatformInspector marks its `Platform_Sync*`
slices + reconcile read views, redeploys, and confirms the SigV4 caller is no
longer `Unauthorized`). Zero change to any existing field's directive.

- `reventless-infra/src/components/Api.res` — added `systemCallable?: bool` to
  `mutationSchemaEntry` and `querySchemaEntry`.
- `reventless-aws/src/components/Api/AppSync_Adapter.res` — `injectAwsAuth` now
  emits the multi-auth form `@aws_cognito_user_pools(cognito_groups: [...])
  @aws_iam` for `systemCallable` fields (bare `@aws_cognito_user_pools` when the
  field carries no Cognito group restriction), keeping `@aws_auth(...)` for every
  other field. `injectAwsAuthAll` gained `~iamFieldNames` for the admin base
  fragment. New `_formatDualAuthDirective` helper.
- `reventless-aws/tests/AppSync_AdapterTest.res` — 6 new tests (28 total, green).
- `docs/guides/appsync-iam-system-caller.md` — how to opt fields in, the emitted
  directive form, and the required IAM scoping.

**Directive-form decision.** `@aws_auth(...)` is the single-mode form and does not
admit IAM on a multi-auth API, so IAM-marked fields use the guaranteed-correct
multi-auth `@aws_cognito_user_pools(...) @aws_iam` form. Non-IAM fields are left
on `@aws_auth` (their existing, working behavior). Confirm the multi-auth form
against the live API on the first downstream field that opts in.

**Security scoping — documented, not provisioned.** Per decision, the adapter
emits the directive but does not provision the deploy-role policy or an AppSync
API resource policy (the deploy role ARN is not known at deploy time; it's an ops
decision). Scoping requirements are in the guide.

## Opt-in plumbing (shipped)

The spec-level knob is the file-level attribute **`@@reventless.systemCallable`** on
StateChangeSlice and StateViewSlice (incl. Stream) spec files. It deliberately does
NOT extend the `Spec` module type (the `commandAuthorization` precedent): a new
required Spec field needs a PPX auto-injection, and any PPX change is blocked on a
`reventless-ppx` republish before CI can pass. Instead it mirrors the
`@@reventless.async` shape — generator-read from raw source — with one improvement:
no PPX consumption is required at all (verified: the current published PPX passes
the unknown attribute through and the compiler ignores it with zero warnings), so
the plumbing ships entirely from this repo.

- `reventless-spec/src/generator/Pairing.res` — `hasSystemCallableAttribute` (shared
  `hasFileAttribute` helper with `hasAsyncAttribute`); StateViewSlice(+Stream)
  relPaths now tracked; new `resolved.systemCallableComponents` (sorted effective spec
  names — the explicit `@@reventless.spec("Name")` payload when present, else the
  stem, so name-overridden specs don't silently miss).
- `reventless-spec/src/generator/Codegen.res` — emits
  `~systemCallableComponents=["..."]` on `Platform.Plugin.make(...)` only when at
  least one component opts in, so existing generated `Plugin.res` files stay
  byte-identical.
- `reventless-infra/src/components/Plugin.res` + core `Plugin.res` module type —
  `Plugin.T.make` gained optional `~systemCallableComponents: array<string>=?`.
- `Plugin_Builder.res` — threads it through `make` → `construct` →
  `DcbBuilder.construct` (both AWS and local platforms `include` this builder, so
  one implementation covers both; local ignores the flag downstream).
- `Dcb_Builder.res` — `construct(~systemCallableComponents=[])` stamps
  `systemCallable: <name match>` on `mutationEntriesFromSlices` (StateChangeSlice
  command mutations) and `stateViewEntries` (StateViewSlice single+list queries).
  The plugin-deploy fragment injection already calls `injectAwsAuth`, which reads
  `entry.systemCallable` — no further wiring in the deploy path.
- `packages/reventless-ppx/src/ppx/ReventlessPpx.ml` — `reventless.systemCallable`
  added to the strip list for hygiene (takes effect on the next ppx republish;
  not required for correctness since pass-through is harmless).
- Docs: `docs/guides/appsync-iam-system-caller.md` (attribute how-to) and
  `.claude/rules/app-developer.md` (PPX annotations list).

Out of scope, unchanged: InboundTranslationSlice mutations, AutomationSlice /
translation-slice audit queries, and Aggregate/ReadModel fields — none are
deploy-time sync targets today; the entry fields exist if they ever need it.

**Remaining — verify end-to-end downstream.** PlatformInspector (business repo)
marks its deploy-time-invoked slices with `@@reventless.systemCallable`, regenerates,
redeploys against a framework version carrying this plumbing, and confirms the
SigV4 sync caller is no longer `Unauthorized` (Verification section below).

The security scoping (least-privilege deploy-role IAM policy / API resource policy)
remains an ops concern as documented — unchanged by the above.

---
(original design below)

## The bug

`Util_AppSync_Caller.sendQuery` / `sendMutation` sign requests with SigV4 using the
ambient deploy-process credentials (`@aws-sdk/credential-provider-node`), i.e. the
**AWS_IAM** auth mode. Against a platform AppSync API configured as:

- primary auth: `AMAZON_COGNITO_USER_POOLS`
- additional auth: `AWS_IAM`

every request from this caller returns:

```
errorType: Unauthorized
"Not Authorized to access <Field> on type Query|Mutation"
```

Observed for both query fields and mutation fields — the caller can reach nothing.

## Root cause

`AppSync_Adapter.injectAwsAuthAll` (and the per-field `injectAwsAuth`) stamps every
mutation/query/subscription field with **only**:

```
@aws_auth(cognito_groups: ["<group>"])
```

On a multi-auth API, a field is reachable by a given mode **only if** it carries that
mode's directive. No field carries `@aws_iam`, so the additional `AWS_IAM` provider is
never actually usable — the deploy-time IAM caller is denied everywhere.

Two coupled facts:
1. `injectAwsAuthAll` never emits `@aws_iam`.
2. `@aws_auth(...)` is the *single-default-auth* directive form; with multiple auth
   modes AppSync expects `@aws_cognito_user_pools(cognito_groups: [...])` **plus**
   `@aws_iam` to admit both. (Verify against the current API's auth config before
   implementing — the exact directive form matters.)

## Design

Give the framework a way to mark the specific fields a deploy-time system caller must
invoke as **dual-auth**: Cognito (for the console UI) *and* IAM (for the deploy
process). Sketch:

- Extend `AppSync_Adapter` with a selective injection (e.g. `injectAwsIam(fragment,
  ~fields)` or an `~alsoIam: bool` / field-predicate on `injectAwsAuthAll`) that adds
  `@aws_iam` to the chosen fields, and switches their Cognito directive to the
  multi-auth form if required (point 2 above).
- Keep it **opt-in per field**, not blanket — only the fields a system caller invokes
  should gain `@aws_iam`.

### Security — do NOT expose platform mutations to arbitrary IAM

`@aws_iam` on a field admits *any* IAM principal the API resource policy allows. Adding
it to platform command mutations is a privilege surface. Constrain it:

- **Least-privilege IAM policy**: only the deploy role gets `appsync:GraphQL` on the
  specific field ARNs (`.../types/Mutation/fields/<Field>`), not `*`.
- Consider an **API resource policy** on the AppSync API restricting IAM access to the
  deploy role's ARN.
- Optionally a **resolver-level principal guard** (assert the caller identity in the
  resolver) for defense in depth.

The design must state which fields become IAM-callable and the exact IAM scoping, and
get reviewed as an auth change before shipping.

## Verification

- Redeploy a plugin and confirm the deploy-time sync caller receives no `Unauthorized`
  for the IAM-marked fields.
- Confirm the console UI (Cognito) still authorizes the same fields.
- Confirm a non-deploy IAM principal is still denied (scoping holds).

## Relationship to the CommandResult fix

Independent of, and beneath, the `CommandResult` sub-selection fix
(`appsync-caller-command-result-subselection`). That fix let the mutations pass GraphQL
validation; this one lets them pass authorization. Both are required for a deploy-time
IAM caller to successfully invoke command mutations end to end.
