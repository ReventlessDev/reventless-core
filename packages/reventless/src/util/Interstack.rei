let mergeServices: array(Service.outputs) => Pulumi.Output.t(array(Service.outputs));
let mergeTasks: ref(array(Task.outputs)) => Pulumi.Output.t(array(Task.outputs));
let mergeEventMappers:
  ref(array(EventMapper.outputs)) => Pulumi.Output.t(array(EventMapper.outputs));
