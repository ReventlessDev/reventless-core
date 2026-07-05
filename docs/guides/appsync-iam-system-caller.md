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
mutation/query with the single-mode Cognito directive:

```graphql
Platform_SyncComponent(...): CommandResult @aws_auth(cognito_groups: ["Admin"])
```

`@aws_auth(...)` is the *single-default-auth* form; it does **not** admit IAM.
No field carries `@aws_iam`, so the IAM caller is `Unauthorized` on every field:

```
errorType: Unauthorized
"Not Authorized to access <Field> on type Query|Mutation"
```

## Opting a field into dual-auth (Cognito + IAM)

Set `iamCallable: true` on the field's schema entry
(`ReventlessInfra.Api.mutationSchemaEntry` / `querySchemaEntry`). The AWS adapter
then emits the **multi-auth** directive form for that field instead of
`@aws_auth`:

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
`iamCallable`. Every other field keeps the single-mode `@aws_auth` form
unchanged. Subscriptions are never IAM-marked — the deploy caller does not
subscribe.

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
