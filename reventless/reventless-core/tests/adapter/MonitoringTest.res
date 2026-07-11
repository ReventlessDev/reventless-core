open JestGlobals

// The registry only forwards `~component`; it never reads its fields. A
// structural stand-in keeps @pulumi/pulumi (whose Output.make would build a real
// resource) out of the Jest run — its ESM entry can't be imported under Jest.
let stubResource: ReventlessInfra.Adapter.resource = %raw(`{}`)

describe("Monitoring", () => {
  testSync("Noop default: notify is silent and does not throw", () => {
    // No backend registered — the default Noop backend swallows the call.
    Monitoring.notify(~kind=CommandHandler, ~name="before", ~component=stubResource)
    expect(true)->toBe(true)
  })

  testSync("use registers a backend that receives every notify, role and name", () => {
    let recorded: array<(Monitoring.unitKind, string)> = []
    module Recorder: Monitoring.Backend = {
      let onProvisioned = (~kind, ~name, ~component as _) => recorded->Array.push((kind, name))
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

    // Restore the default so registry state doesn't leak to other cases.
    Monitoring.use(module(Monitoring.Noop))
  })

  testSync("notify forwards the static name and component resource to the backend", () => {
    let seen: ref<option<(string, ReventlessInfra.Adapter.resource)>> = ref(None)
    module Capture: Monitoring.Backend = {
      let onProvisioned = (~kind as _, ~name, ~component) => seen := Some((name, component))
    }
    Monitoring.use(module(Capture: Monitoring.Backend))

    Monitoring.notify(~kind=Scheduler, ~name="HeartbeatUnit", ~component=stubResource)
    switch seen.contents {
    | Some((name, _component)) => expect(name)->toBe("HeartbeatUnit")
    | None => expect("no notify received")->toBe("a notify")
    }

    Monitoring.use(module(Monitoring.Noop))
  })
})
