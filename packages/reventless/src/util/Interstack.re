type backend;
[@bs.get] external getContexts: backend => array(Context.t) = "contexts";
[@bs.get] external getTasks: backend => array(Task.t) = "tasks";
[@bs.get]
external getEventMapper: backend => array(EventMapper.t) = "eventMappers";

let stackDependencies: Pulumi.Output.t(array(backend)) =
  Pulumi.Config.(make(Some("interstack"))->getObject("dependencies"))
  ->Belt.Option.getWithDefault([||])
  ->Belt.Array.map(stackName =>
      Pulumi.StackReference.(
        make(stackName)->getOutput("backend")->Belt.Option.getExn
      )
    )
  ->Pulumi.Output.all;

let getOutputs: (backend => array('a)) => Pulumi.Output.t(array('a)) =
  getOutput =>
    stackDependencies->Pulumi.Output.apply(backends =>
      backends
      ->Belt.Array.map(backend => backend->getOutput)
      ->Belt.Array.concatMany
    );

let stackDependenciesContexts: Pulumi.Output.t(array(Context.t)) =
  getOutputs(getContexts);

let stackDependenciesTasks: Pulumi.Output.t(array(Task.t)) =
  getOutputs(getTasks);

let stackDependenciesEventMappers: Pulumi.Output.t(array(EventMapper.t)) =
  getOutputs(getEventMapper);

let mergeSingle:
  (Pulumi.Output.t(array('a)), 'a) => Pulumi.Output.t(array('a)) =
  (dependencies, local) =>
    dependencies->Pulumi.Output.apply(dependencies =>
      [|local|]->Belt.Array.concat(dependencies)
    );

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

let mergeContext = mergeSingle(stackDependenciesContexts);
let mergeContexts = mergeMany(stackDependenciesContexts);
let mergeTasks = mergeManyRef(stackDependenciesTasks);
let mergeEventMappers = mergeManyRef(stackDependenciesEventMappers);