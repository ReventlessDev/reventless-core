// Configuration the bundled Task runtime needs to dispatch CreateSchedule /
// DeleteSchedule actions to the underlying scheduler service. None on
// adapters without a real scheduler (in-memory) or on Tasks without a
// side-effect handler — those Tasks can't schedule anything.
type schedulerConfig = {
  /** URN identifying the principal/role the scheduler invokes targets as. */
  schedulerRoleUrn: Pulumi.Output.t<string>,
  /** URN of the channel resource the schedule will deliver events to (the
      side-effect handler's collector channel). */
  targetUrn: Pulumi.Output.t<string>,
  /** Logical name of the target resource — used as the schedule target's id. */
  targetName: Pulumi.Output.t<string>,
}

module type T = {
  type context
  type callbackEvent
  type runtimeParts

  let forBucketCallback: (
    ~handler: Pulumi.Output.t<Runtime.eventHandler<callbackEvent, context, unit>>,
    ~connect: Runtime.connect<runtimeParts>,
    ~memorySize: int=?,
    ~timeout: int=?,
    ~name: string,
    ~callbackModulePath: string,
    ~publishToAggregatesQueueUrls: dict<Pulumi.Output.t<string>>,
    ~schedulerConfig: option<schedulerConfig>,
    Task.component,
  ) => unit
  let finish: unit => unit
}
