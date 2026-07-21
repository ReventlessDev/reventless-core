// Deploy-time log attribution baked into HANDLER_CONFIG.
//
// The deployed entry points annotate each invocation with `comp` and `plugin`
// (HandlerFactoryHelpers.runEffect). `comp` a shell can usually derive itself
// from the spec name it loads; `plugin` it cannot — resolution goes through
// LogPrefix's component→plugin registry, which `Plugin_Builder.construct`
// populates at **deploy** time and which is empty inside a Lambda. And the
// Lambda-name fallback (`derivePluginFromLambdaName`) only works for Lambdas
// named `<Plugin>Plugin<Suffix>`: it yields nothing for a shared multi-plugin
// Lambda (`AllAggregatesCmdHandler`, `AllReadModels`) or a per-component one
// (`<Aggregate>Aggr`) — exactly the cases where the field matters most.
//
// So resolve it here, where the registry exists, and ship it in the config.
// See docs/plans/entrypoint-dispatch-parity-and-latency-fields.md.

/** `,"plugin":"<Name>"` for a HANDLER_CONFIG entry, or `""` when the comp
    resolves to no plugin (the shell then falls back to the Lambda name). */
let pluginFragment = (~comp: string): string =>
  switch ReventlessCore.Logger.resolvePlugin(~comp, ()) {
  | Some(plugin) => `,"plugin":${plugin->JSON.Encode.string->JSON.stringify}`
  | None => ""
  }

/** `,"comp":"<Kind(Name)>"` for a HANDLER_CONFIG entry. For the shells that
    cannot name the element themselves — a read model or side-effect handler is
    known to its shell only by module path, while the aggregate/slice shells read
    the name off the spec they load. */
let compFragment = (~comp: string): string => `,"comp":${comp->JSON.Encode.string->JSON.stringify}`

/** Both fragments, in the order the entry points expect. */
let fragments = (~comp: string): string => compFragment(~comp) ++ pluginFragment(~comp)
