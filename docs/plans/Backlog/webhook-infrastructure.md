# Backlog: Webhook Infrastructure for InboundTranslationSlice

**Status:** Backlog. Refreshed 2026-08-31 against the current tree — the original
draft predates the repo split, the two-file slice spec, and the generated inbound
mutation, and several of its steps were either already done or would now be wrong.
**Depends on:** [done/translation-slice.md](../done/translation-slice.md)
**Prior art:** [done/inbound-translation-slice-api-mutation.md](../done/inbound-translation-slice-api-mutation.md),
[done/aws-inbound-translation-lambda-routing.md](../done/aws-inbound-translation-lambda-routing.md),
[done/inbound-translation-mutation-result-type.md](../done/inbound-translation-mutation-result-type.md)
**Related:** [api-component-openapi.md](./api-component-openapi.md) (REST API Gateway)

## Motivation

An InboundTranslationSlice receives external input, validates it through an
anti-corruption layer, and publishes domain commands.

It is **already reachable**: every slice gets a generated GraphQL mutation
`<Plugin>_<Slice>`, whose arguments come from `@schema type externalInput` and
which returns `CommandResult!`. On AWS that is an AppSync DataSource + Resolver
onto the shared DCB CommandTopic Lambda (`InboundTranslationResolvers_AppSync`);
locally it is a field on the local GraphQL server
(`InboundTranslationResolvers_GraphQL`). No wiring is asked of the app author.

What is missing is a **URL**. A payment provider or a shipping carrier posts a
JSON body to an address you give it; it does not speak GraphQL and it cannot
present a Cognito token. So the remaining gap is narrower than "the component is
unreachable" — it is:

