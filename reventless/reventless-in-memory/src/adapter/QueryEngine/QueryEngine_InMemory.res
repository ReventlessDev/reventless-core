// In-memory QueryEngine — uses Bus storage registry for real scan/query.
// This is a Make(Bus) functor; callers must first create
//   module QueryEngine = QueryEngine_InMemory.Make(Bus)
// and then pass QueryEngine as QueryEngineAdapter to Plugin_Builder.Make or Core_Builder.Make.

open ReventlessSpec

module Make = (Bus: InMemory_Bus.T) => {
  let valueToString = value =>
    switch value {
    | QueryEngine.String(s) => s
    | QueryEngine.Int(i) => i->Int.toString
    | QueryEngine.Bool(b) => b ? "true" : "false"
    }

  let make: Reventless.QueryDb_Adapter.queryEngineMaker = _allQueryDbs =>
    Pulumi.Output.make({
      QueryEngine.scan: async (~readModelName, ~filterConfigs as _, ~limit as _) =>
        switch Bus.getQueryDbScan(readModelName) {
        | Some(scanAll) => scanAll()
        | None => []
        },
      query: async (
        ~readModelName,
        ~key=?,
        ~id,
        ~subIdConfig as _=?,
        ~filterConfigs as _=?,
        ~ascending as _=?,
        ~limit as _=?,
      ) => {
        let keyStr = switch key {
        | Some(k) => k
        | None => id->valueToString
        }
        switch Bus.getQueryDb(readModelName) {
        | Some(ops) => (await ops.load(keyStr))->Result.getOr([])
        | None => []
        }
      },
    })
}
