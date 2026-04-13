# Dual AWS provider: `@pulumi/aws` + `@pulumi/aws-native`

Reventless's AWS adapters use **two** Pulumi AWS providers in the same
deployment:

| Provider | Used for | Why |
|---|---|---|
| `@pulumi/aws` (classic) | Everything by default — DynamoDB, Lambda, SQS, SNS, S3, IAM, AppSync API/DataSource/Function, etc. | Mature, Terraform-bridged, broad coverage. The Pulumi-recommended primary provider. |
| `@pulumi/aws-native` (Cloud Control) | Narrowly: `appsync.Resolver` only. | Cloud Control's CFN handler waits server-side for schema → resolver propagation, eliminating a known race that surfaces as `NotFoundException: No field named X`. |

This matches Pulumi's official guidance: *use `@pulumi/aws` as the
backbone; reach for `@pulumi/aws-native` only when a specific resource
benefits from Cloud Control semantics*.

## The AppSync resolver creation race

When Reventless deploys an AppSync GraphQL API, it pushes the SDL via
`StartSchemaCreation` (AWS SDK) and creates one resolver per top-level
Query field. With the classic `@pulumi/aws` provider, resolver creation
occasionally raced ahead of schema-field propagation inside AppSync's
control plane and failed with:

```
NotFoundException: No field named X found on type Query
```

Resolvers are now created via `@pulumi/aws-native` (Cloud Control API)
instead. Cloud Control hands the request to the `AWS::AppSync::Resolver`
CloudFormation handler, which waits server-side for the field to be
visible before reporting success.

Empirical validation: 25 deploys (5× `eu-west-1` + 5× `us-east-1`, each
up + destroy) of a smoke-test stack succeeded with **zero post-`ACTIVE`
sleep** between schema push and resolver creation.

## Where the line is drawn

- **Bindings** — both providers have ReScript bindings in
  [`rescript-pulumi-aws`](../../rescript/rescript-pulumi-aws/). Classic
  bindings live in `src/AppSync/`, `src/DynamoDb/`, etc. The native
  binding sits under `src/AwsNative/AppSync/` and is exposed as
  `PulumiAws.AwsNative.AppSync.Resolver`.
- **Adapter** — [`AppSync_Resolver_Native.res`](../../reventless/reventless-aws/src/adapter/Api/AppSync_Resolver_Native.res)
  preserves the call shape of the classic `Resolver` module
  (`makeUnitJsResolver`, `makePipelineJsResolver`) so call sites are
  agnostic to the underlying provider.
- **Wiring** — [`QueryDbResolvers_AppSync.res`](../../reventless/reventless-aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res)
  shadows `Resolver` with the native adapter:
  ```rescript
  open PulumiAws.AppSync           // Function, DataSource, GraphQLApi
  module Resolver = AppSync_Resolver_Native
  ```
- **AppSync `Function`** stays on classic. Functions don't reference schema
  field names at create time, so they don't hit the propagation race.
  Pipeline resolvers extract `functionId` outputs from classic Functions
  and pass them into the native `pipelineConfig.functions` array — Pulumi
  supports crossing provider boundaries this way.

## State migration on first deploy after the switch

The first `pulumi up` after the migration **forces a replace** of every
existing resolver — Pulumi sees the resource type change from
`aws:appsync/resolver:Resolver` to `aws-native:appsync:Resolver` and has
no adoption alias to bridge them. Resolvers are stateless configuration;
the brief gap (a few seconds while the old resolver is deleted before
the new one is created) means in-flight queries against affected fields
fail until the new resolver lands. No data loss.

If you ever need a zero-downtime migration in a future move, add a
`Pulumi.Alias` referencing the old resource type to the new resource's
options.

## What to do if the race resurfaces

1. **Confirm the symptom.** `NotFoundException: No field named X` in the
   Pulumi update log under an `aws-native:appsync:Resolver` resource.

2. **Identify the field.** The resource name in the Pulumi log is the
   resolver's `name` (e.g. `MyReadModelByIdResolver`). The failing
   GraphQL field is in the error message itself.

3. **Short-term workaround — reinstate a sleep.** Add a fixed wait after
   `StartSchemaCreation` reaches `ACTIVE` in
   [`AppSync_Adapter.res`](../../reventless/reventless-aws/src/components/Api/AppSync_Adapter.res)
   inside `waitForSchemaActive` (e.g. 15 s `setTimeout` in the
   `ACTIVE` / `SUCCESS` branch). Redeploy.

4. **File an issue.** Open a ticket against `pulumi-aws-native` with
   the stack trace and Pulumi version. The whole point of using Cloud
   Control here is that the CFN handler waits internally; if it stops
   doing so, that's an upstream regression worth reporting.

5. **Fall back if needed.** If the upstream regression persists, the
   alternative is a custom Pulumi dynamic resource that wraps
   `@aws-sdk/client-appsync` directly with retry-on-`NotFoundException`
   classifier (`exn.name === "NotFoundException"` AND `exn.message`
   contains `"No field named"`) and exponential backoff (2 s → 4 s →
   8 s → 16 s → 32 s, capped ~3 min). Pulumi dynamic resources accept
   aliases, so it can adopt existing native resolvers without forcing
   another replace cycle.

## When to extend the native surface

Add a new `aws-native` binding only when:

1. The classic resource has a known, reproducible problem (race, slow
   eventual consistency, missing feature).
2. The Cloud Control / CFN handler demonstrably solves it (verify with
   a smoke test in two regions).
3. The slowdown is acceptable (Cloud Control adds ~5–15 s per resource).

Otherwise default to `@pulumi/aws`.

## References

- Migration plan: [`docs/plans/appsync-resolver-aws-native.md`](../plans/appsync-resolver-aws-native.md)
- [Pulumi: aws-native overview](https://www.pulumi.com/registry/packages/aws-native/)
- [`AWS::AppSync::Resolver` CloudFormation resource](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-appsync-resolver.html)
