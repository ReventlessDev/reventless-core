// TODO: refactor to abstractions
let componentType = ComponentType.Task

type publishCommands = (
  /* ~aggregateName: */ string,
  array<Message.commandJson>,
) => Js.Promise.t<unit>

type outputs = {
  name: string,
  bucket?: PulumiAws.S3.Bucket.t,
  sideEffectHandler?: SideEffectHandler.outputs,
}

type t
type component = Component.t<t, outputs, unit>

type queryBucketName = string => string

type maker = (
  ~queryBucketName: queryBucketName,
  ~scheduler: Scheduler.operations,
  ~publishToAggregates: Js.Dict.t<CommandTopic.publishJsons>,
  ~queryEngine: ReventlessSpec.QueryEngine.operations,
  ~allAggregates: Js.Dict.t<Aggregate.outputs>,
  ~opts: option<Pulumi.ComponentResource.options>,
) => component

type setup = (
  ReventlessSpec.QueryEngine.operations,
  Scheduler.operations,
  publishCommands,
  queryBucketName,
  EventTopic.allOutputs,
  Pulumi.Output.t<CommandTopic.allOutputs>,
  Pulumi.CustomResourceOptions.t,
) => outputs

let construct = (
  ~setup: setup,
  ~queryBucketName,
  ~scheduler,
  ~publishToAggregates,
  ~queryEngine,
  ~allAggregates,
  self,
  _name,
) => {
  let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

  let publishCommands: publishCommands = (aggregateName, cmdJsons) => {
    (publishToAggregates->Js.Dict.get(aggregateName)->Belt.Option.getExn)(cmdJsons)
  }

  self->Component.setOutputs(
    setup(
      queryEngine,
      scheduler,
      publishCommands,
      queryBucketName,
      allAggregates->Aggregate.allEventTopics,
      allAggregates->Aggregate.allCommandTopics,
      opts,
    ),
  )
}

let make = (
  ~name,
  ~setup,
  ~queryBucketName,
  ~scheduler,
  ~publishToAggregates,
  ~queryEngine,
  ~allAggregates,
  ~opts,
) =>
  Component.make(
    ~componentType=componentType->ComponentType.toString,
    ~name=name->ComponentType.name(componentType),
    ~construct=construct(
      ~setup,
      ~queryBucketName,
      ~scheduler,
      ~publishToAggregates,
      ~queryEngine,
      ~allAggregates,
      ...
    ),
    ~opts
  )
