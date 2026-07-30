# Plan (Backlog): retry AppSync data-source creation on the schema-altering 409

**Status:** Backlog (not started) — recorded latent race, deliberately not fixed.

**Origin:** [done/new-plugin-stack-create-path.md](../done/new-plugin-stack-create-path.md) defect 2.

**Trigger to pick this up:** a CI run failing `CreateDataSource` with
`ConcurrentModificationException: Schema is currently being altered`. The two original failures
shared a condition this plan's reproduction did not — the platform stack being created in the
same pipeline window. Until that recurs, the evidence is too thin to justify the work.

---

## The race

`aws:appsync:DataSource` creation fails with a 409 when AppSync's control plane is mid-schema-alteration:

```
AppSync: CreateDataSource, StatusCode: 409,
ConcurrentModificationException: Schema is currently being altered, please wait until that
is complete.  provider=aws@7.19.0
```

**It cannot be ordered away.** Everything a plugin builds is already gated on the subgraph schema
push — `schemaPushed` is an input to the `Output.all6` wrapping plugin construction in
`Plugin_Builder`, so nothing is created until `subgraph schema is ACTIVE`. The contention is with the
**asynchronous merged-API merge**, which keeps altering the schema well after the push reports done:
in the measured run the resolver 409s landed 47s and 68s after ACTIVE. There is no earlier gate to
depend on.

**And it cannot be configured away.** `aws:maxRetries` does not apply: `@aws-sdk/client-appsync`
models `ConcurrentModificationException` as `$fault: "client"` with no retryable marker, so neither
the SDK nor the Terraform provider under `aws:appsync:DataSource` retries it. This is exactly why
`AppSync_Resolver_Retrying` hand-rolls its own loop.

**Why resolvers survive and data sources are exposed.** Resolvers go through
`AppSync_Resolver_Retrying`, whose `isSchemaAlteringError` + `runWithRaceRetry` already absorb this
error (`attempt 1/8 failed, retrying in 2000ms`, then success). Data sources use the plain AWS
provider resource, so a 409 is fatal. Data sources are created in a narrow window right after the
gate and usually miss the merge window; resolvers are created deep inside it and hit it routinely.

## Shape of the fix

1. **Extract the retry machinery first.** Pull `runWithRaceRetry` and `isSchemaAlteringError` out of
   [AppSync_Resolver_Retrying.res](../../../reventless/aws/src/adapter/Api/AppSync_Resolver_Retrying.res)
   into a shared module. Most of that file's 653 lines are its six-field SDK surface, not the retry
   logic — a third hand-rolled copy (after the resolver and source-api-association providers) would be
   the wrong shape.
2. **Add a thin `AppSync_DataSource_Retrying` dynamic provider** on top of it: create / update / delete /
   diff over the data-source SDK surface, mirroring the existing two.
3. **Rewire ~10 `DataSource.make` call sites** (`QueryDbStorage_DynamoDb`, `QueryDbResolvers_AppSync`,
   `CommandGeneratorResolvers_AppSync`, `InboundTranslationResolvers_AppSync`, `PgQueryResolver_Builder`,
   `Platform_UIFragments_Lambda`, `Platform_ComponentDefinitions_Lambda`, `ClonerRunner_Fargate`).

## Verification

Not by a green deploy — see the lesson in the origin plan. Create `catalog-aws/pr-verify` from scratch
*while* `platform-aws/pr-verify` is being created, so the merge window is genuinely open, and confirm
the retry log line appears for data sources rather than a failure.