- no HTTP address for `receive`, and
- no authentication model that fits a third-party sender (see
  [Authentication](#authentication-is-the-hard-half) — this, not the Pulumi
  plumbing, is the part that needs a decision).

This plan adds an optional webhook endpoint to the InboundTranslationSlice spec
and the infrastructure to provision it, so that a slice that wants a URL gets one
without giving up the mutation it already has.

## What changed since the first draft

| Draft said | Now |
|---|---|
| The author must hand-wire a Lambda, an API Gateway route, **or a GraphQL mutation** | The mutation is generated on both platforms; only the URL is missing |
| Step 3: add `Lambda.FunctionUrl` bindings | **Done** — [rescript/pulumi-aws/src/Lambda/FunctionUrl.res](../../../rescript/pulumi-aws/src/Lambda/FunctionUrl.res), richer than the sketch (`invokeMode`, `qualifier`, `urlId`, `get`) |
| Step 4: add `ApiGatewayV2` bindings | Still absent — no `ApiGatewayV2` under `rescript/pulumi-aws/src/` |
| `let translate` and `module DcbEventLogSpec` on the Spec | `translate` lives on the `Translation` module (`<Name>_Translation.res`); there is no `DcbEventLogSpec` member |
| `translate: externalInput => result<(string, command), string>` | `result<array<(string, command)>, string>` — a translation may publish several commands, or none |
| `receive: JSON.t => promise<result<string, string>>` | `promise<result<acceptedResult, rejectedResult>>`, both arms carrying `requestId` |
| Lambdas via `aws.lambda.CallbackFunction` | **Must not** — see [Do not use CallbackFunction](#do-not-use-callbackfunction) |
| `reventless/reventless-spec`, `reventless-in-memory`, `rescript/rescript-pulumi-aws` | `reventless/spec`, `reventless/local`, `rescript/pulumi-aws` |
| `examples/dcb/ordering/src/Slices/` | `examples/online-shop-dcb/<plugin>/src/<Entity>/InboundTranslationSlice/` |

---

## Design

### Spec extension

A slice that wants no URL says nothing and pays nothing:

```rescript
type endpointMethod = POST | PUT

type authType =
  | Open
  | IAM
  | ApiKey(string)
  | SignedBody(signatureConfig)

type transportType = FunctionUrl | ApiGateway

type endpointConfig = {
  /** URL path segment, e.g. "payment-webhook". */
  path: string,
  /** Default: POST. */
  method?: endpointMethod,
  /** Default: Open — see the authentication section before choosing it. */
  auth?: authType,
  /** Default: FunctionUrl. */
  transport?: transportType,
}
```

```rescript
module type Spec = {
  let name: string
  let moduleUrl: string
  @schema type externalInput
  @schema type command
  let targetName: string
  let externalSystem: option<string>
  let commandAuthorization: command => Authorization.permission

  /** Auto-injected by `@@reventless.spec` as `None`, mirroring `externalSystem`. */
  let endpoint: option<endpointConfig>
}
```

**On `option<endpointConfig>` vs an optional field.** A ReScript `module type`
cannot declare an optional `let` — `let endpoint?: endpointConfig` is a syntax
error, and the repo has no such precedent. The `?` form is reachable only by
moving the member onto a record, and a one-field wrapper record earns nothing
here: the PPX injects the default either way, so neither form makes an author
write `None`, and the wrapper costs a nested record at the one site that does set
it (`{endpoint: {path: …}}` vs `Some({path: …})`). Option-typed it is —
consistent with `externalSystem: option<string>` two lines above it, and with
`subIdConfig` on the queryable specs.

**Worth considering instead: a file-level attribute.** A webhook endpoint is a
component-level infrastructure opt-in, which the repo already expresses as an
attribute the generator reads from raw source — `@@reventless.async`,
`@@reventless.systemCallable`:

```rescript
@@reventless.spec
@@reventless.webhook({path: "payment-webhook", transport: FunctionUrl})
```

That removes the question entirely at the authoring surface — a slice with no
endpoint carries no attribute and no `let` — and leaves `option<endpointConfig>`
as a purely internal representation nobody hand-writes. It costs a PPX change
and a republish, so it is a decision for step 1, not an implementation detail.

### Outputs extension

```rescript
type outputs = {
  resources: array<Adapter.resource>,
  queryDb: QueryDb.outputs,
  endpointUrl?: Pulumi.Output.t<string>,
}
```

Optional field, not `option<Pulumi.Output.t<string>>` — that combination is
called out in CLAUDE.md as one that does not work. Lets the deploy read the URL
back to register it with the provider.

### Both doors, one `receive` — and why the endpoint does not switch the mutation off

The endpoint is **additive**. The mutation is generated as it is today; declaring
an endpoint adds a URL beside it. It is not either/or, and the choice does **not**
belong inside `endpointConfig`.

Three reasons the endpoint must not suppress the mutation implicitly:

1. **The mutation is load-bearing.** The seed harness drives the supplier feed
   through `Catalog_ImportProduct`
   ([HybridSeedData.res](../../../examples/online-shop-hybrid/seed-data/src/HybridSeedData.res)
   `seedSupplierFeed`). A slice that traded its mutation for a URL would break
   seeding, replay and every GWT-adjacent path that posts external input directly.
2. **Local has no public URL.** The local platform provisions a route registry,
   not a reachable address. The mutation is the door that works in development on
   both platforms; making it conditional on production infrastructure inverts that.
3. **Adding a webhook would become a breaking schema change.** Removing a field
   from the SDL breaks open clients — and the shell reads schemas at runtime, so
   an already-open tab breaks the moment the SDL changes. "Add a URL" must not
   mean "withdraw a mutation".

**The two are independent axes** — API surface vs. transport — and the repo
already has a knob for the first: `@noApi`. Wire that for inbound slices (it is
read for StateChangeSlice commands and ignored for these) and all four
combinations are expressible, without `endpointConfig` knowing anything about
GraphQL:

| | no `endpoint` | `endpoint` declared |
|---|---|---|
| **default** | mutation only — today's behaviour | mutation **and** URL |
| **`@noApi`** | build error — unreachable slice | URL only, the pure webhook receiver |

For an inbound slice `@noApi` reads off `externalInputSchema`, not
`commandSchema`, since that is where the mutation's arguments come from.

### Consequences of two doors

Additive is the right default, but it is not free, and the implementation must
handle these rather than discover them:

- **Signature verification protects the URL only.** A slice with `SignedBody` and
  a default `commandAuthorization` of `AllowAuthenticated` can still be handed a
  forged payment confirmation by any signed-in caller through the mutation. A
  slice that has a URL should set `commandAuthorization` deliberately —
  `AllowGroups([...])` for an operator-only replay door, or `@noApi` for none at
  all. Consider warning at build time when a slice declares `SignedBody` and
  leaves `commandAuthorization` at the default.
- **The audit log sees both.** The audit row must record which door the input
  arrived through, or the log cannot answer "did the provider actually call us?"
- `requestId` must stay unique across both.

---

## Authentication is the hard half

The mutation answers under the slice's `commandAuthorization` (default
`AllowAuthenticated`). A URL has no such caller. The options are not equivalent
and the choice cannot be deferred to the implementer:

| `auth` | Who can call | Honest assessment |
|---|---|---|
| `Open` | Anybody on the internet | The slice's `translate` is the only gate. Every rejection still costs a Lambda invocation and an audit row — an open URL is a spend amplifier as much as a correctness risk. |
| `IAM` | SigV4 signers | Fine for AWS-internal senders; useless for a third-party SaaS. |
| `ApiKey(name)` | Bearer of a shared secret | API Gateway only. Better than open; the key is a static secret needing rotation. |
| `SignedBody(cfg)` | A sender holding the shared signing secret | **What real webhook providers actually do** (Stripe's `Stripe-Signature`, GitHub's `X-Hub-Signature-256`): HMAC over the raw body plus a timestamp, verified before parsing. Works on both transports because it is done in the handler, not the router. |

`SignedBody` did not exist in the first draft and is the reason this plan should
not be implemented as a straight Pulumi exercise. It also imposes a constraint on
the handler: signature verification needs the **raw** request body, so the
handler must verify before `JSON.parse`, not after.

Decide `SignedBody`'s shape (header name, algorithm, timestamp tolerance, secret
source — Secrets Manager vs an env var) before writing Step 5.

