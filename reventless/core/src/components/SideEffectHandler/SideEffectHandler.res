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
}
