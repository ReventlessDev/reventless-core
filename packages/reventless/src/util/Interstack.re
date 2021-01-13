type plugin = {
  .
  "services": option(Js.Dict.t(Service.outputs)),
  "tasks": option(Js.Dict.t(Task.outputs)),
  "eventMappers": option(Js.Dict.t(EventMapper.outputs)),
  "extensionPoints": option(Js.Dict.t(ExtensionPoint.outputs)),
  "apiUrl": option(string) // this is only present in core & api stack
}; // TODO: add type core and use it for coreStackReference

let coreStackReference =
  Pulumi.Config.make(Some("core"))
  ->Pulumi.Config.get("stack")
  ->Belt.Option.map(stack => stack->Pulumi.StackReference.make);

let coreStackOutput =
  coreStackReference->Belt.Option.map(coreStack =>
    coreStack->Pulumi.StackReference.requireOutput("core"->Pulumi.Input.wrap)
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
  getOutputs(plugin => plugin##services);

let stackDependenciesTasks: Pulumi.Output.t(array(Task.outputs)) =
  getOutputs(plugin => plugin##tasks);

let stackDependenciesEventMappers:
  Pulumi.Output.t(array(EventMapper.outputs)) =
  getOutputs(plugin => plugin##eventMappers);

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
