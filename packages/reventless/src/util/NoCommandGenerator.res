module Make = (Spec: ReventlessSpec.Aggregate.Spec): CommandGenerator.T => {
  external outputsToComponent: CommandGenerator.outputs => CommandGenerator.component = "%identity"

  let make = (~name as _, ~publishJsons as _, ~opts as _=?) => {resources: []}->outputsToComponent
}
