// Read per-variant `targetState` metadata that the reventless-ppx
// `@targetState("…")` attribute attaches to a command schema. Consumed by
// `Plugin_Structure.toCommandDef` when building the `commandDef` records that
// land in `Platform_ComponentDefinitions`, so AutoUI's board drag resolver can
// move a row by a *declared* transition instead of a name-stem guess. Mirrors
// `ApiAllowedStatesHelpers.getAllowedStates`.

open ReventlessInfra.Api

/** Returns the declared target state for a given command-variant name, or None
    when the variant has no `@targetState` annotation (back-compat default —
    the resolver falls back to its name-stem heuristic). */
let getTargetState = (
  commandSchema: S.t<unknown>,
  ~variantName: string,
): option<string> =>
  switch commandSchema->S.Metadata.get(~id=targetStateId) {
  | None => None
  | Some(entries) => entries->Dict.get(variantName)
  }
