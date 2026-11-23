let componentType = ComponentType.InboundTranslationSlice

type t = ReventlessInfra.InboundTranslationSlice.t
type outputs = ReventlessInfra.InboundTranslationSlice.outputs
type operations = ReventlessInfra.InboundTranslationSlice.operations
type acceptedResult = ReventlessInfra.InboundTranslationSlice.acceptedResult
type rejectedResult = ReventlessInfra.InboundTranslationSlice.rejectedResult
type component = Component.t<t, outputs, operations>

/** Whether a slice keeps an audit log of what it receives: not where its door is
    open to visitors, whose requests are set by whoever sends them and are counted
    instead. Its commands' rules decide, as they decide its door's. */
let keepsAudit = (
  ~commandSchema: S.t<unknown>,
  ~authorizationOf: string => Reventless.Authorization.permission,
): bool =>
  Plugin_Structure.inboundDoorPermission(~commandSchema, ~authorizationOf) !=
    Some(Reventless.Authorization.AllowAnonymous)

let toResolvedOutputs = (outputs: outputs): Pulumi.Output.t<
  ReventlessInterop.InboundTranslationSlice.resolvedOutputs,
> =>
  (
    outputs.resources->Adapter.resourcesToInterop,
    outputs.queryDb->Option.mapOr([], db => db.resources)->Adapter.resourcesToInterop,
  )
  ->Pulumi.Output.all2
  ->Pulumi.Output.apply(((resources, queryDbResources)) => {
    let resolved: ReventlessInterop.InboundTranslationSlice.resolvedOutputs = {
      resources,
      queryDb: {resources: queryDbResources},
    }
    resolved
  })

module type T = {
  module Spec: Reventless.InboundTranslationSlice.Spec
  module Translation: Reventless.InboundTranslationSlice.Translation with module Spec := Spec
  type component = Component.t<t, outputs, operations>
  let queryDbName: string
  /** Whether each request is kept in an audit log: not for a door open to visitors. */
  let audited: bool

  let make: (
    ~publishJsons: Pulumi.Output.t<CommandTopic.publishJsons>,
    /** The target's publish that waits for each command's outcome, where its topic
        offers one; the caller then hears the target's refusal. */
    ~publishJsonsAndWait: Pulumi.Output.t<option<CommandTopic.publishJsonsAndWait>>=?,
    ~runtime: ReventlessInfra.RuntimeHints.t=?,
    ~opts: Pulumi.ComponentResource.options=?,
  ) => component
}
