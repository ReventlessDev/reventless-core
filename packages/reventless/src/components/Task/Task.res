let componentType = ComponentType.Task

type t
type outputs = {
  name: string,
  bucketNames?: dict<Pulumi.Output.t<string>>,
  sideEffectSources?: array<string>,
}

type publishCommands = (/* ~aggregateName: */ string, array<Message.commandJson>) => promise<unit>
type queryBucketName = (~taskName: string, ~bucketName: string=?) => string

type operations = {publishCommands: publishCommands}
type component = Component.t<t, outputs, operations>

type taskAction =
  | PublishCommands(string, array<Message.commandJson>)
  | CreateSchedule(ReventlessSpec.Schedule.schedule)
  | DeleteSchedule(string) // TODO add other taskActions
type bucketCallback = (~eventName: string, ~key: string) => promise<array<taskAction>>
type bucketMode = Read | Write | ReadWrite
type bucketSpec = {bucketName?: string, bucketMode: bucketMode, callback?: bucketCallback}
type config = {
  buckets?: array<bucketSpec>,
  sideEffects?: Reventless.SideEffectHandler.sideEffects,
}

type setup = (
  ReventlessSpec.QueryEngine.operations,
  queryBucketName,
  Pulumi.ComponentResource.options,
) => config

module type Spec = {
  let name: string
  let setup: setup
}

type maker = (
  ~queryBucketName: queryBucketName,
  ~scheduler: Scheduler.operations,
  ~publishToAggregates: dict<CommandTopic.publishJsons>,
  ~queryEngine: ReventlessSpec.QueryEngine.operations,
  ~allAggregates: dict<Aggregate.outputs>,
  ~opts: option<Pulumi.ComponentResource.options>,
) => component

module type T = {
  module Spec: Spec

  let make: maker
}
