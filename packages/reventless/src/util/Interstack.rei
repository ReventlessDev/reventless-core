let mergeServices: array(Service.t) => Pulumi.Output.t(array(Service.t));
let mergeTasks: ref(array(Task.t)) => Pulumi.Output.t(array(Task.t));
let mergeEventMappers:
  ref(array(EventMapper.t)) => Pulumi.Output.t(array(EventMapper.t));
