open JestGlobals

// The attribution vocabulary is the shared contract between the AWS tag renderer
// and the Kubernetes label renderer. These guard the wire spellings (which land
// in deployed resource metadata and in downstream inventories) and the ambient
// context's save/restore discipline, which is what keeps a plugin's resources
// from being attributed to whichever plugin was constructed before it.

module Attribution = ResourceAttribution

describe("ResourceAttribution.Scope — wire spellings", () => {
  testSync("scopes render lower-case", () => {
    expect(
      [Attribution.Scope.Component, Plugin, Platform]->Array.map(Attribution.Scope.toString),
    )->toEqual(["component", "plugin", "platform"])
  })
})

describe("ResourceAttribution.Role — wire spellings", () => {
  testSync("piece roles render as their constructor name", () => {
    expect(
      [Attribution.Role.EventLog, QueryDb, Runtime, DeadLetter]->Array.map(
        Attribution.Role.toString,
      ),
    )->toEqual(["EventLog", "QueryDb", "Runtime", "DeadLetter"])
  })

  testSync("Other carries the caller's name verbatim", () => {
    expect(Attribution.Role.Other("ChangeFeed")->Attribution.Role.toString)->toBe("ChangeFeed")
  })

  testSync("platform-level things are Platform, not Core", () => {
    // `Core` predates the platform/plugin split and names nothing the framework
    // builds; it also reads as the built-in core PLUGIN, which is a different
    // thing. Platform substrate is attributed to `Platform`, matching
    // `reventless:platform` and `Scope.Platform`.
    expect(ComponentType.Platform->ComponentType.toString)->toBe("Platform")
    expect(ComponentType.ofString("Platform"))->toEqual(Some(ComponentType.Platform))
  })

  testSync("a role is NOT a component kind — Runtime has no ComponentType twin", () => {
    // The whole point of splitting role from kind: `Runtime` is a deployment
    // piece, not something the domain model can be. If this ever resolves, the
    // two vocabularies have started to merge again.
    expect(ComponentType.ofString("Runtime"))->toEqual(None)
  })
})

describe("ResourceAttribution — ambient plugin context", () => {
  testSync("outside any plugin construct, nothing is attributed", () => {
    expect(Attribution.current.contents.plugin)->toEqual(None)
    expect(Attribution.current.contents.platform)->toEqual(None)
  })

  testSync("enter publishes the plugin and platform under construction", () => {
    let previous = Attribution.enter(~platform="online-shop", ~plugin="Ordering")
    expect(Attribution.current.contents.plugin)->toEqual(Some("Ordering"))
    expect(Attribution.current.contents.platform)->toEqual(Some("online-shop"))
    Attribution.restore(previous)
  })

  testSync("restore unwinds to the previous context, so plugins don't leak", () => {
    let outer = Attribution.enter(~platform="online-shop", ~plugin="Catalog")
    let inner = Attribution.enter(~platform="online-shop", ~plugin="Ordering")
    Attribution.restore(inner)
    expect(Attribution.current.contents.plugin)->toEqual(Some("Catalog"))
    Attribution.restore(outer)
    expect(Attribution.current.contents.plugin)->toEqual(None)
  })
})

// The bracket only covers what runs synchronously inside a builder's construct.
// Builders defer part of their work into a `Pulumi.Output.apply`, which runs
// after `restore` has emptied the context — so a resource created there is
// attributed to nobody. These pin the mechanism that carries the context across
// that gap. Each empties the context first, which is exactly the state a
// deferred callback finds itself in.

