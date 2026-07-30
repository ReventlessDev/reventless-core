module ReventlessEventCollector = EventCollector

let componentType = ComponentType.SideEffectHandler

type t
type outputs = {name: string, eventCollector: EventCollector.outputs}
type operations = {
  enqueueEvent: EventCollector.enqueueEvent,
  createSchedule: Reventless.Schedule.create,
  deleteSchedule: Reventless.Schedule.delete,
}
type component = Component.t<t, outputs, operations>

type sideEffects = array<module(Reventless.SideEffect.T)>

module type T = {
  let make: (
    ~name: string,
    ~sideEffects: sideEffects,
    ~allEventTopics: EventTopic.allOutputs,
    ~allCommandTopics: Pulumi.Output.t<CommandTopic.allOutputs>,
    ~targets: array<string>=?,
    ~queryEngine: Reventless.QueryEngine.operations,
    ~scheduler: Scheduler.operations,
    ~resourceNaming: ReventlessInfra.ResourceNaming.operations,
    ~memorySize: int=?,
    ~timeout: int=?,
    // Extra environment variables merged onto the side-effect-handler Lambda — used
    // by bespoke platform side effects (e.g. the admin ApiSchemaPush) to carry
    // deploy-derived config (API ids, command-topic URLs) that `execute` reads at
    // runtime. Ignored by adapters that don't provision a real Lambda (in-memory).
    ~extraEnvVars: dict<Pulumi.Input.t<string>>=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component

  /** Provision the runtime for every handler registered by `make`.
   *
   * Adapters that share one runtime across all side-effect handlers can only build
   * it once every handler has registered, so nothing is provisioned by `make`
   * alone. Every other component type has this seam
   * (`ReadModel_Builder.finish`, `Aggregate_Builder.finish`, …); the side-effect
   * handler went without one, which is why its Lambda was never created. Call it
   * after the last handler is constructed — `Builder_Helpers.finishTasks` gates it
   * on their readiness. Idempotent. */
  let finish: unit => unit
}
