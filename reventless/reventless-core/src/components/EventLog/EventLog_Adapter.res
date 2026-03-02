type operations = {
  append: EventLog.append<string, JSON.t>,
  replay: EventLog.replay<string, JSON.t>,
  replayStream: string => Stream.t<JSON.t, string, unit>,
  appendStream: EventLog.appendStream<string, JSON.t>,
}
type storage = {
  resources: array<ReventlessInfra.Adapter.resource>,
  operations: Pulumi.Output.t<operations>,
}
type storageMaker = (~name: string, ~opts: Pulumi.CustomResourceOptions.t) => storage

module type Storage = {
  let make: storageMaker
}
