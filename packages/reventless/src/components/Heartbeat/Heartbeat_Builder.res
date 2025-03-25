module Make = (Runner: Heartbeat_Adapter.Runner, RuntimeEnvironment: Runtime.Environment) => {
  let construct = (_self, _name) => ()

  let subscribe = (~name, ~timeout=10, ~heartbeat, ~remoteChannel, ~runtime, ~opts) => {
    // Heartbeat + HealthCheck
    // see: https://docs.aws.amazon.com/AmazonCloudWatch/latest/events/RunLambdaSchedule.html

    let runnerResources = {
      Runner.make(
        ~name=name->ComponentType.name(Heartbeat.componentType),
        ~remoteChannel,
        ~timeout,
        ~runtime,
        ~opts,
      ).resources
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
