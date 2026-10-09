/**
Module types for a DCB inbound translation slice: external input (a webhook, an
API call) translated into domain commands by an anti-corruption layer, triggered
through `operations.receive` rather than by events.

`Spec` holds the types, schemas and target; `Translation` the `translate` function.
The slice moves no lifecycle of its own — its target owns that.
*/
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
  /** Each command's rule. The door admits a caller satisfying any command's
      rule; each command the input translates into is then checked against its
      own, and one refused refuses the whole input. Defaults to `AllowAuthenticated`. */
  let commandAuthorization: command => Authorization.rule<role>
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
