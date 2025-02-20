module Make = (Runner: Heartbeat_Adapter.Runner) => {
  let construct = (~id, ~timeout, ~publishToCorePluginExtensionPoint, self, name) => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

    // Heartbeat + HealthCheck
    // see: https://docs.aws.amazon.com/AmazonCloudWatch/latest/events/RunLambdaSchedule.html

    let runnerResources = {
      module Callback = Heartbeat_Callback.Make({
        let publishToCorePluginExtensionPoint = publishToCorePluginExtensionPoint
        let id = id
        let timeout = timeout
      })
      Runner.make(
        ~name=name->ComponentType.name(Heartbeat.componentType),
        ~timeout,
        ~heartbeat=Callback.heartbeat,
        ~opts,
      ).resources
    }

    self->Component.setOutputs({Heartbeat.name, resources: runnerResources})
  }

  let make = (
    ~id,
    ~name,
    ~timeout=10,
    ~publishToCorePluginExtensionPoint,
    ~opts=?,
  ): Heartbeat.component =>
    Component.make(
      ~componentType=Heartbeat.componentType->ComponentType.toString,
      ~name,
      ~construct=construct(~id, ~timeout, ~publishToCorePluginExtensionPoint, ...),
      ~opts,
    )
}
