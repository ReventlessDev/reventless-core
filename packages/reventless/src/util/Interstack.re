let coreStackReference =
  Pulumi.Config.make(Some("core"))
  ->Pulumi.Config.get("stack")
  ->Belt.Option.map(stack => stack->Pulumi.StackReference.make);

let stackDependencies =
  Pulumi.Config.(make(Some("interstack"))->getObject("dependencies"))
  ->Belt.Option.getWithDefault([||])
  ->Belt.Array.map(stackName => Pulumi.StackReference.(make(stackName)))
  ->Belt.Array.concat(
      coreStackReference->Belt.Option.mapWithDefault([||], coreStack =>
        [|coreStack|]
      ),
    );

let getOutputs = name =>
  stackDependencies
  ->Belt.Array.keepMap(stackRef =>
      stackRef->Pulumi.StackReference.getOutput(name)
    )
  ->Pulumi.Output.all;

let stackDependenciesTasks: Pulumi.Output.t(array(Task.outputs)) =
  getOutputs("tasks");

let stackDependenciesEventMappers:
  Pulumi.Output.t(array(EventMapper.outputs)) =
  getOutputs("eventMappers");

let mergeMany:
  (Pulumi.Output.t(array('a)), array('a)) => Pulumi.Output.t(array('a)) =
  (dependencies, locals) =>
    dependencies->Pulumi.Output.apply(dependencies =>
      locals->Belt.Array.concat(dependencies)
    );

let mergeManyRef:
  (Pulumi.Output.t(array('a)), array('a)) => Pulumi.Output.t(array('a)) =
  (dependencies, locals) =>
    dependencies->Pulumi.Output.apply(dependencies =>
      locals->Belt.Array.concat(dependencies)
    );

let mergeTasks = mergeManyRef(stackDependenciesTasks);
let mergeEventMappers = mergeManyRef(stackDependenciesEventMappers);