---

## Do not use CallbackFunction

The first draft's Steps 6 and 7 both created the webhook Lambda with
`aws.lambda.CallbackFunction`. That path is known-broken for anything touching
the AWS SDK: the serialized closure mixes the Lambda layer's `@smithy` versions
with the runtime's and fails at cold start with a 502. See
[task-sideeffect-callbackfunction-conversion.md](../task-sideeffect-callbackfunction-conversion.md)
and [done/entry-point-rescript-conversion.md](../done/entry-point-rescript-conversion.md).

Follow the established shape instead — a runtime-pure `*_Ops.res` module compiled
into an entry point and shipped via `buildCodeArchive`, exactly as
[Upload_Presign_S3](../../../reventless/aws/src/adapter/Upload/Upload_Presign_S3.res)
(+ `Upload_Presign_S3_Ops.res`) and
[Geocoder_AwsLocation_Resolver](../../../reventless/aws/src/adapter/Geocoder/Geocoder_AwsLocation_Resolver.res)
do. Keeping deploy-time Pulumi values out of the runtime graph is the whole point
of the split; a webhook handler that imports `@pulumi/pulumi` will not cold-start.

---

## AWS implementation: two transports

Both create a Lambda wrapping `receive` and differ only in the HTTP router.

### Approach A: Lambda Function URL (default)

```
External System
    ↓ POST https://{url-id}.lambda-url.{region}.on.aws/
Lambda Function URL  →  Webhook Lambda  →  receive(body)  →  translate → publishJsons → CommandTopic
```

| Resource | Type |
|---|---|
| Lambda Function | compiled entry point via `buildCodeArchive` |
| IAM Role | `aws.iam.Role` |
| Function URL | `aws.lambda.FunctionUrl` — binding exists |
| Permission | `aws.lambda.Permission` (only when `auth = Open`) |

**Pros:** minimal infrastructure, no extra service, no API Gateway cost, lower
latency. **Cons:** one URL per Lambda, no shared base URL, no custom domain
without CloudFront, auth limited to IAM or NONE at the router (which is why
`SignedBody` matters), no built-in throttling, auto-generated URL.

### Approach B: API Gateway HTTP API

```
External System
    ↓ POST /payment-webhook
API Gateway HTTP API  →  Lambda proxy integration  →  Webhook Lambda  →  receive(body)  →  …
```

