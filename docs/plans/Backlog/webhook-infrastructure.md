# Backlog: Webhook Infrastructure for InboundTranslationSlice

**Status:** Backlog
**Depends on:** TranslationSlice plan (completed — `docs/plans/done/translation-slice.md`)
**Related:** `docs/plans/Backlog/api-component-openapi.md` (REST API Gateway)

## Motivation

The InboundTranslationSlice component implements the Event Modeling **Inbound Translation** pattern — it receives external input, validates it through an anti-corruption layer, and publishes domain commands. The translation logic is complete: `operations.receive` accepts `JSON.t` and returns `promise<result<string, string>>`.

However, there is **no framework support for exposing `receive` as an HTTP endpoint**. The user must manually wire a Lambda, API Gateway route, or GraphQL mutation to call `operations.receive`. This defeats the component's purpose — a payment provider sending webhooks needs a URL, not a ReScript function reference.

This plan adds **webhook endpoint configuration** to the InboundTranslationSlice spec and **infrastructure creation** to the platform builders, so that declaring an InboundTranslationSlice automatically provisions a reachable HTTP endpoint.

## Design

### Spec Extension

Add an optional `endpoint` configuration to the InboundTranslationSlice spec:

```rescript
module type Spec = {
  // ... existing fields ...
  let name: string
  module DcbEventLogSpec: DcbEventLog.Spec
  @schema type externalInput
  @schema type command
  let translate: externalInput => result<(string, command), string>

  // NEW: webhook endpoint configuration
  let endpoint: option<endpointConfig>
}

type endpointMethod = POST | PUT
type authType = None | IAM | ApiKey(string)

type endpointConfig = {
  /** URL path segment (e.g., "payment-webhook"). Combined with a base path to form the full URL. */
  path: string,
  /** HTTP method. Default: POST. */
  method?: endpointMethod,
  /** Authentication type for the endpoint. Default: None (open). */
  auth?: authType,
}
```

When `endpoint = None`, behaviour is unchanged — the user wires `operations.receive` manually (e.g., via a GraphQL mutation resolver). When `endpoint = Some({path: "payment-webhook"})`, the platform builder provisions an HTTP endpoint that forwards the request body to `operations.receive`.

### Why Optional?

Not every InboundTranslationSlice needs a dedicated HTTP endpoint:
- Some are triggered via GraphQL mutations (internal API consumers)
- Some are triggered by message queue consumers (SQS, EventBridge)
- Only external webhooks (payment providers, shipping updates, third-party integrations) need a stable URL

Making `endpoint` optional keeps the component flexible while providing first-class webhook support when needed.

### Outputs Extension

When an endpoint is configured, the outputs expose the URL:

```rescript
type outputs = {
  resources: array<Adapter.resource>,
  queryDb: QueryDb.outputs,
  endpointUrl?: Pulumi.Output.t<string>,  // NEW: the provisioned webhook URL
}
```

