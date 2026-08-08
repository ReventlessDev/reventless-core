# Plan: Make query interception reachable in a deployed estate

**Status.** Implemented — 2026-08-08.

**Goal.** An out-of-tree package can switch query interception on for a deployment, and the
framework provisions whatever that costs. Today the hook exists, the handler exists, and nothing
can connect them.

**Non-goal.** Deciding *when* interception is worth its cost. That is a product decision belonging
to whatever registers the seam, exactly as `Monitoring` and `EventLogProvisioning` leave their own
activation to the extension.

---

## §1 — A hook, a handler, and no way to connect them

The framework ships both ends of query interception and no middle:

| Piece | Where | State |
| --- | --- | --- |
| The hook | `QueryDb_Callback.registerQueryInterceptor` | reachable at runtime — `RuntimeExtension` closed that gap |
| The handler | `reventless/aws/src/adapter/QueryDb/QueryInterceptor_Lambda.res` | shipped, dispatches to the hook |
| The wiring | `QueryDbResolvers_AppSync.queryInterceptorConfig` | **nothing in the repo ever sets it** |

`queryInterceptorConfig` is a `ref<option<{dataSourceName}>>`, and when set, every top-level Query
resolver becomes a pipeline resolver: interceptor Lambda, then the DynamoDB query
(`QueryDbResolvers_AppSync.res:109-140`). Its docstring says "Set this before calling `make`".

**That instruction cannot be followed from outside the framework.** The value is a *data-source
name*, and a data source can only be created with an API handle and a service role:

```rescript
DataSource.makeDynamoDBDataSourceWithTableName(~name, ~api, ~tableName, ~serviceRole=apiRole, ~opts)
```

Both are passed down by the plugin builder and exist only *inside* the plugin build — which is
after the moment the config has to be set. A deploy program can build the Lambda but has nowhere to
attach it, and `queryInterceptorConfig` is a single global ref while resolvers live on each
plugin's own source API, so one name could not serve them anyway.

The result: on a DynamoDB-backed read model, **nothing of ours runs on a read**, and the four-hook
runtime story has a hole exactly where per-request authorisation, rate limiting and request
accounting would sit.

## §2 — Why the extension should not supply the data source

The obvious seam — "let an extension hand us a data-source name" — is the wrong shape, for the
same reason `EventLogProvisioning` does not ask an extension to hand over a stream ARN:

- It pushes AppSync vocabulary into every package that wants interception, when the framework
  already owns that vocabulary everywhere else.
- The extension would need the api and role anyway, so the seam would have to hand them over —
  making the extension write framework-shaped infrastructure with framework-internal handles.
- One data source per plugin API means the extension would have to know the API topology, which is
  precisely the knowledge the plugin builder exists to encapsulate.

**The framework already ships the handler**, so the extension has nothing provider-shaped to
contribute. It only needs to say *that* interception should happen, and to register the runtime
hook it already can.

## §3 — The shape: the framework provisions, the extension decides

A deploy-time registration in the established pattern (`Monitoring`, `EventLogProvisioning`,
`RuntimeExtension`): an extension calls it before the platform/plugin build; core reads it lazily at
each provisioning site.

```rescript
// reventless/core/src/adapter/QueryInterception/QueryInterception.res
let use: unit => unit      // switch interception on for this deployment
let isEnabled: unit => bool
let reset: unit => unit    // tests only
```

When enabled, the AppSync read-model adapter provisions, **per plugin API**, an interceptor Lambda
from the handler it already ships plus its Lambda data source, and sets `queryInterceptorConfig`
itself. No call site outside that adapter changes, and nothing outside the framework touches
AppSync.

**It composes with the cold-start seam rather than duplicating it.** If the interceptor Lambda is
built through the standard runtime builder, `Util_Bundle` already bundles every registered
extension's package into its archive and `makeFromCodeAsset` already writes `RUNTIME_EXTENSIONS`.
So an extension that registers a query interceptor in `onColdStart` is carried into the interceptor
runtime with no further work — the two seams meet without knowing about each other.

**Off by default, and silent when off.** No registration means no Lambda, no data source, unit
resolvers exactly as today, and a byte-identical archive — the same guarantee the cold-start seam
makes.

## §4 — The cost, which is the whole reason this is opt-in

Interception puts a Lambda invocation in front of **every read** on a DynamoDB-backed read model.
Reads outrun writes by orders of magnitude, so this is the most expensive thing the framework can
be asked to switch on, and the plan should say so where an operator will read it.

Two properties bound it, and both belong in the seam's documentation rather than in a consumer's
head:

- **It is a property of the read-model backend, not of the cloud.** A Postgres-backed read model
  already routes through a resolver Lambda (`PgQueryResolver_Lambda.res:133` consults the same
  hook), so interception there costs nothing extra. Only the DynamoDB direct-resolver path pays.
- **It is the only place a read can be refused.** Anything cheaper — a log subscription, a
  stream-fed counter — can observe a read after the fact but cannot deny it. If the requirement is
  enforcement rather than observation, this cost is the requirement's price, not overhead.

## §5 — Granularity, deliberately left coarse

