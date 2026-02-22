// Cross-stack resolved output type for the Task component.
// This is the Output.t-free, JSON-serializable counterpart of ReventlessSpec.Task.outputs.
// Pulumi resolves all pending Output.t values before serializing stack exports, so
// bucketNames is dict<string> here instead of dict<Pulumi.Output.t<string>>.

@schema
type resolvedOutputs = {
  name: string,
  bucketNames?: dict<string>,
  sideEffectSources?: array<string>,
}
