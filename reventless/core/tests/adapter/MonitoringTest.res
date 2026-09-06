open JestGlobals

// The registry only forwards `~component`; it never reads its fields. A
// structural stand-in keeps @pulumi/pulumi (whose Output.make would build a real
// resource) out of the Jest run — its ESM entry can't be imported under Jest.
let stubResource: ReventlessInfra.Adapter.resource = %raw(`{}`)

describe("Monitoring", () => {
  testSync("no backend registered: notify is silent and does not throw", () => {
    Monitoring.notify(~kind=CommandHandler, ~name="before", ~component=stubResource)
    expect(true)->toBe(true)
    Monitoring.reset()
  })

  // The case the dead-letter sink is: a module that provisions at import time announces
  // itself before any statement of the deploy program has run, so it is *always* earlier
  // than the `use` call. Dropping those announcements made that one unit unmonitorable no
  // matter what a backend did.
  testSync("an announcement made before any backend is registered reaches the first one", () => {
    let recorded: array<(Monitoring.unitKind, string, option<string>)> = []
    module Late: Monitoring.Backend = {
      let onProvisioned = (~kind, ~name, ~component as _, ~plugin, ~platform as _, ~logLocator as _) =>
        recorded->Array.push((kind, name, plugin))
    }

    // Provisioned at import time, inside a construct scope that is long gone by the time
    // anyone registers — so the owner must be captured now, not at delivery.
    let prev = ResourceAttribution.enter(~platform="online-shop", ~plugin="Ordering")
    Monitoring.notify(~kind=DeadLetterSink, ~name="DeadLetterQueue", ~component=stubResource)
    ResourceAttribution.restore(prev)
    Monitoring.notify(~kind=Scheduler, ~name="Heartbeat", ~component=stubResource)

    expect(recorded)->toEqual([])

    Monitoring.use(module(Late: Monitoring.Backend))

    expect(recorded)->toEqual([
      (Monitoring.DeadLetterSink, "DeadLetterQueue", Some("Ordering")),
      (Monitoring.Scheduler, "Heartbeat", None),
    ])

    // Drained: a second registration does not receive them again.
    let second: array<string> = []
    module Other: Monitoring.Backend = {
      let onProvisioned = (~kind as _, ~name, ~component as _, ~plugin as _, ~platform as _, ~logLocator as _) =>
        second->Array.push(name)
    }
    Monitoring.use(module(Other: Monitoring.Backend))
    expect(second)->toEqual([])

    Monitoring.reset()
  })

  testSync("use registers a backend that receives every notify, role and name", () => {
    let recorded: array<(Monitoring.unitKind, string)> = []
    module Recorder: Monitoring.Backend = {
      let onProvisioned = (~kind, ~name, ~component as _, ~plugin as _, ~platform as _, ~logLocator as _) =>
        recorded->Array.push((kind, name))
    }
    Monitoring.use(module(Recorder: Monitoring.Backend))

    Monitoring.notify(~kind=CommandHandler, ~name="AllAggregatesCmdHandler", ~component=stubResource)
    Monitoring.notify(~kind=Projection, ~name="AllStateViewSlices", ~component=stubResource)
    Monitoring.notify(~kind=DeadLetterSink, ~name="DeadLetterQueue", ~component=stubResource)
    Monitoring.notify(~kind=Other("Counter"), ~name="ProductCounter", ~component=stubResource)

    expect(recorded)->toEqual([
      (Monitoring.CommandHandler, "AllAggregatesCmdHandler"),
      (Monitoring.Projection, "AllStateViewSlices"),
      (Monitoring.DeadLetterSink, "DeadLetterQueue"),
      (Monitoring.Other("Counter"), "ProductCounter"),
    ])

    // Restore the initial state so registry and buffer don't leak to other cases.
    Monitoring.reset()
  })

  testSync("notify forwards the static name and component resource to the backend", () => {
    let seen: ref<option<(string, ReventlessInfra.Adapter.resource)>> = ref(None)
    module Capture: Monitoring.Backend = {
      let onProvisioned = (~kind as _, ~name, ~component, ~plugin as _, ~platform as _, ~logLocator as _) =>
        seen := Some((name, component))
    }
    Monitoring.use(module(Capture: Monitoring.Backend))

    Monitoring.notify(~kind=Scheduler, ~name="HeartbeatUnit", ~component=stubResource)
    switch seen.contents {
    | Some((name, _component)) => expect(name)->toBe("HeartbeatUnit")
    | None => expect("no notify received")->toBe("a notify")
    }

    Monitoring.reset()
  })

  testSync("notify delivers the ambient plugin/platform inside a construct scope, None outside", () => {
    let seen: array<(option<string>, option<string>)> = []
    module OwnerCapture: Monitoring.Backend = {
      let onProvisioned = (~kind as _, ~name as _, ~component as _, ~plugin, ~platform, ~logLocator as _) =>
        seen->Array.push((plugin, platform))
    }
    Monitoring.use(module(OwnerCapture: Monitoring.Backend))

    // Outside any plugin construct: platform substrate → both None.
    Monitoring.notify(~kind=CommandHandler, ~name="ApiRouter", ~component=stubResource)

    // Inside a construct scope (what Plugin_Builder.construct establishes): both delivered.
    let prev = ResourceAttribution.enter(~platform="online-shop", ~plugin="Ordering")
    Monitoring.notify(~kind=CommandHandler, ~name="AllAggregatesCmdHandler", ~component=stubResource)
    ResourceAttribution.restore(prev)

    // After restore: back to None.
    Monitoring.notify(~kind=Projection, ~name="AllStateViewSlices", ~component=stubResource)

    expect(seen)->toEqual([
      (None, None),
      (Some("Ordering"), Some("online-shop")),
      (None, None),
    ])

    Monitoring.reset()
  })

  // Unlike the owner, the locator is not ambient — the seam only forwards what the provisioning
  // site passed. A site with nothing to say omits it, and the backend must see that as "this unit
  // has no logs of its own" rather than receiving a fabricated address.
  testSync("notify forwards the log locator when given one, None when omitted", () => {
    // The registry only forwards the locator; it never resolves it. A structural stand-in keeps
    // @pulumi/pulumi out of the Jest run, exactly as `stubResource` does.
    let stubLocator: Pulumi.Output.t<string> = %raw(`{}`)
    let seen: array<bool> = []
    module LocatorCapture: Monitoring.Backend = {
      let onProvisioned = (~kind as _, ~name as _, ~component as _, ~plugin as _, ~platform as _, ~logLocator) =>
        seen->Array.push(logLocator->Option.isSome)
    }
    Monitoring.use(module(LocatorCapture: Monitoring.Backend))

    Monitoring.notify(
      ~kind=CommandHandler,
      ~name="AllAggregatesCmdHandler",
      ~component=stubResource,
      ~logLocator=stubLocator,
    )
    Monitoring.notify(~kind=DeadLetterSink, ~name="DeadLetterQueue", ~component=stubResource)

    expect(seen)->toEqual([true, false])

    Monitoring.reset()
  })
})
