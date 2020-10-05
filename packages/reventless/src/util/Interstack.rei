type plugin = {
  .
  "services": option(Js.Dict.t(Service.outputs)),
  "tasks": option(Js.Dict.t(Task.outputs)),
  "eventMappers": option(Js.Dict.t(EventMapper.outputs)),
  "extensionPoints": option(Js.Dict.t(ExtensionPoint.outputs)),
  "apiUrl": option(string) // this is only present in core & api stack
};

let coreStackReference: option(Pulumi.StackReference.t);
let coreStackOutput: option(Pulumi.Output.t(plugin));

let mergeServices:
  array(Service.outputs) => Pulumi.Output.t(array(Service.outputs));
let mergeTasks:
  ref(array(Task.outputs)) => Pulumi.Output.t(array(Task.outputs));
let mergeEventMappers:
  ref(array(EventMapper.outputs)) =>
  Pulumi.Output.t(array(EventMapper.outputs));
