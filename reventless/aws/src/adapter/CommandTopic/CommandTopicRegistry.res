// Where each component's CommandTopic queue lives, recorded as the queue is
// created.
//
// Runtime code cannot be handed a publisher. A slice Lambda is a compiled
// EntryPoint configured through `HANDLER_CONFIG`, not a serialized closure —
// that separation is what fixed the cold-start crashes from closures mixing
// layer and runtime SDK versions — so a `publishJsons` function cannot cross
// into it. The same choice has to travel as *data*: which queue, and whether it
// is FIFO.
//
// Captured here rather than recovered later, because recovering it does not
// work. A component's `resources` array reaches callers inside a
// `Pulumi.Output.t`, and although every `resource` field is typed
// `Pulumi.Output.t<string>`, Pulumi flattens nested Outputs at resolution — so
// within the enclosing apply those fields are already plain strings and calling
// `.apply` on one throws. At creation the queue is still concrete: `.id` is a
// flat Output, and the creating module's identity already settles the flavor.
//
// Keyed by owner *name* — an Aggregate's `Spec.name` — which is the same key an
// OutboundTranslationSlice names in `targetName`.

type entry = {
  /** The queue URL, for a runtime publisher rebuilt from configuration. */
  queueUrl: Pulumi.Output.t<string>,
  /** The queue as a deploy-time resource, so a caller can add it to a channel
      spec and pick up `connectLambda`'s existing `sqs:SendMessage` grant. */
  resource: ReventlessInfra.Adapter.resource,
  /** FIFO queues need a `MessageGroupId` and standard queues reject one, so this
      cannot be assumed by the caller — it is a property of the queue that only
      the module which created it knows. */
  isFifo: bool,
}

let byOwner: dict<entry> = Dict.make()

let register = (
  ~owner: option<ReventlessCore.ResourceAttribution.owner>,
  ~queueUrl: Pulumi.Output.t<string>,
  ~resource: ReventlessInfra.Adapter.resource,
  ~isFifo: bool,
) =>
  owner->Option.forEach(({name}) =>
    byOwner->Dict.set(name, {queueUrl, resource, isFifo})
  )

/** The CommandTopic of the component with this name, if one has been created.
    `None` for a target that is not an Aggregate in this plugin — a DCB
    StateChangeSlice, or a name that matches nothing — where the caller keeps
    the plugin-wide DCB command topic. */
let get = (name: string) => byOwner->Dict.get(name)
