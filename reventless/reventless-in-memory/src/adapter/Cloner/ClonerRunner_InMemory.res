// No-op ClonerRunner for in-memory mode.
// Satisfies Cloner.Adapter.Runner with type api = unit.

type api = unit

let make: ReventlessCore.Cloner.Adapter.runnerMaker<api> = (
  ~name as _,
  ~api as _,
  ~fullQualifiedStackName as _,
  ~reventlessCiSecretUrn as _,
  ~secretUrns as _,
  ~opts as _=?,
) => ReventlessCore.Cloner.Adapter.noRunner
