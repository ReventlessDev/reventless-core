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
