type operations = {
  append: EventLog.append<string, JSON.t>,
  replay: EventLog.replay<string, JSON.t>,
  replayStream: (string, ~fromSeq: int=?) => Stream.t<JSON.t, string, unit>,
  appendStream: EventLog.appendStream<string, JSON.t>,
  latestSnapshot: EventLog.latestSnapshot<string>,
  writeSnapshot: EventLog.writeSnapshot<string>,
}
type storage = {
  resources: array<ReventlessInfra.Adapter.resource>,
  operations: Pulumi.Output.t<operations>,
}
type storageMaker = (
  ~name: string,
  ~owner: option<ResourceAttribution.owner>,
  ~opts: Pulumi.CustomResourceOptions.t,
) => storage

module type Storage = {
  let make: storageMaker
}