| Resource | Type |
|---|---|
| Lambda + IAM Role | as above |
| HTTP API | `aws.apigatewayv2.Api` (shared) |
| Route | `aws.apigatewayv2.Route` — `POST /payment-webhook` |
| Integration | `aws.apigatewayv2.Integration` — `AWS_PROXY`, payload format `2.0` |
| Stage | `aws.apigatewayv2.Stage` — `$default`, auto-deploy |
| Permission | `aws.lambda.Permission` for `apigateway.amazonaws.com` |

**Pros:** one base URL for every webhook in a plugin, custom domains via Route 53
+ ACM, API keys / JWT authorizers, request validation, access logs, throttling.
**Cons:** more infrastructure, needs the missing `apigatewayv2` bindings, an extra
hop.

**Recommendation:** default `FunctionUrl`; reach for `ApiGateway` when you need a
custom domain, a unified base URL, or throttling. `transport` on the config picks.

---

## Local implementation

Start with a route registry — enough for tests, no server:

**New file:** `reventless/local/src/adapter/Webhook/LocalWebhookRegistry.res`
(`Local` prefix, no backend suffix — there is no in-memory/SQLite choice here;
see the backend-suffix convention in `.claude/rules/component-guidelines.md`.)

```rescript
type route = {
  method: string,
  path: string,
  handler: JSON.t => promise<ReventlessInfra.InboundTranslationSlice.receiveResult>,
}

let routes: ref<array<route>> = ref([])
let register = (~method, ~path, ~handler) => ...
let post = async (path, body) => ...
let reset = () => routes := []
```

Registration must be **two-phase**, mirroring `InboundTranslationResolvers_GraphQL`:
register the route synchronously with a queuing forwarder, bind the real `receive`
when the `Output` resolves, drain the parked calls. Without this a test that posts
before the platform settles hangs.

