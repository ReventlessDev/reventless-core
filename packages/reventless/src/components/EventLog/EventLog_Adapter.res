type operations = {
  append: EventLog.append<string, Js.Json.t>,
  replay: EventLog.replay<string, Js.Json.t>,
}
type storage = {
  resources: array<ReventlessSpec.Adapter.resource>,
  operations: Pulumi.Output.t<operations>,
}
type storageMaker = (~name: string, ~opts: Pulumi.CustomResourceOptions.t) => storage

module type Storage = {
  let make: storageMaker
}
