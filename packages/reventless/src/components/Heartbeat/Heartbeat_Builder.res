module Make = (Runner: Heartbeat_Adapter.Runner): (
  Heartbeat.T with type runtimeParts = Runner.runtimeParts
) => {
  type runtimeParts = Runner.runtimeParts

  let construct = (_self, _name) => ()

  let connect = (~runtime, ~remoteChannel, ~timeout=10, heartbeat) => {
    let heartbeatResource = heartbeat->Component.toPulumiResource
    let name =
      heartbeatResource.name
      ->Option.getOr("Unnamed")
      ->ComponentType.name(Heartbeat.componentType)
    let opts = {Pulumi.ComponentResource.parent: heartbeatResource}

    let runnerResources = {
      Runner.make(~name, ~remoteChannel, ~timeout, ~runtime, ~opts).resources
    }

    let _ = heartbeat->Component.setOutputs({
      name,
      Heartbeat.resources: runnerResources,
    })
  }

  let makeHandler = (~id, ~timeout=10, ~publishToCorePluginExtensionPoint) => {
    module Callback = Heartbeat_Callback.Make({
      let publishToCorePluginExtensionPoint = publishToCorePluginExtensionPoint
      let id = id
      let timeout = timeout
    })
    Callback.heartbeat->Pulumi.Output.make
  }

  let make = (~name, ~opts=?): Heartbeat.component =>
    Component.make(
      ~componentType=Heartbeat.componentType->ComponentType.toString,
      ~name,
      ~construct,
      ~opts,
    )
}
