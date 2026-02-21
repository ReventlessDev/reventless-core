module Make = (ScheduledPublisher: Scheduler_Adapter.ScheduledPublisher): Scheduler.T => {
  let construct = (self, name): Component.constructed => {
    let opts = {Pulumi.CustomResourceOptions.parent: self->Component.toPulumiResource}

    let scheduledPublisher = ScheduledPublisher.make(~name, ~opts)

    self->Component.setOperations(scheduledPublisher.operations)
    let outputs: Scheduler.outputs = {resource: scheduledPublisher.resource}
    self->Component.setOutputs(outputs)
  }

  let make = (~opts=?): Scheduler.component =>
    Component.make(
      ~componentType=Scheduler.componentType->ComponentType.toString,
      ~name=Scheduler.componentType->ComponentType.toName,
      ~construct,
      ~opts,
    )
}
