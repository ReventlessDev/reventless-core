// In-memory event log storage.
// Stores events per aggregate id in a ref<dict<array<JSON.t>>>.

let make: ReventlessCore.EventLog_Adapter.storageMaker = (~name as _, ~opts as _) => {
  let events: ref<dict<array<JSON.t>>> = ref(Dict.make())

  let append: ReventlessCore.EventLog.append<string, JSON.t> = async (_seqNr, id, jsons) => {
    let existing = events.contents->Dict.get(id)->Option.getOr([])
    events.contents->Dict.set(id, existing->Array.concat(jsons))
    Ok()
  }

  let replay: ReventlessCore.EventLog.replay<string, JSON.t> = async id => {
    events.contents->Dict.get(id)->Option.getOr([])
  }

  {
    resources: [],
    operations: Pulumi.Output.make({
      ReventlessCore.EventLog_Adapter.append,
      replay,
    }),
  }
}
