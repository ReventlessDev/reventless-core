// Read per-variant `allowedStates` metadata that the reventless-ppx
// `@allowedStates([…])` attribute attaches to a command schema. Consumed by
// `Plugin_Structure.toCommandDef` when building the `commandDef` records that
// land in `Platform_UIDefinitions` so AutoUI can filter the per-row command
// menu by the row's status.

open ReventlessInfra.Api

/** Returns the allowed-state list for a given command-variant name, or None
    when the variant has no `@allowedStates` annotation (back-compat default
    — the command shows on every row). */
let getAllowedStates = (
  commandSchema: S.t<unknown>,
  ~variantName: string,
): option<array<string>> =>
  switch commandSchema->S.Metadata.get(~id=allowedStatesId) {
  | None => None
  | Some(entries) => entries->Dict.get(variantName)
  }
