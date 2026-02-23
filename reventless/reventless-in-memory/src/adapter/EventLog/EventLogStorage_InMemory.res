// In-memory event log storage.
// Stores events per aggregate id in a ref<dict<array<JSON.t>>>.

let make: Reventless.EventLog_Adapter.storageMaker = (~name as _, ~opts as _) => {
  let events: ref<dict<array<JSON.t>>> = ref(Dict.make())

  let append: Reventless.EventLog.append<string, JSON.t> = async (_seqNr, id, jsons) => {
    let existing = events.contents->Dict.get(id)->Option.getOr([])
    events.contents->Dict.set(id, existing->Array.concat(jsons))
    Ok()
  }

  let replay: Reventless.EventLog.replay<string, JSON.t> = async id => {
    events.contents->Dict.get(id)->Option.getOr([])
  }

  {
    resources: [],
    operations: Pulumi.Output.make({
      Reventless.EventLog_Adapter.append,
      replay,
    }),
  }
}
