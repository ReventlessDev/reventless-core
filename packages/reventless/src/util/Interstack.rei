let mergeContext: Context.t => Pulumi.Output.t(array(Context.t));
let mergeContexts: array(Context.t) => Pulumi.Output.t(array(Context.t));
let mergeTasks: ref(array(Task.t)) => Pulumi.Output.t(array(Task.t));
let mergeEventMappers:
  ref(array(EventMapper.t)) => Pulumi.Output.t(array(EventMapper.t));