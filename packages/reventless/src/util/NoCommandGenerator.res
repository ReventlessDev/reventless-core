module Make = (Spec: ReventlessSpec.Aggregate.Spec): (
  CommandGenerator.T with module Spec = Spec
) => {
  module Spec = Spec

  @obj
  external makeOutputs: (
    ~resources: array<ReventlessSpec.Adapter.resource>,
  ) => CommandGenerator.outputs = ""

  external outputsToComponent: CommandGenerator.outputs => CommandGenerator.component = "%identity"

  let make = (~name as _, ~publishJsons as _, ~opts as _=?) =>
    makeOutputs(~resources=[])->outputsToComponent
}
