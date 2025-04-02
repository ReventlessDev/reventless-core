let componentType = ComponentType.Cloner

type outputs = {resources: Pulumi.Output.t<array<ReventlessSpec.Adapter.resource>>}

type fullQualifiedStackName = {
  organization: string,
  project: string,
  stack: string,
}

type t
type component = Component.t<t, outputs, unit>

module type T = {
  let make: (~opts: Pulumi.ComponentResource.options=?) => component
}

module Adapter = {
  type runner = {resources: Pulumi.Output.t<array<ReventlessSpec.Adapter.resource>>}
  type runnerMaker<'api> = (
    ~name: string,
    ~api: 'api,
    ~fullQualifiedStackName: fullQualifiedStackName,
    ~reventlessCiSecretUrn: string,
    ~secretUrns: array<string>,
    ~opts: Pulumi.CustomResourceOptions.t=?,
  ) => runner

  module type Runner = {
    type api

    let make: runnerMaker<api>
  }

  let noRunner = {resources: []->Pulumi.Output.make}
}

module Make = (Config: Config.T, Runner: Adapter.Runner with type api := Config.api): T => {
  let construct = (~api, self, name) => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

    let fullQualifiedStackName = {
      organization: Env.pulumiOrganization->Belt.Option.getWithDefault("NO_ORGANIZATION"),
      project: Pulumi.Pulumi.getProjectName(),
      stack: Pulumi.Pulumi.getStackName(),
    }
    let secretsConfig = Pulumi.Config.make(Some("secrets"))
    let secretUrns =
      ["aws", "pulumi", "repository"]->Array.map(str => Pulumi.Config.get(secretsConfig, str))
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
      )

    | _ =>
      Js.log("No ClonerRunner created because no secrets are configured in Pulumi config !")
      Adapter.noRunner
    }
    self->Component.setOutputs({resources: runner.resources})
  }

  let make = (~opts=?) =>
    Component.make(
      ~componentType=componentType->ComponentType.toString,
      ~name=componentType->ComponentType.toString,
      ~construct=construct(~api=Config.api, ...),
      ~opts
    )
}
