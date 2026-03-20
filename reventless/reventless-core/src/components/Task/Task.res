let componentType = ComponentType.Task

type t
type outputs = ReventlessInfra.Task.outputs

type publishCommands = (/* ~aggregateName: */ string, array<Message.commandJson>) => promise<unit>
type queryBucketName = ReventlessInfra.Task.queryBucketName

type operations = ReventlessInfra.Task.operations
type component = Component.t<t, outputs, operations>

type taskAction = Reventless.Task.taskAction =
  | PublishCommands(string, array<Message.commandJson>)
  | CreateSchedule(Reventless.Schedule.schedule)
  | DeleteSchedule(string)
type bucketCallback = Reventless.Task.bucketCallback
type bucketMode = Reventless.Task.bucketMode = Read | Write | ReadWrite
type bucketSpec = Reventless.Task.bucketSpec
type sideEffects = Reventless.Task.sideEffects
type config = Reventless.Task.config
type setup = ReventlessInfra.Task.setup

module type Spec = ReventlessInfra.Task.Spec

type maker = (
  ~queryBucketName: queryBucketName,
  ~scheduler: Scheduler.operations,
  ~publishToAggregates: dict<CommandTopic.publishJsons>,
  ~queryEngine: Reventless.QueryEngine.operations,
  ~resourceNaming: ReventlessInfra.ResourceNaming.operations,
  ~allAggregates: dict<Aggregate.outputs>,
  ~opts: option<Pulumi.ComponentResource.options>,
) => component

let toResolvedOutputs = (
  outputs: outputs,
): Pulumi.Output.t<ReventlessInterop.Task.resolvedOutputs> =>
  switch (outputs.bucketNames, outputs.sideEffectSources) {
  | (Some(bucketNames), Some(sideEffectSources)) =>
    bucketNames
    ->Dict.toArray
    ->Array.map(((k, v)) => v->Pulumi.Output.apply(resolved => (k, resolved)))
    ->Pulumi.Output.all
    ->Pulumi.Output.apply(pairs => {
      let resolved: ReventlessInterop.Task.resolvedOutputs = {
        name: outputs.name,
        bucketNames: pairs->Dict.fromArray,
        sideEffectSources,
      }
      resolved
    })
  | (Some(bucketNames), None) =>
    bucketNames
    ->Dict.toArray
    ->Array.map(((k, v)) => v->Pulumi.Output.apply(resolved => (k, resolved)))
    ->Pulumi.Output.all
    ->Pulumi.Output.apply(pairs => {
      let resolved: ReventlessInterop.Task.resolvedOutputs = {
        name: outputs.name,
        bucketNames: pairs->Dict.fromArray,
      }
      resolved
    })
  | (None, Some(sideEffectSources)) =>
    Pulumi.Output.make({
      ReventlessInterop.Task.name: outputs.name,
      sideEffectSources,
    })
  | (None, None) =>
    Pulumi.Output.make({
      ReventlessInterop.Task.name: outputs.name,
    })
  }

module type T = {
  module Spec: Spec
  type component = Component.t<t, outputs, operations>
  let make: maker
  let outputs: component => outputs
}
