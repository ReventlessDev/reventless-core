type runner = {resources: array<ReventlessSpec.Adapter.resource>}

type runnerMaker<'runtimeParts> = (
  ~name: string,
  ~timeout: int,
  ~runtime: Runtime.environment<'runtimeParts>,
  ~opts: Pulumi.ComponentResource.options,
) => runner

module type Runner = {
  type runtimeParts
  let make: runnerMaker<runtimeParts>
}
