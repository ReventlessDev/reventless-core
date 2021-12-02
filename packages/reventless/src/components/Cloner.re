open ReventlessSpec.Adapter;

let componentType = ComponentType.Cloner;

type outputs = {. "resources": array(resource)};

type fullQualifiedStackName = {
  organization: string,
  project: string,
  stack: string,
};

type t;
type component = Component.t(t, outputs);

module type T = {
  let make: (~opts: Pulumi.ComponentResource.Options.t=?, unit) => component;
};

module Adapter = {
  type runner = {resources: array(resource)};
  type runnerMaker('api) =
    (
      ~name: string,
      ~api: 'api,
      ~fullQualifiedStackName: fullQualifiedStackName,
      ~containerSecretUrn: string,
      ~secretUrns: array(string),
      ~opts: Pulumi.CustomResourceOptions.t=?,
      unit
    ) =>
    runner;

  module type Runner = {
    type api;

    let make: runnerMaker(api);
  };
};

module Make =
       (Config: Config.T, Runner: Adapter.Runner with type api := Config.api)
       : T => {
  type constructed;
  type construct = (component, string) => constructed;

  [@bs.module "./Component"] [@bs.new]
  external make:
    (
      ~componentType: string,
      ~name: string,
      ~construct: construct,
      ~opts: option(Pulumi.ComponentResource.Options.t)
    ) =>
    component =
    "default";

  [@bs.val]
  external pulumiOrganization: option(string) =
    "process.env.PULUMI_ORGANIZATION";

  [@bs.obj]
  external makeOutputs: (~resources: array(resource)) => outputs = "";

  [@bs.send]
  external registerOutputs: (component, outputs) => constructed =
    "registerOutputs";
  [@bs.send] external setOutputs: (component, outputs) => unit = "setOutputs";
  let setOutputs = (self, outputs) => {
    self->setOutputs(outputs);
    self->registerOutputs(outputs);
  };

  let construct = (~api, self, name) => {
    let opts =
      Pulumi.CustomResourceOptions.make(
        ~parent=self->Component.toPulumiResource,
        (),
      );

    let fullQualifiedStackName = {
      organization:
        pulumiOrganization->Belt.Option.getWithDefault("NO_ORGANIZATION"),
      project: Pulumi.Pulumi.getProjectName(),
      stack: Pulumi.Pulumi.getStackName(),
    };
    let secretsConfig = Pulumi.Config.make(Some("secrets"));
    let secretUrns =
      [|"aws", "pulumi", "repository"|]
      ->Belt.Array.map(secretsConfig->Pulumi.Config.require(_));
    let containerSecretUrn =
      secretsConfig->Pulumi.Config.require("container");

    let runner =
      Runner.make(
        ~name=name->ComponentType.name(componentType),
        ~api,
        ~fullQualifiedStackName,
        ~containerSecretUrn,
        ~secretUrns,
        ~opts,
        (),
      );

    makeOutputs(~resources=runner.resources) |> self->setOutputs;
  };

  let make = (~opts=?, _) => {
    make(
      ~componentType=componentType->ComponentType.toString,
      ~name=componentType->ComponentType.toString,
      ~construct=construct(~api=Config.api),
      ~opts,
    );
  };
};
