let componentType = ComponentType.Task

type t
type outputs = Reventless.Task.outputs

type publishCommands = (/* ~aggregateName: */ string, array<Message.commandJson>) => promise<unit>
type queryBucketName = Reventless.Task.queryBucketName

type operations = Reventless.Task.operations
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
type setup = Reventless.Task.setup

module type Spec = Reventless.Task.Spec

type maker = (
  ~queryBucketName: queryBucketName,
  ~scheduler: Scheduler.operations,
  ~publishToAggregates: dict<CommandTopic.publishJsons>,
  ~queryEngine: Reventless.QueryEngine.operations,
  ~resourceNaming: Reventless.ResourceNaming.operations,
  ~allAggregates: dict<Aggregate.outputs>,
  ~opts: option<Pulumi.ComponentResource.options>,
) => component

module type T = {
  module Spec: Spec
  type component = Component.t<t, outputs, operations>
  let make: maker
  let outputs: component => outputs
}
