let componentType = ComponentType.Task

type t
type outputs = ReventlessSpec.Task.outputs

type publishCommands = (/* ~aggregateName: */ string, array<Message.commandJson>) => promise<unit>
type queryBucketName = ReventlessSpec.Task.queryBucketName

type operations = ReventlessSpec.Task.operations
type component = Component.t<t, outputs, operations>

type taskAction = ReventlessSpec.Task.taskAction =
  | PublishCommands(string, array<Message.commandJson>)
  | CreateSchedule(ReventlessSpec.Schedule.schedule)
  | DeleteSchedule(string)
type bucketCallback = ReventlessSpec.Task.bucketCallback
type bucketMode = ReventlessSpec.Task.bucketMode = Read | Write | ReadWrite
type bucketSpec = ReventlessSpec.Task.bucketSpec
type sideEffects = ReventlessSpec.Task.sideEffects
type config = ReventlessSpec.Task.config
type setup = ReventlessSpec.Task.setup

module type Spec = ReventlessSpec.Task.Spec

type maker = (
  ~queryBucketName: queryBucketName,
  ~scheduler: Scheduler.operations,
  ~publishToAggregates: dict<CommandTopic.publishJsons>,
  ~queryEngine: ReventlessSpec.QueryEngine.operations,
  ~resourceNaming: ReventlessSpec.ResourceNaming.operations,
  ~allAggregates: dict<Aggregate.outputs>,
  ~opts: option<Pulumi.ComponentResource.options>,
) => component

module type T = {
  module Spec: Spec
  type component = Component.t<t, outputs, operations>
  let make: maker
  let outputs: component => outputs
}