describe("ResourceAttribution — carrying the context into deferred work", () => {
  testSync("a deferred callback runs under the context it was wrapped in", () => {
    let previous = Attribution.enter(~platform="online-shop", ~plugin="Catalog")
    let observed = ref(None)
    let finish = Attribution.deferred(() => observed := Attribution.current.contents.plugin)
    Attribution.restore(previous)

    // Construct has returned; nothing is attributed. This is when the apply fires.
    expect(Attribution.current.contents.plugin)->toEqual(None)
    finish()
    expect(observed.contents)->toEqual(Some("Catalog"))
  })

  testSync("it puts the context back, so the next callback is not attributed to it", () => {
    let previous = Attribution.enter(~platform="online-shop", ~plugin="Catalog")
    let finish = Attribution.deferred(() => ())
    Attribution.restore(previous)

    finish()
    expect(Attribution.current.contents.plugin)->toEqual(None)
  })

  // The registries these callbacks land in are module-level and shared, so one
  // apply runs several plugins' finish functions back to back. Attributing them
  // all to whichever ran first is the failure this guards.
  testSync("two plugins deferred from one apply are each attributed to themselves", () => {
    let outer = Attribution.enter(~platform="online-shop", ~plugin="Catalog")
    let catalogSaw = ref(None)
    let catalogFinish = Attribution.deferred(() =>
      catalogSaw := Attribution.current.contents.plugin
    )
    Attribution.restore(outer)

    let previous = Attribution.enter(~platform="online-shop", ~plugin="Ordering")
    let orderingSaw = ref(None)
    let orderingFinish = Attribution.deferred(() =>
      orderingSaw := Attribution.current.contents.plugin
    )
    Attribution.restore(previous)

    catalogFinish()
    orderingFinish()
    expect((catalogSaw.contents, orderingSaw.contents))->toEqual((
      Some("Catalog"),
      Some("Ordering"),
    ))
  })

  testSync("a throwing callback still puts the context back", () => {
    let previous = Attribution.enter(~platform="online-shop", ~plugin="Catalog")
    let finish: unit => unit = Attribution.deferred(() =>
      JsError.throwWithMessage("finish blew up")
    )
    Attribution.restore(previous)

    let threw = try {
      finish()
      false
    } catch {
    | _ => true
    }
    expect(threw)->toBe(true)
    expect(Attribution.current.contents.plugin)->toEqual(None)
  })

  testSync("within re-enters a captured context for a callback that takes arguments", () => {
    let previous = Attribution.enter(~platform="online-shop", ~plugin="Catalog")
    let captured = Attribution.current.contents
    Attribution.restore(previous)

    let observed = captured->Attribution.within(() => Attribution.current.contents.plugin)
    expect(observed)->toEqual(Some("Catalog"))
    expect(Attribution.current.contents.plugin)->toEqual(None)
  })

  testSync("enterCaptured can express the empty context, which enter cannot", () => {
    let previous = Attribution.enter(~platform="online-shop", ~plugin="Catalog")
    let restoredToEmpty = Attribution.enterCaptured({platform: None, plugin: None})
    expect(Attribution.current.contents.plugin)->toEqual(None)
    expect(restoredToEmpty.plugin)->toEqual(Some("Catalog"))
    Attribution.restore(previous)
  })
})

// The combinator being right is not the same as it being wired in. This one
// exercises the production choke point: a task side-effect handler registered
// during construct, then run the way `finishTasks` runs it — from an apply,
// with nothing attributed.
describe("Builder_Helpers.registerTaskSideEffectHandler — attribution survives the deferral", () => {
  testSync("the registered finish sees the plugin that registered it", () => {
    let before = Builder_Helpers.taskSideEffectFinishFns->Array.length
    let observed = ref(None)

    let previous = Attribution.enter(~platform="online-shop", ~plugin="Catalog")
    Builder_Helpers.registerTaskSideEffectHandler(
      ~gate=Pulumi.Output.make(),
      ~finish=() => observed := Attribution.current.contents.plugin,
    )
    Attribution.restore(previous)

    switch Builder_Helpers.taskSideEffectFinishFns->Array.get(before) {
    | Some(finish) => finish()
    | None => JsError.throwWithMessage("handler was not registered")
    }
    expect(observed.contents)->toEqual(Some("Catalog"))
  })
})
