let coreStackReference: option<Pulumi.StackReference.t>

let stackDependenciesTasks: Pulumi.Output.t<
  array<result<ReventlessInterop.Task.resolvedOutputs, ReventlessInterop.Compat.error>>,
>

let stackDependenciesEventMappers: Pulumi.Output.t<
  array<result<ReventlessInterop.EventMapper.resolvedOutputs, ReventlessInterop.Compat.error>>,
>

let mergeTasks: array<ReventlessInterop.Task.resolvedOutputs> => Pulumi.Output.t<
  array<ReventlessInterop.Task.resolvedOutputs>,
>

let mergeEventMappers: array<ReventlessInterop.EventMapper.resolvedOutputs> => Pulumi.Output.t<
  array<ReventlessInterop.EventMapper.resolvedOutputs>,
>
