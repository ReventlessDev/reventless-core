let coreStackReference =
  Pulumi.Config.make(Some("core"))
  ->Pulumi.Config.get("stack")
  ->Belt.Option.map(stack => stack->Pulumi.StackReference.make)

let stackDependencies =
  {
    open Pulumi.Config
    make(Some("interstack"))->getObject("dependencies")
  }
  ->Belt.Option.getWithDefault([])
  ->Array.map(stackName => {
    open Pulumi.StackReference
    make(stackName)
  })
  ->Belt.Array.concat(coreStackReference->Belt.Option.mapWithDefault([], coreStack => [coreStack]))

let getOutputs = name =>
  stackDependencies
  ->Array.map(stackRef => stackRef->Pulumi.StackReference.getOutput(name))
  ->Pulumi.Output.all
  ->Pulumi.Output.apply(outputs => outputs->Belt.Array.keepMap(x => x))

let stackDependenciesTasks: Pulumi.Output.t<array<Task.outputs>> = getOutputs("tasks")

let stackDependenciesEventMappers: Pulumi.Output.t<array<EventMapper.outputs>> = getOutputs(
  "eventMappers",
)

let mergeMany: (Pulumi.Output.t<array<'a>>, array<'a>) => Pulumi.Output.t<array<'a>> = (
  dependencies,
  locals,
) => dependencies->Pulumi.Output.apply(dependencies => locals->Belt.Array.concat(dependencies))

let mergeTasks = mergeMany(stackDependenciesTasks, ...)
let mergeEventMappers = mergeMany(stackDependenciesEventMappers, ...)
