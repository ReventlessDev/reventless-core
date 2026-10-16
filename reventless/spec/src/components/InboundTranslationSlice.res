/**
Module types for a DCB inbound translation slice: external input (a webhook, an
API call) translated into domain commands by an anti-corruption layer, triggered
through `operations.receive` rather than by events.

`Spec` holds the types, schemas and target; `Translation` the `translate` function.
The slice moves no lifecycle of its own — its target owns that.
*/
/**
How a sender proves a webhook request is theirs: an HMAC-SHA256 over the raw
body, hex-encoded, in `header` (after `prefix`, e.g. `"sha256="`). With
`timestampHeader`, the signed text is `<timestamp>.<body>` and a timestamp more
than `toleranceSeconds` (default 300) from now is refused, so a captured request
cannot be replayed later. `secret` names the shared secret, never its value: the
platform reads it from `REVENTLESS_WEBHOOK_SECRET_<SECRET>`, which may list
several, comma-separated, while one is being rotated.
*/
type signature = {
  header: string,
  prefix?: string,
  timestampHeader?: string,
  toleranceSeconds?: int,
  secret: string,
}

/** Who may call a webhook. `Open` admits anybody, as an anonymous caller. */
type webhookAuth =
  | Open
  | SignedBody(signature)

type webhookMethod =
  | @as("POST") Post
  | @as("PUT") Put

/** How the URL is served. On AWS, a Lambda Function URL on the plugin's command
    handler, every slice's webhook a path under it. */
type webhookTransport = FunctionUrl

/**
A URL beside the slice's mutation, for a sender that only posts JSON to an
address. `path` is the slice's segment under the plugin's webhook base URL. A
request that passes `auth` acts as a signed-in caller holding `role` (none when
absent); each command it translates into is checked against its own rule, as on
the mutation.
*/
type endpointConfig<'role> = {
  path: string,
  method?: webhookMethod,
  auth: webhookAuth,
  role?: 'role,
  transport?: webhookTransport,
}

module type Spec = {
  /** Logical name of this inbound translation slice (used as a component prefix). */
  let name: string
  let moduleUrl: string

  /** The external input type received from the outside world. Must carry `@schema`. */
  @schema
  type externalInput

  /** The command type produced by the anti-corruption layer. Must carry `@schema`. */
  @schema
  type command

  /** Name of the aggregate or StateChangeSlice that receives the produced command. */
  let targetName: string

  /** The foreign system this slice receives from (e.g. `"SupplierFeed"`), drawn as a
      box outside the plugin. Injected as `None` by `@@reventless.spec`. */
  let externalSystem: option<string>

  /** The roles this spec's rules name: its plugin's `Roles.t`, which the PPX
      supplies; `Role.name` where the plugin declares none. */
  type role
  /** Each command's rule, by constructor name. The door admits a caller
      satisfying any command's rule; each command the input translates into is
      then checked against its own, and one refused refuses the whole input.
      Defaults to `AllowAuthenticated`. */
  let authorizationOf: string => Authorization.rule<role>

  /** The slice's webhook URL, if it has one. Injected as `None` by
      `@@reventless.spec`. */
  let endpoint: option<endpointConfig<role>>
}

/** The synchronous translate function. */
module type Translation = {
  module Spec: Spec

  /** External input into `(targetId, command)` pairs; `Ok([])` is an idempotent
      no-op, `Error(msg)` rejects the input. */
  let translate: Spec.externalInput => result<array<(string, Spec.command)>, string>

  /** File URL of this Translation module (`import.meta.url`). */
  let moduleUrl: string
}