Per-deployment, not per-plugin or per-read-model. A finer switch is arguable, but:

- the ref it feeds (`queryInterceptorConfig`) is global today, so per-plugin would be a second
  change to a second subsystem;
- an operator reasoning about "what does interception cost me" wants one answer, not one per
  component;
- narrowing later is additive (a predicate on the registration), while widening a per-component
  switch to a global one is not.

Revisit when something needs interception for one read model and not another — not before.

## §6 — Acceptance

- An out-of-tree package can switch interception on from a deploy program without naming an
  AppSync data source, an api or a role.
- With it on, a top-level Query resolver is a pipeline resolver and a registered interceptor hook
  observes the read; a `Deny` refuses it.
- With it off, resolvers are unit resolvers, no interceptor Lambda or data source exists, and the
  archive is unchanged.
- An extension registering the hook in `onColdStart` reaches the interceptor runtime with no extra
  registration — the composition in §3 holds end to end.
- Several plugins in one deployment each get a working interceptor on their own API.
- A Postgres-backed read model is unaffected either way.

---

## §7 — What was built, and what the shape cost

`ReventlessCore.QueryInterception` (`use` / `isEnabled` / `reset`) is the seam;
`QueryInterceptor_Provisioning` is the AWS half that reads it and provisions the runtime, its
execution role, the AppSync Lambda data source and the role that lets AppSync invoke it.
`QueryDbResolvers_AppSync` asks that module for a data source instead of reading a ref.

**`queryInterceptorConfig` is gone rather than set.** §3 said the framework would set it, but §1's
own observation rules that out: it is one global ref and resolvers live on each plugin's own api, so
no single value can serve a stack with several plugins. The provisioning module returns the data
source for *this* resolver's plugin instead, which is the same decision made per-api.

**The memo is keyed on the api handle by identity, and named from the owning plugin.** Keying it on
the plugin was the first attempt and it is wrong in a way previews would not have caught: the
platform stack routes everything built outside a plugin construct into one bucket, and the moment
that bucket spans two apis a resolver names a data source that does not exist on its api — rejected
at deploy time, with nothing in the message pointing here. The api's *contents* are an `Output` and
unknown at resolver-construction time, but the handle itself is a value the builders thread
unchanged through every read model on that api, so object identity is an exact key. The ambient
`ResourceAttribution` plugin supplies only the resource names, which is presentation. That context
is reliable inside the deferred apply where resolvers are built only because of
`docs/plans/done/attribution-across-the-deferred-finish.md` — this plan quietly depends on that one.

### Verified by preview, not by reading

Enabling it in the catalog plugin stack and running `pulumi preview` plans exactly:

```
+ aws:lambda:Function     CatalogQueryInterceptor
+ aws:iam:Role            CatalogQueryInterceptor
+ aws:cloudwatch:LogGroup CatalogQueryInterceptorLogGroup
+ aws:iam:Role            CatalogQueryInterceptorDataSource
+ aws:appsync:DataSource  CatalogQueryInterceptorDataSource
+ 24 aws:appsync:Function        (two per Query field)
+-12 resolvers to replace        (unit → pipeline)
```

One interceptor for all twelve read models, named for its plugin — the "per plugin api, not per
read model" property, observed rather than argued. The log group and the IAM role come from
`RuntimeEnvironment_Lambda.makeFromCodeAsset`, which is also what carries `RUNTIME_EXTENSIONS` and
the bundled extension packages into the archive, so §3's composition holds by construction. With
the switch removed the same stack plans no interceptor resources at all and the resolvers stay
unit resolvers.

### One thing acceptance §1 does not say

A deploy program reaches the switch through `reventless-core`, so a package that depends only on
`reventless-aws` cannot call it — the example stacks needed `@reventlessdev/reventless-core` added
to their `rescript.json` to switch it on. This is not a new constraint (`Monitoring.use`,
`RuntimeExtension.use` and `registerQueryInterceptor` itself all live in core, so any extension
already depends on it) but it is worth stating, because "an out-of-tree package can switch it on"
reads as if no dependency were involved.

---

## Appendix: code anchors (2026-08-08)

| Fact | Anchor |
| --- | --- |
| The config nothing sets | `reventless/aws/src/adapter/QueryDb/QueryDbResolvers_AppSync.res:23` |
| Unit vs pipeline resolver, chosen on it | `QueryDbResolvers_AppSync.res:109-140` |
| Data sources need api + service role | `QueryDbResolvers_AppSync.res:366-372` |
| The shipped interceptor handler | `reventless/aws/src/adapter/QueryDb/QueryInterceptor_Lambda.res` |
| The runtime hook it dispatches to | `reventless/core/src/components/QueryDb/QueryDb_Callback.res:10-16` |
| Postgres path consults the same hook for free | `reventless/aws/src/adapter/QueryDb/PgQueryResolver_Lambda.res:133` |
| Deploy-time seams this mirrors | `Monitoring.res`; `EventLogProvisioning.res` |
| Runtime seam it composes with | `reventless/core/src/adapter/RuntimeExtension/RuntimeExtension.res` |
