type plugin;
[@bs.get]
external getServices: plugin => option(Js.Dict.t(Service.outputs)) =
  "services";
[@bs.get]
external getTasks: plugin => option(Js.Dict.t(Task.outputs)) = "tasks";
[@bs.get]
external getEventMapper: plugin => option(Js.Dict.t(EventMapper.outputs)) =
  "eventMappers";

let coreStackOutput =
  Pulumi.Config.make(Some("core"))
  ->Pulumi.Config.get("stack")
  ->Belt.Option.map(stack =>
      stack
      ->Pulumi.StackReference.make
      ->Pulumi.StackReference.requireOutput("core"->Pulumi.Input.wrap)
    );

let stackDependencies: Pulumi.Output.t(array(plugin)) =
  Pulumi.Config.(make(Some("interstack"))->getObject("dependencies"))
  ->Belt.Option.getWithDefault([||])
  ->Belt.Array.map(stackName =>
      Pulumi.StackReference.(
        make(stackName)->requireOutput("plugin"->Pulumi.Input.wrap)
      )
    )
  ->Belt.Array.concat(
      coreStackOutput->Belt.Option.mapWithDefault([||], coreStack =>
        [|coreStack|]
      ),
    )
  ->Pulumi.Output.all;

let getOutputs:
  (plugin => option(Js.Dict.t('a))) => Pulumi.Output.t(array('a)) =
  getOutput =>
    stackDependencies->Pulumi.Output.apply(plugins =>
      plugins
      ->Belt.Array.map(plugin =>
          plugin->getOutput->Belt.Option.mapWithDefault([||], Js.Dict.values)
        )
      ->Belt.Array.concatMany
    );

let stackDependenciesServices: Pulumi.Output.t(array(Service.outputs)) =
  getOutputs(getServices);

let stackDependenciesTasks: Pulumi.Output.t(array(Task.outputs)) =
  getOutputs(getTasks);

let stackDependenciesEventMappers:
  Pulumi.Output.t(array(EventMapper.outputs)) =
  getOutputs(getEventMapper);

let mergeMany:
  (Pulumi.Output.t(array('a)), array('a)) => Pulumi.Output.t(array('a)) =
  (dependencies, locals) =>
    dependencies->Pulumi.Output.apply(dependencies =>
      locals->Belt.Array.concat(dependencies)
    );

let mergeManyRef:
  (Pulumi.Output.t(array('a)), ref(array('a))) =>
  Pulumi.Output.t(array('a)) =
  (dependencies, locals) =>
    dependencies->Pulumi.Output.apply(dependencies =>
      (locals^)->Belt.Array.concat(dependencies)
    );

let mergeServices = mergeMany(stackDependenciesServices);
let mergeTasks = mergeManyRef(stackDependenciesTasks);
let mergeEventMappers = mergeManyRef(stackDependenciesEventMappers);
