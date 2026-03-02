type runner = {resources: array<ReventlessInfra.Adapter.resource>}

type runnerMaker<'runtimeParts> = (
  ~name: string,
  ~remoteChannel: CommandTopic_Adapter.remoteChannel,
  ~timeout: int,
  ~runtime: Runtime.environment<'runtimeParts>,
  ~opts: Pulumi.ComponentResource.options,
) => runner

module type Runner = {
  type runtimeParts
  let make: runnerMaker<runtimeParts>
}
