open JestGlobals

// The registry only forwards `~resources` and `~opts`; it never reads their
// fields. A structural stand-in keeps @pulumi/pulumi (whose Output.make would
// build a real resource) out of the Jest run — its ESM entry can't be imported
// under Jest. Same reason as MonitoringTest's stub.
let stubResource: ReventlessInfra.Adapter.resource = %raw(`{}`)
let noOpts: Pulumi.CustomResourceOptions.t = {}

let classicOwner: ResourceAttribution.owner = {kind: ComponentType.Aggregate, name: "Product"}
let dcbOwner: ResourceAttribution.owner = {kind: ComponentType.Plugin, name: "Catalog"}

describe("EventLogProvisioning", () => {
  testSync("Noop default: notify is silent and does not throw", () => {
    // No backend registered — the default Noop backend swallows the call.
    EventLogProvisioning.notify(
      ~logStyle=Classic,
      ~name="ProductEventLog",
      ~owner=Some(classicOwner),
      ~resources=[],
      ~opts=noOpts,
    )
    expect(true)->toBe(true)
  })

  testSync("use registers a backend that receives every notify, style and name", () => {
    let recorded: array<(EventLogProvisioning.logStyle, string)> = []
    module Recorder: EventLogProvisioning.Backend = {
      let onProvisioned = (
        ~logStyle,
        ~name,
        ~owner as _,
        ~plugin as _,
        ~platform as _,
        ~resources as _,
        ~opts as _,
      ) => recorded->Array.push((logStyle, name))
    }
    EventLogProvisioning.use(module(Recorder: EventLogProvisioning.Backend))

    EventLogProvisioning.notify(
      ~logStyle=Classic,
      ~name="ProductEventLog",
      ~owner=Some(classicOwner),
      ~resources=[],
      ~opts=noOpts,
    )
    EventLogProvisioning.notify(
      ~logStyle=Dcb,
      ~name="CatalogDcbEventLog",
      ~owner=Some(dcbOwner),
      ~resources=[],
      ~opts=noOpts,
    )

    expect(recorded)->toEqual([
      (EventLogProvisioning.Classic, "ProductEventLog"),
      (EventLogProvisioning.Dcb, "CatalogDcbEventLog"),
    ])

    // Restore the default so registry state doesn't leak to other cases.
    EventLogProvisioning.reset()
  })

  testSync("notify forwards the owner and the adapter's resources unchanged", () => {
    let seen: ref<
      option<(option<ResourceAttribution.owner>, array<ReventlessInfra.Adapter.resource>)>,
    > = ref(None)
    module Capture: EventLogProvisioning.Backend = {
      let onProvisioned = (
        ~logStyle as _,
        ~name as _,
        ~owner,
        ~plugin as _,
        ~platform as _,
        ~resources,
        ~opts as _,
      ) => seen := Some((owner, resources))
    }
    EventLogProvisioning.use(module(Capture: EventLogProvisioning.Backend))

    EventLogProvisioning.notify(
      ~logStyle=Classic,
      ~name="ProductEventLog",
      ~owner=Some(classicOwner),
      ~resources=[stubResource],
      ~opts=noOpts,
    )
    switch seen.contents {
    | Some((owner, resources)) =>
      expect(owner)->toEqual(Some(classicOwner))
      expect(resources)->toHaveLength(1)
    | None => expect("no notify received")->toBe("a notify")
    }

    EventLogProvisioning.reset()
  })

  testSync("a Postgres-style log with no resources still fires — the contract is uniform", () => {
    // Postgres and in-memory adapters return `resources: []`. Backends that only
    // implement a DynamoDB arm ignore those; the seam does not filter for them.
    let styles: array<EventLogProvisioning.logStyle> = []
    module Recorder: EventLogProvisioning.Backend = {
      let onProvisioned = (
        ~logStyle,
        ~name as _,
        ~owner as _,
        ~plugin as _,
        ~platform as _,
        ~resources,
        ~opts as _,
      ) =>
        if resources->Array.length == 0 {
          styles->Array.push(logStyle)
        }
    }
    EventLogProvisioning.use(module(Recorder: EventLogProvisioning.Backend))

    EventLogProvisioning.notify(
      ~logStyle=Dcb,
      ~name="CatalogDcbEventLog",
      ~owner=Some(dcbOwner),
      ~resources=[],
      ~opts=noOpts,
    )

    expect(styles)->toEqual([EventLogProvisioning.Dcb])
    EventLogProvisioning.reset()
  })

  testSync("notify delivers the ambient plugin/platform inside a construct scope, None outside", () => {
    let seen: array<(option<string>, option<string>)> = []
    module OwnerCapture: EventLogProvisioning.Backend = {
      let onProvisioned = (
        ~logStyle as _,
        ~name as _,
        ~owner as _,
        ~plugin,
        ~platform,
        ~resources as _,
        ~opts as _,
      ) => seen->Array.push((plugin, platform))
    }
    EventLogProvisioning.use(module(OwnerCapture: EventLogProvisioning.Backend))

    // Outside any plugin construct: both None.
    EventLogProvisioning.notify(
      ~logStyle=Classic,
      ~name="ProductEventLog",
      ~owner=Some(classicOwner),
      ~resources=[],
      ~opts=noOpts,
    )

    // Inside a construct scope (what Plugin_Builder.construct establishes): both delivered.
    let prev = ResourceAttribution.enter(~platform="online-shop", ~plugin="Catalog")
    EventLogProvisioning.notify(
      ~logStyle=Dcb,
      ~name="CatalogDcbEventLog",
      ~owner=Some(dcbOwner),
      ~resources=[],
      ~opts=noOpts,
    )
    ResourceAttribution.restore(prev)

    // After restore: back to None.
    EventLogProvisioning.notify(
      ~logStyle=Classic,
      ~name="OrderEventLog",
      ~owner=None,
      ~resources=[],
      ~opts=noOpts,
    )

    expect(seen)->toEqual([(None, None), (Some("Catalog"), Some("online-shop")), (None, None)])

    EventLogProvisioning.reset()
  })

  testSync("use is single-slot: a second registration throws rather than silently winning", () => {
    module First: EventLogProvisioning.Backend = {
      let onProvisioned = (
        ~logStyle as _,
        ~name as _,
        ~owner as _,
        ~plugin as _,
        ~platform as _,
        ~resources as _,
        ~opts as _,
      ) => ()
    }
    EventLogProvisioning.use(module(First: EventLogProvisioning.Backend))

    let threw = try {
      EventLogProvisioning.use(module(First: EventLogProvisioning.Backend))
      false
    } catch {
    | _ => true
    }
    expect(threw)->toBe(true)

    // reset clears the slot, so a later registration succeeds again.
    EventLogProvisioning.reset()
    EventLogProvisioning.use(module(First: EventLogProvisioning.Backend))
    EventLogProvisioning.reset()
  })
})
