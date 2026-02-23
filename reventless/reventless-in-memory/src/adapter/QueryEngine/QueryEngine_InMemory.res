// In-memory QueryEngine — returns empty results.
// Tests that need query results should populate the read model via events.

open ReventlessSpec

let make: Reventless.QueryDb_Adapter.queryEngineMaker = _allQueryDbs =>
  Pulumi.Output.make({
    QueryEngine.scan: async (~readModelName as _, ~filterConfigs as _, ~limit as _) => [],
    query: async (
      ~readModelName as _,
      ~key as _=?,
      ~id as _,
      ~subIdConfig as _=?,
      ~filterConfigs as _=?,
      ~ascending as _=?,
      ~limit as _=?,
    ) => [],
  })