A real local HTTP server (Node `http`, routes mounted on the existing local
GraphQL server's port) can come later if anyone needs to point a tunnel at it.

---

## Implementation steps

| # | Step | File | State |
|---|---|---|---|
| 1 | Decide `SignedBody`'s shape, and `let endpoint` vs `@@reventless.webhook` | — | **Blocks 2–3 and 8–9** |
| 2 | Add `endpointConfig` + `let endpoint` to the Spec | `reventless/spec/src/components/InboundTranslationSlice.res` | |
| 3 | Inject `let endpoint = None` by default (or read the attribute, per step 1) | `reventless-ppx` (spec pass) | Republish in lockstep — an older published ppx omits the injection and every spec fails to compile against the new module type |
| 4 | Add `endpointUrl?` to outputs | `reventless/infra/src/components/InboundTranslationSlice.res` | |
| 5 | `Lambda.FunctionUrl` bindings | `rescript/pulumi-aws/src/Lambda/FunctionUrl.res` | **Done** |
| 6 | `ApiGatewayV2` bindings (`Api`, `Integration`, `Route`, `Stage`) | `rescript/pulumi-aws/src/ApiGatewayV2/` | Only for transport B |
| 7 | Webhook provider abstraction | `reventless/infra/src/components/Webhook_Adapter.res` | |
| 8 | Function URL provider (+ `_Ops` split) | `reventless/aws/src/adapter/Webhook/Webhook_FunctionUrl.res` | |
| 9 | API Gateway provider (+ `_Ops` split) | `reventless/aws/src/adapter/Webhook/Webhook_ApiGateway.res` | |
| 10 | Local registry | `reventless/local/src/adapter/Webhook/LocalWebhookRegistry.res` | |
| 11 | Thread the provider through the core builder | `reventless/core/src/components/InboundTranslationSlice/InboundTranslationSlice_Builder.res` | Note the **nested** `Make` and the `unit => api` thunks on the `Api` parameter |
| 12 | Wire AWS | `reventless/aws/src/components/InboundTranslationSlice_Builder.res`, `reventless/aws/src/Platform.res` | Shared HTTP API created once per plugin, only if some slice asks for transport B |
| 13 | Wire local | `reventless/local/src/components/InboundTranslationSlice_Builder.res`, `reventless/local/src/Platform.res` | |
| 14 | Honour `@noApi` on `externalInputSchema`; error when a slice has neither a mutation nor an endpoint | `reventless/core/src/components/Dcb/Dcb_Builder.res` (`inboundTranslationSliceData`, `mutationEntriesFromInboundSlices` — neither filters today) | |
| 15 | Record the door on the audit row | `reventless/core/src/components/InboundTranslationSlice/InboundTranslationSlice_Callback.res` | |
| 16 | Example slice with an endpoint | `examples/online-shop-dcb/<plugin>/src/<Entity>/InboundTranslationSlice/` | Two files: `<Name>.res` + `<Name>_Translation.res` |
| 17 | Tests | | See below |
| 18 | Docs | `packages/doc/docs-app/components/inboundtranslationslice.md` § "No HTTP endpoint yet — planned", `packages/doc/docs-app/graphql-api-guide.md` § 5.3 | Both currently state the gap; both must be rewritten when it closes |

### Builder wiring sketch (step 11)

The current functor is nested — an outer `Make` taking the adapters, an inner
`Make` taking `(Spec, Translation)`. The webhook provider is an outer parameter:

```rescript
module Make = (
  QueryDbStorage: QueryDb_Adapter.Storage,
  QueryDbResolvers: QueryDb_Adapter.Resolvers
    with type api = QueryDbStorage.api and type role = QueryDbStorage.role,
  Api: {
    let api: unit => QueryDbStorage.api
    let apiRole: unit => QueryDbStorage.role
  },
  Webhook: Webhook_Adapter.Provider,
) => {
  module Make = (
    Spec: Reventless.InboundTranslationSlice.Spec,
    Translation: Reventless.InboundTranslationSlice.Translation with module Spec := Spec,
  ): InboundTranslationSlice.T => {
    // ... existing audit QueryDb + receive wiring ...

    let endpoint = switch Spec.endpoint {
    | Some(cfg) => Some(Webhook.makeEndpoint(~name=Spec.name, ~cfg, ~handler=..., ~opts))
    | None => None
    }

    let outputs: InboundTranslationSlice.outputs = {
      resources: ...,
      queryDb: queryDb->Component.outputs,
      endpointUrl: ?endpoint->Option.map(e => e.url),
    }
  }
}
```

Platforms that provision no webhooks pass a no-op provider rather than making the
parameter optional — a functor parameter that is sometimes absent is worse than
one that sometimes does nothing.

### Tests (step 16)

- **Registry:** register → `post` invokes the handler; unknown route errors; calls
  placed before `bindReceive` drain afterwards; `reset` clears.
- **Local builder:** no `endpoint` ⇒ no `endpointUrl` and no route; with `endpoint`
  ⇒ both, and `post` reaches `translate` end to end.
- **Signature verification:** a valid HMAC passes; a wrong one, a replayed
  timestamp outside tolerance, and a body mutated after signing all reject —
  before parsing, and with an audit row.
- **Both doors:** the same input through the mutation and the URL produces the
  same commands and two distinguishable audit rows; a slice with `@noApi` and an
  endpoint exposes no mutation but still receives over the URL; a slice with
  `@noApi` and no endpoint fails the build.
- **AWS builder:** the right resources per transport; naming conventions hold.

---

## Open questions

1. **Shared API Gateway scope** — per-plugin (simpler, created alongside other
   plugin infrastructure) or per-platform (one base URL, needs coordination)?
2. **Custom domains** — spec-configurable or left to infrastructure?
   Recommendation: infrastructure.
3. **CORS** — server-to-server webhooks do not need it; a browser-initiated POST
   would. Add an optional `cors` to `endpointConfig` for transport B only?
4. **Request validation** — auto-generate a JSON Schema from `externalInputSchema`
   and attach it as an API Gateway validator, rejecting malformed bodies before
   the Lambda? Note this cannot precede signature verification.
5. **Rate limiting** — in `endpointConfig`, or an infrastructure concern? An open
   Function URL has no throttle at all, which argues for at least a reserved
   concurrency on the webhook Lambda.
6. **Idempotency** — providers retry on timeout. Extract a provider-supplied key
   from a header and deduplicate against the audit log, or leave it to `translate`
   (which can already return `Ok([])` for a no-op)?
7. **Secret storage** — Secrets Manager (rotatable, costs per secret) or a Lambda
   env var (free, rotation is a redeploy)?
