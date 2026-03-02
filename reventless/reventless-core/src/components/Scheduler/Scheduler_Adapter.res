type scheduledPublisher = {
  resource: ReventlessInfra.Adapter.resource,
  operations: Pulumi.Output.t<Scheduler.operations>,
}

type scheduledPublisherMaker = (
  ~name: string,
  ~opts: Pulumi.CustomResourceOptions.t,
) => scheduledPublisher

module type ScheduledPublisher = {
  let make: scheduledPublisherMaker
}
