open ReventlessSpec.Adapter

let componentType = ComponentType.Cloner

type outputs = {"resources": array<resource>}

type fullQualifiedStackName = {
  organization: string,
  project: string,
  stack: string,
}

type t
type component = ReventlessSpec.Component.t<t, outputs>

module type T = {
  let make: (~opts: Pulumi.ComponentResource.Options.t=?, unit) => component
}

module Adapter = {
  type runner = {resources: Pulumi.Output.t<array<resource>>}
  type runnerMaker<'api> = (
    ~name: string,
    ~api: 'api,
    ~fullQualifiedStackName: fullQualifiedStackName,
    ~reventlessCiSecretUrn: string,
    ~secretUrns: array<string>,
    ~opts: Pulumi.CustomResourceOptions.t=?,
    unit,
  ) => runner

  module type Runner = {
    type api

    let make: runnerMaker<api>
  }

  let noRunner = {resources: []->Pulumi.Output.make}
}

module Make = (Config: Config.T, Runner: Adapter.Runner with type api := Config.api): T => {
  type constructed
  type construct = (component, string) => constructed

  @module("./Component") @new
  external make: (
    ~componentType: string,
    ~name: string,
    ~construct: construct,
    ~opts: option<Pulumi.ComponentResource.Options.t>,
  ) => component = "default"

  @obj
  external makeOutputs: (~resources: Pulumi.Output.t<array<resource>>) => outputs = ""

  @send
  external registerOutputs: (component, outputs) => constructed = "registerOutputs"
  @send external setOutputs: (component, outputs) => unit = "setOutputs"
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs)
    self->registerOutputs(outputs)
  }

  let construct = (~api, self, name) => {
    let opts = Pulumi.CustomResourceOptions.make(~parent=self->Component.toPulumiResource, ())

    let fullQualifiedStackName = {
      organization: Env.pulumiOrganization->Belt.Option.getWithDefault("NO_ORGANIZATION"),
      project: Pulumi.Pulumi.getProjectName(),
      stack: Pulumi.Pulumi.getStackName(),
    }
    let secretsConfig = Pulumi.Config.make(Some("secrets"))
    let secretUrns =
      ["aws", "pulumi", "repository"]->Belt.Array.map(secretsConfig->Pulumi.Config.get(_))
    let reventlessCiSecretUrn = secretsConfig->Pulumi.Config.get("reventless-ci")

    let runner = switch (secretUrns, reventlessCiSecretUrn) {
    | ([Some(aws), Some(pulumi), Some(repository)], Some(reventlessCiSecretUrn)) =>
      Runner.make(
        ~name,
        ~api,
        ~fullQualifiedStackName,
        ~reventlessCiSecretUrn,
        ~secretUrns=[aws, pulumi, repository],
        ~opts,
        (),
      )

    | _ =>
      Js.log("No ClonerRunner created because no secrets are configured in Pulumi config !")
      Adapter.noRunner
    }
    self->setOutputs(makeOutputs(~resources=runner.resources))
  }

  let make = (~opts=?, _) =>
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name=componentType->ComponentType.toString,
      ~construct=construct(~api=Config.api),
      ~opts,
    )
}
