// In-memory QueryEngine — uses Bus storage registry for real scan/query.
// This is a Make(Bus) functor; callers must first create
//   module QueryEngine = QueryEngine_InMemory.Make(Bus)
// and then pass QueryEngine as QueryEngineAdapter to Plugin_Builder.Make or Platform_Admin.Make.

open Reventless

module Make = (Bus: InMemory_Bus.T) => {
  let valueToString = value =>
    switch value {
    | QueryEngine.String(s) => s
    | QueryEngine.Int(i) => i->Int.toString
    | QueryEngine.Bool(b) => b ? "true" : "false"
    }

  let make: ReventlessCore.QueryDb_Adapter.queryEngineMaker = _allQueryDbs =>
    Pulumi.Output.make({
      QueryEngine.scan: async (~readModelName, ~filterConfigs as _, ~limit) =>
        switch Bus.getQueryDbStream(readModelName) {
        | Some(makeStream) =>
          await makeStream()->Stream.take(limit)->Stream.runCollect->Effect.runPromise
        | None =>
          // Backward compat: fall back to array scan if no stream registered
          switch Bus.getQueryDbScan(readModelName) {
          | Some(scanAll) => scanAll()
          | None => []
          }
        },
      query: async (
        ~readModelName,
        ~key=?,
        ~id,
        ~subIdConfig as _=?,
        ~filterConfigs as _=?,
        ~ascending as _=?,
        ~limit=?,
      ) => {
        let keyStr = switch key {
        | Some(k) => k
        | None => id->valueToString
        }
        switch Bus.getQueryDb(readModelName) {
        | Some(ops) =>
          let stream = ops.loadStream(keyStr)
          let bounded = switch limit {
          | Some(n) => stream->Stream.take(n)
          | None => stream
          }
          await bounded
          ->Stream.runCollect
          ->Effect.catchAll(_ => Effect.succeed([]))
          ->Effect.runPromise
        | None => []
        }
      },
    })
}
