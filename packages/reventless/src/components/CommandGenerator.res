let componentType = ComponentType.CommandGenerator

type outputs = {resources: array<ReventlessSpec.Adapter.resource>}

type t
type component = Component.t<t, outputs, unit>

module type T = {
  module Spec: ReventlessSpec.Aggregate.Spec

  let make: (
    ~name: string,
    ~publishJsons: ReventlessSpec.CommandTopic.publishJsons,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}

module Adapter = {
  type resolvers = {resources: array<ReventlessSpec.Adapter.resource>}
  type resolversMaker<'api> = (
    ~name: string,
    ~api: 'api,
    ~fields: array<string>,
    ~commandGenerator: CommandGenerator_Runtime.commandGenerator,
    ~opts: Pulumi.CustomResourceOptions.t,
  ) => resolvers

  module type Resolvers = {
    type api

    let make: resolversMaker<api>
  }
}

module Make = (
  Config: Config.T,
  Spec: ReventlessSpec.Aggregate.Spec,
  Behaviour: Behaviour.T with module Spec := Spec,
  Resolvers: Adapter.Resolvers with type api := Config.api,
): (T with module Spec = Spec) => {
  module Spec = Spec
  module Runtime = CommandGenerator_Runtime.Make(Spec, Behaviour)

  type api = Config.api

  type constructed
  type construct = (component, string, api, Runtime.publishJsons) => constructed

  @module("./Component") @new
  external make: (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option<Pulumi.ComponentResource.options>,
    ~api: api,
    ~publishJsons: Runtime.publishJsons,
  ) => component = "default"

  @send
  external registerOutputs: (component, outputs) => constructed = "registerOutputs"
  //[@send] external setOutputs: (t, outputs) => unit = "setOutputs";

  let construct = (self, name, api, publishJsons) => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

    let resolvers = Resolvers.make(
      ~name=name->ComponentType.name(componentType),
      ~api,
      ~fields=Behaviour.resolverConfig.fields,
      ~commandGenerator=Runtime.generateCommand(publishJsons),
      ~opts,
    )

    //self->setOutputs(outputs); // NOTE: creates circular reference (promise leaks)
    self->registerOutputs({resources: resolvers.resources})
  }

  let make = (~name, ~publishJsons, ~opts=?) =>
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name,
      ~construct,
      ~opts,
      ~api=Config.api,
      ~publishJsons,
    )
}
