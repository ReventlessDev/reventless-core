# Plan: IAM-safe identity access in AppSync mutation/command resolvers

> **Status: Done.** Implemented in `invokeCommandGenerator` and `invokeDcbMutation`
> ([AppSync_Resolver_Functions.res](../../rescript/rescript-pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res))
> and `interceptorCode`
> ([QueryDbResolvers_AppSync.res](../../reventless/reventless-aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res)).
> `invokeInboundTranslation` was listed in the plan but does not emit an `identity`
> block — verified at the source — so it needed no change. New unit tests
> exercise Cognito, IAM, and null-identity paths via `aws-appsync/utils`-mocked
> evaluation.

## Problem

Three resolver-code generators in `AppSync_Resolver_Functions.res` build a `payload.identity` object by reading fields from `ctx.identity` directly:

- [invokeCommandGenerator](../../rescript/rescript-pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res#L794) (Aggregate command)
- [invokeDcbMutation](../../rescript/rescript-pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res#L821) (DCB mutation)
- [invokeInboundTranslation](../../rescript/rescript-pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res#L848) (inbound translation)

Each emits the same shape:

```js
meta: {
  ip: ctx.identity.sourceIp,
  user: ctx.identity.username,
  ...
},
identity: {
  userId: ctx.identity.sub,
  username: ctx.identity.username,
  groups: ctx.identity.claims?.['cognito:groups'] ?? [],
  claims: ctx.identity.claims,
  provider: 'Cognito'
}
```

`ctx.identity` is null/undefined for `AWS_IAM`-authenticated requests — `sub` and `claims` are Cognito-only fields. Direct property access throws `TypeError: Cannot read property 'claims' of undefined` at runtime, and AppSync silently surfaces this as `Cannot return null for non-nullable type: 'String'` to the caller (the actual exception is never propagated to the GraphQL response).

Confirmed via `aws appsync evaluate-code` against the deployed resolver code with `identity: null` — same TypeError.

The resolvers shipped with `provider: 'Cognito'` hardcoded, so the contract was clearly built for Cognito-authenticated traffic. But every plugin's deploy-time sync hooks call these mutations from a Lambda using IAM-signed HTTP — Cognito identity is not available there. So the `AWS_IAM` path is silently broken for every API that uses these generators.

## Scope

- File: [rescript/rescript-pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res](../../rescript/rescript-pulumi-aws/src/AppSync/AppSync_Resolver_Functions.res) — three template literals in `invokeCommandGenerator`, `invokeDcbMutation`, `invokeInboundTranslation`.
- Same pattern in [reventless-aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res:25-47](../../reventless/reventless-aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res#L25-L47) (`interceptorCode`) — query interceptor; only invoked when a query interceptor is configured, so likely not exercised in IAM-only stacks today, but same fix applies preemptively.
- Lambda handlers downstream of these resolvers must keep accepting the existing payload shape — this change is purely additive on the resolver side.

## Approach

Replace direct field access with optional chaining (already supported by APPSYNC_JS — the existing `ctx.identity.claims?.['cognito:groups']` proves it). Detect provider from what's actually present in `ctx.identity`:

```js
import { util } from '@aws-appsync/utils';
export function request(ctx) {
  const id = ctx.identity;
  // Cognito identity has `sub`; IAM identity has `userArn` / `accountId`.
  const isCognito = id != null && id.sub != null;
  return {
    operation: 'Invoke',
    payload: {
      command: '${command}',
      arguments: ctx.args,
      meta: {
        ip: id?.sourceIp ?? null,
        user: id?.username ?? null,
        info: ctx.info.parentTypeName + '.' + ctx.info.fieldName
      },
      identity: isCognito
        ? {
            userId: id.sub,
            username: id.username,
            groups: id.claims?.['cognito:groups'] ?? [],
            claims: id.claims,
            provider: 'Cognito'
          }
        : id != null
          ? {
              userArn: id.userArn ?? null,
              accountId: id.accountId ?? null,
              username: id.username ?? null,
              provider: 'IAM'
            }
          : null
    }
  };
}
```

`provider: 'IAM'` lets downstream Lambdas authorise based on the IAM principal when needed. `provider: null` (when `ctx.identity` is entirely absent) lets API_KEY / unauthorised paths flow through as well.

Three places to change in `AppSync_Resolver_Functions.res`; one in `QueryDbResolvers_AppSync.res`. No SDL changes; no Lambda contract changes (extra fields are tolerated, and `Cognito`-shaped consumers continue to receive the same keys when the request is Cognito-authenticated).

## Validation

1. `aws appsync evaluate-code` with `identity: null` → no TypeError, returns the request payload with `identity: null`.
2. Same with a synthetic Cognito identity → `provider: 'Cognito'` and existing fields populated.
3. Same with a synthetic IAM identity (`{userArn, accountId, sourceIp, username}`) → `provider: 'IAM'` and IAM fields populated.
4. Snapshot/unit test: extend any existing AppSync_Resolver_Functions test that snapshots the emitted code for these three generators.
5. Smoke: deploy a stack with `authenticationType: AWS_IAM`, run a SyncX mutation via IAM-signed HTTP, observe a non-null String result instead of `Cannot return null`.

## Out of scope

- AppSync logging configuration changes (the silent error surface is an AppSync defaults issue, not a generator one).
- Reworking `provider: 'Cognito'` into a configurable enum / removing the field — current downstream Lambdas only inspect `userId`/`username`, so the additional `IAM` branch is sufficient without a broader auth-model refactor.
- `interceptorCode` is included for symmetry; if a query interceptor is configured on an IAM-only API, it has the same bug.
