/**
Deploy-time switch: an extension asks for query interception, and the framework
provisions whatever that costs.

`QueryDb_Callback.registerQueryInterceptor` is a runtime hook, and `RuntimeExtension`
made it reachable inside a deployed runtime. On a DynamoDB-backed read model there
was still nothing to reach: a top-level Query resolver talks to DynamoDB directly,
so no code of ours runs on a read at all. Something has to put a runtime in front
of the read, and that is a provisioning decision the extension cannot make for
itself — an AppSync Lambda data source needs the api handle and a service role,
both of which exist only inside the plugin build.

So the split follows `Monitoring` and `EventLogProvisioning`: **the extension
decides, the framework provisions.** An extension says only *that* interception
should happen; it names no data source, no api and no role, and writes nothing
provider-shaped. The framework already ships the handler
(`QueryInterceptor_Lambda` on AWS), so there is nothing left for a caller to
supply.

**Off by default, and silent when off.** No registration means no interceptor
runtime, no data source, unit resolvers exactly as before, and a byte-identical
code archive — the same guarantee the cold-start seam makes.

**It composes with `RuntimeExtension` without either knowing about the other.**
The interceptor runtime is built through the standard runtime builder, so
`Util_Bundle` bundles every registered extension's package into its archive and
`makeFromCodeAsset` writes `RUNTIME_EXTENSIONS`. An extension that registers its
interceptor in `onColdStart` is therefore carried into the interceptor runtime
with no second registration.

## What it costs, which is why it is opt-in

Interception puts a Lambda invocation in front of **every read** on a
DynamoDB-backed read model. Reads outrun writes by orders of magnitude, so this
is the most expensive thing the framework can be asked to switch on. Two
properties bound it:

- **It is a property of the read-model backend, not of the cloud.** A
  Postgres-backed read model already routes through a resolver Lambda, which
  consults the same hook, so interception there costs nothing extra. Only the
  DynamoDB direct-resolver path pays.
- **It is the only place a read can be refused.** Anything cheaper — a log
  subscription, a stream-fed counter — observes a read after the fact but cannot
  deny it. Where the requirement is enforcement rather than observation, this
  cost is the requirement's price rather than overhead.

Granularity is per-deployment, deliberately: an operator asking "what does
interception cost me" wants one answer, not one per component. Narrowing later is
additive (a predicate on the registration); widening a per-component switch is
not.

See `docs/plans/done/query-interception-provisioning.md`.
*/

let enabled = ref(false)

/**
Switch query interception on for this deployment. Must run before the
platform/plugin build in the deploy program (plain statement order — the switch is
read lazily at each provisioning site), exactly like `Monitoring.use`.

Registering the runtime interceptor itself stays separate and is the extension's
job, through `QueryDb_Callback.registerQueryInterceptor` — typically from a
`RuntimeExtension` cold-start hook. This call only provisions the path that lets
that hook be consulted on a read.
*/
let use = () => enabled := true

/** Whether interception was asked for. Consulted by the provisioning sites. */
let isEnabled = () => enabled.contents

/** Tests only — the switch is process-global, so a test that flips it must put it
    back. */
let reset = () => enabled := false
