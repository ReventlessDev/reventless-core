type queryBucketName = (~taskName: string, ~bucketName: string=?) => string

type taskAction =
  | PublishCommands(string, array<Message.commandJson>)
  | CreateSchedule(Schedule.schedule)
  | DeleteSchedule(string)
type bucketCallback = (~eventName: string, ~key: string) => promise<array<taskAction>>
type bucketMode = Read | Write | ReadWrite
type bucketSpec = {bucketName?: string, bucketMode: bucketMode, callback?: bucketCallback}
type sideEffects = array<module(SideEffect.T)>
type config = {
  buckets?: array<bucketSpec>,
  sideEffects?: sideEffects,
}
type setup = (QueryEngine.operations, queryBucketName, Pulumi.ComponentResource.options) => config

module type Spec = {
  let name: string
  let setup: setup
}

type outputs = {
  name: string,
  bucketNames?: dict<Pulumi.Output.t<string>>,
  sideEffectSources?: array<string>,
}
type operations = {publishCommands: (string, array<Message.commandJson>) => promise<unit>}

module type T = {
  module Spec: Spec
  type component
  let make: (
    ~queryBucketName: queryBucketName,
    ~scheduler: Scheduler.operations,
    ~publishToAggregates: dict<CommandTopic.publishJsons>,
    ~queryEngine: QueryEngine.operations,
    ~resourceNaming: ResourceNaming.operations,
    ~allAggregates: dict<Aggregate.outputs>,
    ~opts: option<Pulumi.ComponentResource.options>,
  ) => component
  let outputs: component => outputs
}
