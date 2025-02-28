type runner = {resources: array<ReventlessSpec.Adapter.resource>}

type runnerMaker = (
  ~name: string,
  ~timeout: int,
  ~runtime: Runtime.environment,
  ~opts: Pulumi.CustomResourceOptions.t,
) => runner

module type Runner = {
  let make: runnerMaker
}
