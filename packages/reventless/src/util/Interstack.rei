let coreStackReference: option(Pulumi.StackReference.t);

let mergeTasks: array(Task.outputs) => Pulumi.Output.t(array(Task.outputs));
let mergeEventMappers:
  array(EventMapper.outputs) => Pulumi.Output.t(array(EventMapper.outputs));
