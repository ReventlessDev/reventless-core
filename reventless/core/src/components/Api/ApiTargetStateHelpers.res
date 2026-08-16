// Read per-variant `targetState` metadata that the reventless-ppx
// an `@transition` target attaches to a command schema. Consumed by
// `Plugin_Structure.toCommandDef` when building the `commandDef` records that
// land in `Platform_ComponentDefinitions`, so AutoUI's board drag resolver can
// move a row by a *declared* transition instead of a name-stem guess. Mirrors
// `ApiAllowedStatesHelpers.getAllowedStates`.

open ReventlessInfra.Api

/** Returns the declared target state for a given command-variant name, or None
    when the variant declares no target — either because it carries no
    `@transition` at all, or because it declares a from-set only, which is a
    command saying it does not move the row. */
let getTargetState = (
  commandSchema: S.t<unknown>,
  ~variantName: string,
): option<string> =>
  switch commandSchema->S.Metadata.get(~id=targetStateId) {
  | None => None
  | Some(entries) => entries->Dict.get(variantName)
  }
