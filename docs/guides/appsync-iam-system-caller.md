# AppSync: IAM auth for deploy-time system callers

Reventless platform APIs are provisioned as **multi-auth** AppSync APIs:

- **primary:** `AMAZON_COGNITO_USER_POOLS` (the console UI)
- **additional:** `AWS_IAM` (server-to-server / deploy-time callers)

`Util_AppSync_Caller` (`reventless-aws/src/util/Util_AppSync_Caller.res`) is the
deploy-time GraphQL client. It signs requests with SigV4 using the ambient AWS
credentials of the deploy process (developer machine, CI role, or instance
profile) — i.e. it authenticates via the `AWS_IAM` provider.

## Why a field needs an explicit `@aws_iam` directive

On a multi-auth AppSync API a field is reachable by a given auth mode **only if
it carries that mode's directive**. By default the AWS adapter stamps every
group-gated mutation/query with the Cognito-only directive:

```graphql
Platform_SyncComponent(...): CommandResult @aws_cognito_user_pools(cognito_groups: ["Admin"])
```

That admits the console UI and nothing else. No field carries `@aws_iam`, so the
IAM caller is `Unauthorized` on every field:

```
errorType: Unauthorized
"Not Authorized to access <Field> on type Query|Mutation"
```

> **Not `@aws_auth`.** The single-mode `@aws_auth(cognito_groups: [...])` form
> admits neither IAM *nor* — on a multi-auth API — anyone at all: AppSync ignores
> it outright, and `defaultAction: ALLOW` then opens the field to every
> authenticated Cognito user. The adapter emitted that form until the fix in
> `docs/plans/done/appsync-group-authorization-unenforced.md`; every group gate was
> inert. If you see `@aws_auth` anywhere in a deployed SDL, it is gating nothing.

## Opting a field into dual-auth (Cognito + IAM)

### Plugin slices — `@@reventless.systemCallable`

For a plugin's **StateChangeSlice** (command mutation) or **StateViewSlice /
StateViewSliceStream** (single-id + list queries), add the file-level attribute
to the spec file:

```rescript
// StateChangeSlice/SyncComponent.res
@@reventless.spec
@@reventless.systemCallable

@schema type command = ...
```

The plugin generator reads the attribute from the raw source (like
`@@reventless.async`) and threads the component's spec name as
`~systemCallableComponents` on the generated `Platform.Plugin.make(...)` call;
`Dcb_Builder` sets `systemCallable: true` on the matching mutation / query schema
entries. Re-run `generate-plugin src/` (the `prebuild` script does this
automatically) and commit the regenerated `src/Plugin.res`.

### Framework-built entries — `systemCallable` on the schema entry

Where the schema entry is constructed by hand (framework/internal code), set
`systemCallable: true` on the field's schema entry
(`ReventlessInfra.Api.mutationSchemaEntry` / `querySchemaEntry`).

In both cases the AWS adapter appends the **IAM arm** to that field's directive:

```graphql
Platform_SyncComponent(...): CommandResult
    @aws_cognito_user_pools(cognito_groups: ["Admin"]) @aws_iam
```

- The `@aws_cognito_user_pools` arm preserves the field's existing Cognito group
  gating. When the field carries no group restriction (e.g. `AllowAuthenticated`),
  a bare `@aws_cognito_user_pools` keeps it open to any authenticated Cognito
  user.
- The `@aws_iam` arm admits the SigV4 system caller.

For the admin **base fragment** (pushed via `AppSync_Adapter.injectAwsAuthAll`),
pass `~iamFieldNames=[...]` to mark specific base fields dual-auth.

**Opt-in per field.** Only fields a system caller actually invokes should set
`systemCallable`. Every other field keeps its Cognito-only directive unchanged.
Subscriptions are never IAM-marked — the deploy caller does not subscribe — but
they do carry the Cognito group gate, since a subscription is a read.

## Security — constrain the IAM principal

`@aws_iam` on a field admits *any* IAM principal the API's resource policy
allows. Adding it to platform command mutations is a privilege surface. It
**must** be constrained by IAM scoping outside the schema:

1. **Least-privilege deploy-role policy.** Grant `appsync:GraphQL` only on the
   specific field ARNs the caller invokes, not `*`:

   ```
   arn:aws:appsync:<region>:<acct>:apis/<apiId>/types/Mutation/fields/Platform_SyncComponent
   ```

2. **API resource policy (recommended).** Attach a resource policy to the
   AppSync API restricting `AWS_IAM` access to the deploy role's ARN, so a
   different IAM principal in the account cannot reach the IAM-marked fields
   even if it holds a broad `appsync:GraphQL` grant.

3. **Resolver-level principal guard (optional, defense in depth).** Assert the
   caller identity inside the resolver.

This adapter emits the directive but does **not** provision the deploy-role
policy or the API resource policy — the deploy role ARN is not known at deploy
time and the scoping is an ops/account decision. Provision it alongside the
deploy role.

## Verification checklist

- Redeploy a plugin and confirm the deploy-time sync caller receives no
  `Unauthorized` for the IAM-marked fields.
- Confirm the console UI (Cognito) still authorizes the same fields.
- Confirm a non-deploy IAM principal is still denied (scoping holds).

## Related

- `appsync-caller-command-result-subselection` — the companion fix that lets the
  same mutations pass GraphQL *validation* (`CommandResult` union sub-selection).
  Both are required for a deploy-time IAM caller to invoke command mutations end
  to end.
