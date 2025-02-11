// TODO: refactor to abstractions
let componentType = ComponentType.Task

type publishCommands = (
  . /* ~aggregateName: */ string,
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
  ~publishToAggregates: Js.Dict.t<ReventlessSpec.CommandTopic.publishJsons>,
  ~queryEngine: ReventlessSpec.QueryEngine.operations,
  ~allAggregates: Js.Dict.t<Aggregate.outputs>,
  ~opts: option<Pulumi.ComponentResource.options>,
) => component

type setup = (
  . ReventlessSpec.QueryEngine.operations,
  Scheduler.operations,
  publishCommands,
  queryBucketName,
  EventTopic.allOutputs,
  Pulumi.CustomResourceOptions.t,
) => outputs

type constructed
type construct = (component, string) => constructed

@module("./Component") @new
external make: (
  ~componentType: string,
  ~name: string,
  ~construct: construct,
  ~opts: option<Pulumi.ComponentResource.options>,
) => component = "default"

@send
external registerOutputs: (component, outputs) => constructed = "registerOutputs"
@send external setOutputs: (component, outputs) => unit = "setOutputs"
let setOutputs = (self, outputs) => {
  self->setOutputs(outputs)
  self->registerOutputs(outputs)
}

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

  self->setOutputs(
    setup(
      queryEngine,
      scheduler,
      publishCommands,
      queryBucketName,
      Aggregate.allEventTopics(allAggregates),
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
  make(
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
    ~opts,
  )
