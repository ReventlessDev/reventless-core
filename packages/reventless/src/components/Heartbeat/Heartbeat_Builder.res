module Make = (Runner: Heartbeat_Adapter.Runner, RuntimeEnvironment: Runtime.Environment) => {
  let construct = (~timeout, ~runtime, self, name) => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

    // Heartbeat + HealthCheck
    // see: https://docs.aws.amazon.com/AmazonCloudWatch/latest/events/RunLambdaSchedule.html

    let runnerResources = {
      Runner.make(
        ~name=name->ComponentType.name(Heartbeat.componentType),
        ~timeout,
        ~runtime,
        ~opts,
      ).resources
    }

    self->Component.setOutputs({Heartbeat.name, resources: runnerResources})
  }

  let makeHandler = (~id, ~timeout=10, ~publishToCorePluginExtensionPoint) => {
    module Callback = Heartbeat_Callback.Make({
      let publishToCorePluginExtensionPoint = publishToCorePluginExtensionPoint
      let id = id
      let timeout = timeout
    })
    Callback.heartbeat->Pulumi.Output.make
  }

  let make = (~name, ~timeout=10, ~runtime, ~opts=?): Heartbeat.component =>
    Component.make(
      ~componentType=Heartbeat.componentType->ComponentType.toString,
      ~name,
      ~construct=construct(~timeout, ~runtime, ...),
      ~opts
    )
}
