let componentType = ComponentType.Task

type t
type outputs = {
  name: string,
  buckets?: dict<Pulumi.Output.t<string>>,
  sideEffects?: array<string>,
}

type publishCommands = (
  /* ~aggregateName: */ string,
  array<Message.commandJson>,
) => Js.Promise.t<unit>
type queryBucketName = (~taskName: string, ~bucketName: string=?) => string

type operations = {publishCommands: publishCommands}
type component = Component.t<t, outputs, operations>

type bucketCallback = (~eventName: string, ~key: string) => promise<unit>

type bucketSpec = {bucketName: string, callback: bucketCallback}
type config = {
  buckets?: array<bucketSpec>,
  sideEffects?: Reventless.SideEffectHandler.sideEffects,
}

type setup = (
  ReventlessSpec.QueryEngine.operations,
  Scheduler.operations,
  publishCommands,
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
