type runner = {resources: array<ReventlessSpec.Adapter.resource>}

type runnerMaker = (
  ~name: string,
  ~timeout: int,
  ~runtime: Runtime.environment,
  ~opts: Pulumi.ComponentResource.options,
) => runner

module type Runner = {
  let make: runnerMaker
}
