let componentType = ComponentType.Heartbeat

type outputs = {name: string, resources: Pulumi.Output.t<array<ReventlessSpec.Adapter.resource>>}

type t
type component = Component.t<t, outputs, unit>

module type T = {
  let make: (
    ~id: string,
    ~name: string,
    ~timeout: int,
    ~publishToCorePluginExtensionPoint: Pulumi.Output.t<ReventlessSpec.CommandTopic.publishJsons>,
  ) => component
}

module Adapter = {
  type runner = {resources: array<ReventlessSpec.Adapter.resource>}
  type runnerMaker = (
    ~name: string,
    ~timeout: int,
    ~heartbeat: unit => promise<unit>,
    ~opts: Pulumi.CustomResourceOptions.t,
  ) => runner

  module type Runner = {
    let make: runnerMaker
  }
}

module Make = (Runner: Adapter.Runner) => {
  let construct = (~id, ~timeout, ~publishToCorePluginExtensionPoint, self, name) => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

    // Heartbeat + HealthCheck
    // see: https://docs.aws.amazon.com/AmazonCloudWatch/latest/events/RunLambdaSchedule.html

    let runnerResources =
      publishToCorePluginExtensionPoint
      ->Pulumi.Output.apply(publishToCorePluginExtensionPoint => {
        module Runtime = Heartbeat_Runtime.Make({
          let publishToCorePluginExtensionPoint = publishToCorePluginExtensionPoint
          let id = id
          let timeout = timeout
        })
        Runner.make(
          ~name=name->ComponentType.name(componentType),
          ~timeout,
          ~heartbeat=Runtime.heartbeat,
          ~opts,
        ).resources
      })
      // ->Reventless.Adapter.outputToResource

    self->Component.setOutputs({name, resources: runnerResources})
  }

  let make = (~id, ~name, ~timeout=10, ~publishToCorePluginExtensionPoint, ~opts=?): component =>
    Component.make(
      ~componentType=componentType->ComponentType.toString,
      ~name,
      ~construct=construct(~id, ~timeout, ~publishToCorePluginExtensionPoint, ...),
      ~opts,
    )
}