This lets the user retrieve the webhook URL at deploy time (e.g., to register it with a payment provider's dashboard or to configure another system).

---

## AWS Implementation: Two Approaches

Both approaches create a Lambda function that wraps `operations.receive` and returns an HTTP response. They differ only in the HTTP routing layer in front of the Lambda.

### Approach A: API Gateway HTTP API

Uses [AWS API Gateway v2 (HTTP API)](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api.html) — the lightweight, low-cost variant designed for simple proxy integrations.

**Architecture:**

```
External System
    ↓ POST /payment-webhook
API Gateway HTTP API
    ↓ Lambda proxy integration
Webhook Lambda
    ↓ operations.receive(event.body)
InboundTranslationSlice Callback
    ↓ translate → publishJsons
CommandTopic
```

**Resources created per InboundTranslationSlice (with endpoint):**

| Resource | Type | Purpose |
|----------|------|---------|
| Lambda Function | `aws.lambda.CallbackFunction` | Wraps `operations.receive` |
| IAM Role | `aws.iam.Role` | Lambda execution role |
| HTTP API | `aws.apigatewayv2.Api` | HTTP API (one per plugin, shared) |
| Route | `aws.apigatewayv2.Route` | `POST /payment-webhook` |
| Integration | `aws.apigatewayv2.Integration` | Lambda proxy integration |
| Stage | `aws.apigatewayv2.Stage` | `$default` auto-deploy stage |
| Permission | `aws.lambda.Permission` | Allows API Gateway to invoke Lambda |

**Shared API Gateway:** A single HTTP API can be shared across all InboundTranslationSlices in a plugin (or even across the entire Core). Each slice adds its own route. This is more cost-effective and provides a single base URL.

**URL format:** `https://{api-id}.execute-api.{region}.amazonaws.com/{path}`

**Pros:**
- Standard AWS pattern for webhooks
- Supports custom domains via Route 53 + ACM
- Supports API key authentication, IAM auth, JWT authorizers
- Request/response transformation and validation
- CloudWatch access logging and metrics
- Rate limiting and throttling built-in
- Single base URL for all webhooks in a plugin

**Cons:**
- Additional infrastructure (API Gateway + routes + integrations)
- Requires new Pulumi AWS bindings (`apigatewayv2`)
- Slight latency overhead vs direct Lambda invocation

### Approach B: Lambda Function URL

Uses [Lambda Function URLs](https://docs.aws.amazon.com/lambda/latest/dg/urls-configuration.html) — a built-in HTTP(S) endpoint on the Lambda function itself.

**Architecture:**

```
External System
    ↓ POST https://{url-id}.lambda-url.{region}.on.aws/
Lambda Function URL
    ↓ (direct invocation, no proxy)
Webhook Lambda
    ↓ operations.receive(event.body)
InboundTranslationSlice Callback
    ↓ translate → publishJsons
CommandTopic
```

**Resources created per InboundTranslationSlice (with endpoint):**

| Resource | Type | Purpose |
|----------|------|---------|
| Lambda Function | `aws.lambda.CallbackFunction` | Wraps `operations.receive` |
| IAM Role | `aws.iam.Role` | Lambda execution role |
| Function URL | `aws.lambda.FunctionUrl` | HTTPS endpoint on the Lambda |
| Permission | `aws.lambda.Permission` | (only if auth=None, allows public access) |

**URL format:** `https://{url-id}.lambda-url.{region}.on.aws/`

**Pros:**
- Minimal infrastructure — just the Lambda + URL config
- No additional service to manage
- Lower latency (no API Gateway hop)
- Simpler — fewer moving parts
- Free (included in Lambda pricing, no API Gateway cost)

**Cons:**
- One URL per Lambda (can't share a base URL across slices)
- No custom domain support without CloudFront
- Limited auth options (IAM or NONE — no API keys, no JWT authorizers)
- No built-in rate limiting or throttling
- No request/response transformation
- URL is auto-generated (not human-friendly)

### Recommendation

Both approaches should be supported. The choice depends on the use case:

- **Lambda Function URL** for simple, low-cost webhooks where the URL can be registered with a provider (e.g., Stripe webhook configuration accepts any URL)
- **API Gateway HTTP API** when you need custom domains, API keys, rate limiting, or a unified base URL for multiple webhook endpoints

The spec's `endpointConfig` drives the choice. The AWS builder checks for a `transport` field:

```rescript
type transportType = FunctionUrl | ApiGateway

type endpointConfig = {
  path: string,
  method?: endpointMethod,
  auth?: authType,
  transport?: transportType,  // Default: FunctionUrl
}
```

---

## In-Memory Implementation

The in-memory platform needs to support webhook endpoints for local development and testing. Two options:

### Option A: Direct Function Exposure (Minimal)

The simplest approach: `operations.receive` is already callable directly. For in-memory, the "endpoint" just registers the path in a routing table that test code can look up:

```rescript
type operations = {
  receive: JSON.t => promise<result<string, string>>,
  endpointUrl?: string,  // e.g., "http://localhost:4000/payment-webhook"
}
```

The in-memory platform maintains a global route registry. Test code calls `InMemory_Webhooks.post("/payment-webhook", jsonBody)` which looks up and invokes the matching `receive` function.

### Option B: HTTP Server (Full Fidelity)

For integration testing that needs real HTTP calls, spin up a lightweight HTTP server (Node `http` module) that listens on a local port:

```rescript
// Shared across all InboundTranslationSlices in a plugin
let webhookServer = InMemory_WebhookServer.make(~port=4000)

// Each slice with an endpoint registers its route
webhookServer.addRoute("POST", "/payment-webhook", slice.operations.receive)
```

This mirrors the production behaviour — external systems can POST to `http://localhost:4000/payment-webhook` during local development.

### Recommendation

Start with **Option A** (direct function + route registry) — it's sufficient for unit and integration tests. Add Option B later if users need full HTTP fidelity for local development.

---

## Implementation Steps

### Step 1: Add Endpoint Types to Spec

**Modify:** `reventless/reventless-spec/src/components/InboundTranslationSlice.res`

Add the endpoint configuration types and the optional `endpoint` field to the Spec module type.

```rescript
type endpointMethod = POST | PUT

type authType =
  | None
  | IAM
  | ApiKey(string)

type transportType =
  | FunctionUrl
  | ApiGateway

type endpointConfig = {
  path: string,
  method?: endpointMethod,
  auth?: authType,
  transport?: transportType,
}

module type Spec = {
  let name: string
  module DcbEventLogSpec: DcbEventLog.Spec
  @schema type externalInput
  @schema type command
  let translate: externalInput => result<(string, command), string>
  let endpoint: option<endpointConfig>
}
```

### Step 2: Extend Infra Types

**Modify:** `reventless/reventless-infra/src/components/InboundTranslationSlice.res`

Add `endpointUrl` to outputs:

```rescript
type outputs = {
  resources: array<Adapter.resource>,
  queryDb: QueryDb.outputs,
  endpointUrl?: Pulumi.Output.t<string>,
}
```

### Step 3: Add Lambda Function URL Bindings

**New file:** `rescript/rescript-pulumi-aws/src/Lambda/Lambda_FunctionUrl.res`

Add ReScript bindings for `@pulumi/aws.lambda.FunctionUrl`:

```rescript
type authorizationType =
  | @as("NONE") None_
  | @as("AWS_IAM") AwsIam

type cors = {
  allowCredentials?: bool,
  allowHeaders?: array<string>,
  allowMethods?: array<string>,
  allowOrigins?: array<string>,
  exposeHeaders?: array<string>,
  maxAge?: int,
}

type args = {
  functionName: Pulumi.Input.t<string>,
  authorizationType: authorizationType,
  cors?: Pulumi.Input.t<cors>,
}

type t = {
  functionUrl: Pulumi.Output.t<string>,
  functionArn: Pulumi.Output.t<string>,
}

@module("@pulumi/aws") @scope("lambda") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "FunctionUrl"
```

Re-export from `Lambda.res`:
```rescript
module FunctionUrl = Lambda_FunctionUrl
```

### Step 4: Add API Gateway v2 (HTTP API) Bindings

**New file:** `rescript/rescript-pulumi-aws/src/ApiGatewayV2/ApiGatewayV2.res`

Add ReScript bindings for the minimal set of API Gateway v2 resources:

```rescript
module Api = {
  type args = {
    name: string,
    protocolType: string,  // "HTTP"
    description?: string,
  }

  type t = {
    id: Pulumi.Output.t<string>,
    apiEndpoint: Pulumi.Output.t<string>,
  }

  @module("@pulumi/aws") @scope("apigatewayv2") @new
  external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t = "Api"
}

module Integration = {
  type args = {
    apiId: Pulumi.Input.t<string>,
    integrationType: string,  // "AWS_PROXY"
    integrationUri: Pulumi.Input.t<string>,
    payloadFormatVersion?: string,  // "2.0"
  }

  type t = {
    id: Pulumi.Output.t<string>,
  }

  @module("@pulumi/aws") @scope("apigatewayv2") @new
  external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
    "Integration"
}

module Route = {
  type args = {
    apiId: Pulumi.Input.t<string>,
    routeKey: string,  // "POST /payment-webhook"
    target: Pulumi.Input.t<string>,  // "integrations/{integration-id}"
  }

  type t = {
    id: Pulumi.Output.t<string>,
  }

  @module("@pulumi/aws") @scope("apigatewayv2") @new
  external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
    "Route"
}

module Stage = {
  type args = {
    apiId: Pulumi.Input.t<string>,
    name: string,  // "$default"
    autoDeploy?: bool,
  }

  type t = {
    id: Pulumi.Output.t<string>,
  }

  @module("@pulumi/aws") @scope("apigatewayv2") @new
  external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
    "Stage"
}
```

### Step 5: Create Webhook Adapter Interface

**New file:** `reventless/reventless-infra/src/components/Webhook_Adapter.res`

Provider abstraction so the core builder doesn't depend on AWS directly:

```rescript
type webhookHandler = JSON.t => promise<result<string, string>>

type webhookEndpoint = {
  url: Pulumi.Output.t<string>,
  resources: array<Adapter.resource>,
}

module type Provider = {
  type config

  /** Create an HTTP endpoint that invokes the given handler. */
  let makeEndpoint: (
    ~name: string,
    ~path: string,
    ~method: string,
    ~handler: Pulumi.Output.t<webhookHandler>,
    ~config: config,
    ~opts: Pulumi.ComponentResource.options,
  ) => webhookEndpoint
}
```

### Step 6: Implement Lambda Function URL Provider

**New file:** `reventless/reventless-aws/src/adapter/Webhook/Webhook_FunctionUrl.res`

Creates a Lambda wrapping `operations.receive` and attaches a Function URL:

```rescript
type config = unit

let makeEndpoint = (~name, ~path as _path, ~method as _method, ~handler, ~config as _, ~opts) => {
  // Create Lambda that accepts API Gateway v2 payload format
  // and calls handler(event.body)
  let lambdaRole = IAM.Role.makeWithDefaultPolicy(...)
  let lambda = handler->Output.apply(handler =>
    Lambda.CallbackFunction.make(~name=name ++ "Webhook", ~args=Lambda.CallbackFunction.Args.make(
      ~callback=async (event, _ctx) => {
        let body = event["body"]->JSON.parseExn
        let result = await handler(body)
        switch result {
        | Ok(targetId) => {statusCode: 200, body: JSON.stringify({"targetId": targetId})}
        | Error(msg) => {statusCode: 400, body: JSON.stringify({"error": msg})}
        }
      },
      ~role=lambdaRole,
    ))
  )

  // Attach Function URL
  let functionUrl = lambda->Output.apply(lambda =>
    Lambda.FunctionUrl.make(~name=name ++ "WebhookUrl", ~args={
      functionName: lambda.name,
      authorizationType: None_,
    })
  )

  {
    url: functionUrl->Output.apply(fu => fu.functionUrl),
    resources: [...],
  }
}
```

### Step 7: Implement API Gateway HTTP API Provider

**New file:** `reventless/reventless-aws/src/adapter/Webhook/Webhook_ApiGateway.res`

Creates a shared HTTP API and adds routes per InboundTranslationSlice:

```rescript
type config = {
  api: ApiGatewayV2.Api.t,
  stage: ApiGatewayV2.Stage.t,
}

let makeSharedApi = (~name, ~opts) => {
  let api = ApiGatewayV2.Api.make(~name, ~args={
    name: name ++ "WebhookApi",
    protocolType: "HTTP",
  }, ~opts)

  let stage = ApiGatewayV2.Stage.make(~name=name ++ "DefaultStage", ~args={
    apiId: api.id,
    name: "$default",
    autoDeploy: true,
  }, ~opts)

  {api, stage}
}

let makeEndpoint = (~name, ~path, ~method, ~handler, ~config, ~opts) => {
  // Create Lambda (same as FunctionUrl approach)
  let lambda = ...

  // Create Integration
  let integration = ApiGatewayV2.Integration.make(
    ~name=name ++ "Integration",
    ~args={
      apiId: config.api.id,
      integrationType: "AWS_PROXY",
      integrationUri: lambda.arn,
      payloadFormatVersion: "2.0",
    },
    ~opts,
  )

  // Create Route
  let routeKey = method ++ " /" ++ path
  let _route = ApiGatewayV2.Route.make(
    ~name=name ++ "Route",
    ~args={
      apiId: config.api.id,
      routeKey,
      target: integration.id->Output.apply(id => "integrations/" ++ id),
    },
    ~opts,
  )

  // Grant API Gateway permission to invoke Lambda
  let _permission = Lambda.Permission.make(
    ~name=name ++ "ApiGwPermission",
    ~args={
      action: "lambda:InvokeFunction",
      function: lambda.arn,
      principal: "apigateway.amazonaws.com",
      sourceArn: config.api.id->Output.apply(id =>
        "arn:aws:execute-api:*:*:" ++ id ++ "/*"
      ),
    },
    ~opts,
  )

  {
    url: config.api.apiEndpoint->Output.apply(base => base ++ "/" ++ path),
    resources: [...],
  }
}
```

### Step 8: Wire Webhook Provider into Core Builder

**Modify:** `reventless/reventless-core/src/components/InboundTranslationSlice/InboundTranslationSlice_Builder.res`

Add an optional `Webhook` functor parameter and wire it when `Spec.endpoint` is `Some`:

```rescript
module Make = (
  QueryDbStorage: QueryDb_Adapter.Storage,
  QueryDbResolvers: QueryDb_Adapter.Resolvers with type api = QueryDbStorage.api and type role = QueryDbStorage.role,
  Api: { let api: QueryDbStorage.api; let apiRole: QueryDbStorage.role },
  Webhook: {
    type config
    let makeEndpoint: (
      ~name: string, ~path: string, ~method: string,
      ~handler: Pulumi.Output.t<Webhook_Adapter.webhookHandler>,
      ~config: config,
      ~opts: Pulumi.ComponentResource.options,
    ) => Webhook_Adapter.webhookEndpoint
    let config: option<config>
  },
) => {
  // ... existing builder code ...

  let construct = (~publishJsons, self, _name) => {
    // ... existing code creating queryDb and operations ...

    // NEW: create webhook endpoint if configured
    let webhookEndpoint = switch (Spec.endpoint, Webhook.config) {
    | (Some(endpointCfg), Some(webhookConfig)) =>
      let method = endpointCfg.method->Option.getOr(POST)->endpointMethodToString
      let endpoint = Webhook.makeEndpoint(
        ~name=Spec.name,
        ~path=endpointCfg.path,
        ~method,
        ~handler=operationsOutput->Output.apply(ops => ops.receive),
        ~config=webhookConfig,
        ~opts,
      )
      Some(endpoint)
    | _ => None
    }

    let outputs: InboundTranslationSlice.outputs = {
      resources: webhookEndpoint->Option.map(e => e.resources)->Option.getOr([]),
      queryDb: queryDb->Component.outputs,
      endpointUrl: ?webhookEndpoint->Option.map(e => e.url),
    }
    self->Component.setOutputs(outputs)
  }
}
```

### Step 9: Wire into AWS Platform Builders

**Modify:** `reventless/reventless-aws/src/components/InboundTranslationSlice_Builder.res`

Pass the webhook provider based on the spec's transport choice:

```rescript
module Make = (Api: {
  let api: Types.AppSync.api
  let apiRole: Types.AppSync.role
  // NEW: shared API Gateway (None if not using ApiGateway transport)
  let webhookApiGateway: option<Webhook_ApiGateway.config>
}) => ReventlessCore.InboundTranslationSlice_Builder.Make(
  QueryDbStorage.DynamoDb,
  QueryDbResolvers.AppSync,
  Api,
  {
    type config = /* determined by transport choice */
    let makeEndpoint = ...
    let config = ...
  },
)
```

The Plugin_Builder (AWS) creates the shared API Gateway HTTP API once per plugin if any InboundTranslationSlice uses `transport: ApiGateway`. For `FunctionUrl` slices, no shared resource is needed.

### Step 10: Implement In-Memory Webhook Support

**New file:** `reventless/reventless-in-memory/src/adapter/Webhook/InMemory_WebhookRegistry.res`

Simple route registry for test code:

```rescript
type route = {
  method: string,
  path: string,
  handler: JSON.t => promise<result<string, string>>,
}

let routes: ref<array<route>> = ref([])

let register = (~method, ~path, ~handler) => {
  routes := routes.contents->Array.concat([{method, path, handler}])
}

let post = async (path, body) => {
  switch routes.contents->Array.find(r => r.path == path && r.method == "POST") {
  | Some(route) => await route.handler(body)
  | None => Error("No route registered for POST " ++ path)
  }
}

let reset = () => { routes := [] }
```

**Modify:** `reventless/reventless-in-memory/src/components/InboundTranslationSlice_Builder.res`

Pass a webhook provider that registers routes in the in-memory registry and returns `http://localhost/{path}` as the URL.

### Step 11: Update Example Plugins

Add an example InboundTranslationSlice with `endpoint` configured:

```rescript
// examples/dcb/ordering/src/Slices/PaymentWebhook.res
module DcbEventLogSpec = OrderingEventLog

let name = "PaymentWebhook"

@schema type externalInput = { paymentId: string, orderId: string, status: string, amount: float }
@schema type command = ConfirmPayment({ orderId: @s.matches(DcbTag.string) string, paymentId: string, amount: float })

let translate = (input: externalInput) =>
  switch input.status {
  | "completed" => Ok((input.orderId, ConfirmPayment({ orderId: input.orderId, paymentId: input.paymentId, amount: input.amount })))
  | status => Error("Unknown payment status: " ++ status)
  }

let endpoint = Some({
  path: "payment-webhook",
  method: POST,
  auth: None,
  transport: FunctionUrl,
})
```

### Step 12: Tests

**Webhook Registry Tests (in-memory):**
- Register route, call `post`, verify handler invoked
- Unregistered route returns Error
- Reset clears all routes

**Builder Tests (in-memory):**
- Slice with `endpoint = None` → no endpointUrl in outputs
- Slice with `endpoint = Some(...)` → endpointUrl is set, route is registered
- `InMemory_WebhookRegistry.post` invokes `receive` end-to-end

**AWS Builder Tests (unit):**
- Verify FunctionUrl resources are created when `transport = FunctionUrl`
- Verify API Gateway resources are created when `transport = ApiGateway`
- Verify correct resource naming conventions

### Step 13: Documentation

Update existing InboundTranslationSlice docs:
- Add "Webhook Endpoint" section explaining the `endpoint` spec field
- Add examples for both FunctionUrl and ApiGateway transports
- Document how to retrieve the endpoint URL from outputs
- Add comparison table of FunctionUrl vs ApiGateway trade-offs

---

## New Pulumi AWS Bindings Required

| Binding | Pulumi Resource | Package |
|---------|----------------|---------|
| `Lambda.FunctionUrl` | `aws.lambda.FunctionUrl` | `rescript-pulumi-aws` |
| `ApiGatewayV2.Api` | `aws.apigatewayv2.Api` | `rescript-pulumi-aws` |
| `ApiGatewayV2.Integration` | `aws.apigatewayv2.Integration` | `rescript-pulumi-aws` |
| `ApiGatewayV2.Route` | `aws.apigatewayv2.Route` | `rescript-pulumi-aws` |
| `ApiGatewayV2.Stage` | `aws.apigatewayv2.Stage` | `rescript-pulumi-aws` |

These are standard `@pulumi/aws` resources. The bindings follow the existing pattern in `rescript-pulumi-aws` (FFI via `@module("@pulumi/aws") @scope(...) @new external make`).

## Files Summary

### New files:
| Package | File | Purpose |
|---------|------|---------|
| `rescript-pulumi-aws` | `src/Lambda/Lambda_FunctionUrl.res` | Lambda Function URL bindings |
| `rescript-pulumi-aws` | `src/ApiGatewayV2/ApiGatewayV2.res` | API Gateway v2 HTTP API bindings |
| `reventless-infra` | `src/components/Webhook_Adapter.res` | Provider abstraction |
| `reventless-aws` | `src/adapter/Webhook/Webhook_FunctionUrl.res` | Lambda Function URL provider |
| `reventless-aws` | `src/adapter/Webhook/Webhook_ApiGateway.res` | API Gateway HTTP API provider |
| `reventless-in-memory` | `src/adapter/Webhook/InMemory_WebhookRegistry.res` | In-memory route registry |

### Modified files:
| Package | File | Change |
|---------|------|--------|
| `reventless-spec` | `src/components/InboundTranslationSlice.res` | Add `endpoint` types + field |
| `reventless-infra` | `src/components/InboundTranslationSlice.res` | Add `endpointUrl?` to outputs |
| `reventless-core` | `src/components/InboundTranslationSlice/InboundTranslationSlice_Builder.res` | Add Webhook functor + wiring |
| `reventless-aws` | `src/components/InboundTranslationSlice_Builder.res` | Pass webhook provider |
| `reventless-aws` | `src/Platform.res` | Wire webhook providers |
| `reventless-in-memory` | `src/components/InboundTranslationSlice_Builder.res` | Pass in-memory webhook provider |
| `reventless-in-memory` | `src/Platform.res` | Wire in-memory webhook registry |

## Open Questions

1. **Shared API Gateway scope**: Should the HTTP API be shared per-plugin or per-Core? Per-plugin is simpler (created in Plugin_Builder alongside other slice infrastructure). Per-Core gives a single base URL for all webhooks across all plugins but requires coordination in Core_Builder.

2. **Custom domains**: API Gateway HTTP API supports custom domains via Route 53 + ACM. Should this be configurable in the spec or handled externally? Recommend: externally (infrastructure concern, not domain concern).

3. **CORS**: Webhooks from server-to-server integrations don't need CORS. Browser-initiated POST requests (e.g., from a partner's web app) might. Should CORS be configurable in `endpointConfig`? Recommend: add an optional `cors` field for API Gateway transport only.

4. **Request validation**: API Gateway HTTP API supports request validation via OpenAPI models. Should the framework auto-generate a JSON Schema from `externalInputSchema` and attach it as a request validator? This would reject malformed requests before they reach the Lambda.

5. **Rate limiting**: API Gateway supports throttling. Should `endpointConfig` include rate limit settings, or is this an infrastructure concern handled outside the framework?

6. **Idempotency**: Webhook providers often retry on timeout. Should the framework provide idempotency key support (e.g., extract a key from headers and deduplicate in the audit log)?
