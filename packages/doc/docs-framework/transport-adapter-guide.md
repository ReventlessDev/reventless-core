# Transport Adapter Guide

This guide covers the runtime side of adding a new API transport to Reventless (e.g., OpenAPI/REST, gRPC). It is the counterpart to [`api-protocol-integration.md`](./api-protocol-integration.md), which covers the deploy-time schema generation layer.

A transport adapter is the in-memory (or Lambda handler) code that receives an incoming request, bridges it to the framework's internal types, calls the relevant interceptors, and dispatches the command or query.

---

## Architecture: Two Layers

| Layer | Guide | Purpose |
|---|---|---|
| **Schema generation** (deploy-time) | `api-protocol-integration.md` | Generates protocol-specific schema (SDL, OpenAPI spec, MCP manifest) from entry types |
| **Resolver / handler** (runtime) | this guide | Receives requests, extracts identity, calls interceptors, dispatches commands and queries |

These layers are independent. A new transport needs both, but they can be developed separately.

---

## Identity Propagation

Every command and query carries an `Identity.t` value. The transport adapter is responsible for extracting it from the incoming request and passing it into the framework.

### Type

```rescript
// Reventless.Identity.t — parsed from JSON
type t = {
  userId: string,
  // ... additional fields from your identity provider
}

let anonymous: t  // fallback when no identity is present
let schema: S.t<t> // sury schema for parsing
```

### Convention

Transport adapters use a dedicated header (or equivalent transport-level mechanism) to carry the identity. The in-memory GraphQL transport reads **`X-Identity`** — a JSON-encoded `Identity.t` value set by the caller (e.g., an auth middleware layer).

### Extraction pattern

```rescript
// Example: HTTP transport
let extractIdentity = (request: myTransportRequest): Reventless.Identity.t => {
  try {
    switch request->getHeader("x-identity") {
    | Some(json) => json->JSON.parseOrThrow->S.parseOrThrow(Reventless.Identity.schema)
    | None => Reventless.Identity.anonymous
    }
  } catch {
  | _ => Reventless.Identity.anonymous
  }
}
```

Always fall back to `Reventless.Identity.anonymous` on any parse error — never throw from identity extraction.

---

## Command Interceptor

### Hook location

```rescript
// reventless-core/src/components/CommandGenerator/CommandGenerator_Callback.res

type interceptResult = Allow | Deny(string)

type commandComponentKind = Aggregate | StateChangeSlice

type commandInterceptor = (
  ~identity: Reventless.Identity.t,
  ~componentName: string,   // aggregate / slice name
  ~componentKind: commandComponentKind,
  ~tag: string,             // command variant name (e.g. "AddProduct")
  ~args: JSON.t,            // raw command arguments (includes entity ID)
) => promise<interceptResult>

let commandInterceptorHook: ref<option<commandInterceptor>> = ref(None)
```

The hook is a module-level ref set once at application startup. `None` means passthrough (default).

### When to call it

Call `commandInterceptorHook` **after** identity extraction and **before** calling `generateCommand`. The framework's `CommandGenerator_Callback.makeGenerateCommand` already does this — transport adapters do not call the hook directly. Instead, they construct a `CommandGenerator.payload` with the extracted identity and pass it to `generateCommand`, which calls the hook internally.

### Payload construction

```rescript
// CommandGenerator.payload — the struct passed to generateCommand
type payload = {
  command: string,           // variant constructor name (e.g. "AddProduct")
  arguments: 'a,             // command args object (entity ID + command fields)
  meta: {
    ip: array<string>,
    user: string,            // identity.userId
    info: string,            // human-readable source (e.g. "Mutation.Catalog_AddProduct")
  },
  identity: Reventless.Identity.t,
}
```

The identity flows through the payload into `makeGenerateCommand`, where the hook intercepts it before `publishJsons` is called.

### DCB StateChangeSlice specifics

For DCB mutations, the entity ID lives inside a tagged field (annotated with `@s.matches(DcbTag.string)`) rather than as a separate `id` parameter. Before constructing the payload, extract the tagged field value and inject it as `"id"` into the args dict:

```rescript
// Find the DcbTag-annotated field in the command schema, extract its value,
// add it as "id" so generateCommand sees a consistent payload shape.
switch idFieldName {
| Some(idField) if idField != "id" =>
  let id = switch argsDict->Dict.get(idField) {
  | Some(JSON.String(s)) => s
  | _ => ""
  }
  argsDict->Dict.set("id", JSON.Encode.string(id))
| _ => ()
}
```

### Error response on `Deny`

`makeGenerateCommand` throws a `JsError` with the `Deny` message. The transport adapter should catch this and return the appropriate protocol-level error (HTTP 403, GraphQL error, etc.).

---

## Query Interceptor

### Hook location

```rescript
// reventless-core/src/components/QueryDb/QueryDb_Callback.res

type interceptResult = Allow | Deny(string)

type queryInterceptor = (
  ~identity: Reventless.Identity.t,
  ~readModelName: string,  // the QueryDb / read model name
  ~args: JSON.t,           // raw query arguments (filters, pagination, etc.)
) => promise<interceptResult>

let queryInterceptorHook: ref<option<queryInterceptor>> = ref(None)
```

**Note:** `QueryDb_Callback` and its hook are planned but not yet implemented.

### When to call it

Unlike the command interceptor (which is called inside `makeGenerateCommand`), the query interceptor must be called directly by each transport adapter resolver, because there is no equivalent to `generateCommand` on the query path.

Call the hook **before** fetching from the QueryDb:

```rescript
let runQueryInterceptor = async (
  ~identity: Reventless.Identity.t,
  ~readModelName: string,
  ~args: JSON.t,
): QueryDb_Callback.interceptResult => {
  switch QueryDb_Callback.queryInterceptorHook.contents {
  | None => Allow
  | Some(interceptor) =>
    await interceptor(~identity, ~readModelName, ~args)
  }
}

// In each resolver:
switch await runQueryInterceptor(~identity, ~readModelName=name, ~args) {
| Deny(_) => /* return empty / 403 */
| Allow => /* proceed with QueryDb fetch */
}
```

### Response on `Deny`

Return the transport-appropriate empty or error response:

| Query type | On `Deny` |
|---|---|
| Single item (byId) | `null` / 404 |
| List / paginated | Empty list, zero count |
| Index query | Empty list |

---

## Two-Phase Mutation Registration (in-memory)

The in-memory transport must register resolvers in two phases because `generateCommand` is produced inside an `Output.apply` chain, which fires asynchronously after the synchronous `Plugin_Builder.construct()` call.

### Phase 1 — synchronous (during `construct()`)

Register the protocol schema (SDL fields, OpenAPI paths, etc.) and resolver stubs with empty handler refs:

```rescript
let handlerRefs: dict<ref<option<CommandGenerator.commandGenerator>>> = Dict.make()

let register = (~fields: array<string>, ~commandSchema: S.t<unknown>) => {
  fields->Array.forEach(field => {
    let handlerRef = ref(None)
    handlerRefs->Dict.set(field, handlerRef)
    let resolver = async (request) => {
      switch handlerRef.contents {
      | Some(generateCommand) => /* dispatch */
      | None => /* not yet bound — return error or queue */
      }
    }
    // register resolver stub with your transport server
  })
}
```

Phase 1 is called synchronously via the `aggregateMutationResolverHook` (aggregates) or `dcbMutationResolverHook` (DCB slices).

### Phase 2 — async (inside `Output.apply`)

Bind the real `generateCommand` to the pre-registered stubs:

```rescript
let make: CommandGenerator_Adapter.resolversMaker<...> = (~name as _, ~fields, ...) => {
  let generateCommand = /* retrieved from pending slot or passed directly */
  fields->Array.forEach(field => {
    switch handlerRefs->Dict.get(field) {
    | Some(handlerRef) => handlerRef.contents = Some(generateCommand)
    | None => ()
    }
  })
  {resources: []}
}
```

The `CommandGenerator_Adapter.resolversMaker` type signature is the contract between the framework and the transport adapter for Phase 2.

---

## Inbound Translation

`InboundTranslationSlice` transports follow a simpler, single-phase pattern. The resolver receives an external payload (e.g., a webhook body) and calls a `receive` function that validates and translates it into a command.

```rescript
// Register a receive handler for an inbound translation endpoint
let receiveRegistry: dict<JSON.t => promise<result<string, string>>> = Dict.make()

let registerInbound = (~fieldName: string) => {
  // register your route/resolver stub, storing into receiveRegistry
}

let bindReceiveHandler = (
  ~fieldName: string,
  ~receive: JSON.t => promise<result<string, string>>,
) => {
  receiveRegistry->Dict.set(fieldName, receive)
}
```

The `receive` function returns `Ok(msgId)` on success or `Error(message)` on validation/translation failure.

---

## Query Resolver Types

Four standard query patterns map to QueryDb operations. Each transport adapter implements all four:

| Pattern | Parameters | QueryDb call |
|---|---|---|
| `byId` | `id: string`, optional `subId: string` | `getById` |
| `list` | `nextToken?: string`, `limit?: int` | `scan` (paginated) |
| `byIdList` | `id: string` | `getByIdList` |
| `byIndex` | `indexValue: string` (one per index) | `getByIndex` |

The GraphQL transport generates resolver field names from `QueryDb_Adapter.resolversMaker` and `Plugin_Helpers.queryFieldNamesRegistry`. Use the same registry for your transport to ensure consistent naming across all protocols.

---

## Hooks Reference

| Hook | Location | Called by | Purpose |
|---|---|---|---|
| `commandInterceptorHook` | `CommandGenerator_Callback` | `makeGenerateCommand` (internal) | Intercept all commands before publish |
| `queryInterceptorHook` | `QueryDb_Callback` *(planned)* | Transport adapter query resolvers | Intercept all queries before QueryDb fetch |
| `aggregateMutationResolverHook` | `Plugin_Builder` | `Plugin_Builder.construct` | Register aggregate mutation resolvers (Phase 1) |
| `dcbMutationResolverHook` | `Dcb_Builder` | `Dcb_Builder.construct` | Register DCB mutation resolvers (Phase 1) |
| `dcbMutationBindHook` | `Dcb_Builder` | `Output.apply` in `Dcb_Builder` | Bind DCB mutation handlers (Phase 2) |

---

## Checklist

- [ ] `extractIdentity` reads from the transport's auth mechanism, falls back to `Identity.anonymous`
- [ ] Command payload includes `identity` field populated from `extractIdentity`
- [ ] DCB commands: tagged ID field extracted and injected as `"id"` in args before payload construction
- [ ] Phase 1 registration is synchronous (called during `construct()`)
- [ ] Phase 2 binding is inside `Output.apply` or equivalent async chain
- [ ] `Deny` from command interceptor mapped to transport-appropriate error (e.g., HTTP 403)
- [ ] Query resolvers call `queryInterceptorHook` before any QueryDb operation
- [ ] `Deny` from query interceptor returns empty/null — not a hard error (no data exposed)
- [ ] All four query patterns implemented: byId, list, byIdList, byIndex
- [ ] `CommandGenerator_Adapter.resolversMaker` type satisfied for Phase 2
- [ ] Tests cover: identity extraction, `Allow` passthrough, `Deny` response shape
