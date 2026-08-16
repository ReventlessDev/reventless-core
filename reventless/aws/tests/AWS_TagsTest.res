open JestGlobals

// Guards the resource-attribution tag schema. A downstream inventory answers
// "which model component owns this resource, in what role, at what scope" purely
// from these keys, so the key set and its namespacing are load-bearing.
// See docs/plans/done/resource-attribution-tag-schema.md.

module Attribution = ReventlessCore.ResourceAttribution

// Pulumi.Input.make is %identity, so the tags value is the underlying dict.
external toDict: Pulumi.Input.t<dict<string>> => dict<string> = "%identity"

let tagsFor = (
  ~name,
  ~kind,
  ~role,
  ~scope: Attribution.Scope.t=Component,
  ~component=?,
  ~plugin=?,
  ~platform=?,
) =>
  AWS_Tags.make(~name, ~kind, ~role, ~scope, ~component?, ~plugin?, ~platform?)->toDict

describe("AWS_Tags — key set", () => {
  testSync("emits every reventless: fact exactly once, plus the bare Name", () => {
    let keys =
      tagsFor(
        ~name="ProductsQueryDb",
        ~kind=ReventlessCore.ComponentType.ReadModel,
        ~role=QueryDb,
        ~plugin="Catalog",
        ~platform="online-shop",
      )
      ->Dict.keysToArray
      ->Array.toSorted(String.compare)
    expect(keys)->toEqual([
      "Name",
      "reventless:component",
      "reventless:environment",
      "reventless:kind",
      "reventless:platform",
      "reventless:plugin",
      "reventless:role",
      "reventless:scope",
    ])
  })

  testSync("the dropped bare duplicates stay dropped", () => {
    // `Type` and `Plugin` were exact duplicates of reventless:kind / :plugin, and
    // `Environment` was a framework fact wearing an un-namespaced name. One
    // authoritative name per fact — `Name` is the sole bare key, because the AWS
    // console reads that literal spelling for its resource-name column.
    let tags = tagsFor(~name="Products", ~kind=ReventlessCore.ComponentType.ReadModel, ~role=QueryDb)
    expect(tags->Dict.get("Type"))->toEqual(None)
    expect(tags->Dict.get("Plugin"))->toEqual(None)
    expect(tags->Dict.get("Environment"))->toEqual(None)
    expect(tags->Dict.get("Name"))->toEqual(Some("Products"))
  })
})

describe("AWS_Tags — role and kind are independent facts", () => {
  testSync("one component kind spans several piece roles", () => {
    let kind = ReventlessCore.ComponentType.Aggregate
    let eventLog = tagsFor(~name="OrderEventLog", ~kind, ~role=EventLog)
    let commandTopic = tagsFor(~name="OrderCmdTopic", ~kind, ~role=CommandTopic)
    expect(eventLog->Dict.get("reventless:kind"))->toEqual(Some("Aggregate"))
    expect(commandTopic->Dict.get("reventless:kind"))->toEqual(Some("Aggregate"))
    expect(eventLog->Dict.get("reventless:role"))->toEqual(Some("EventLog"))
    expect(commandTopic->Dict.get("reventless:role"))->toEqual(Some("CommandTopic"))
  })

  testSync("one piece role spans several component kinds — the Lambda mis-tag", () => {
    // Regression guard for the defect this schema exists to fix: every runtime
    // Lambda used to report kind=role=CommandTopic regardless of what it ran.
    let aggregate = tagsFor(
      ~name="AllAggregatesCmdHandler",
      ~kind=ReventlessCore.ComponentType.Aggregate,
      ~role=Runtime,
    )
    let projection = tagsFor(
      ~name="ProductsProjection",
      ~kind=ReventlessCore.ComponentType.StateViewSlice,
      ~role=Runtime,
    )
    expect(aggregate->Dict.get("reventless:role"))->toEqual(Some("Runtime"))
    expect(projection->Dict.get("reventless:role"))->toEqual(Some("Runtime"))
    expect(aggregate->Dict.get("reventless:kind"))->toEqual(Some("Aggregate"))
    expect(projection->Dict.get("reventless:kind"))->toEqual(Some("StateViewSlice"))
    // …and neither reports the old hardcoded lie.
    expect(aggregate->Dict.get("reventless:kind") == Some("CommandTopic"))->toBe(false)
  })
})

describe("AWS_Tags — owner overrides the piece adapter's own kind", () => {
  // The piece adapters pass their OWN ComponentType as ~kind, which names the
  // piece and so collapses onto ~role. A QueryDb is instantiated by six different
  // component kinds, so without the owner a reader cannot tell a ReadModel's
  // table from a StateViewSlice's. See docs/plans/done/resource-attribution-owner-kind.md.
  let queryDbTagsFor = (~owner=?) =>
    AWS_Tags.make(
      ~name="ProductsQueryDb",
      ~kind=ReventlessCore.ComponentType.QueryDb,
      ~role=QueryDb,
      ~owner?,
    )->toDict

  testSync("without an owner, kind still names the piece", () => {
    let tags = queryDbTagsFor()
    expect(tags->Dict.get("reventless:kind"))->toEqual(Some("QueryDB"))
    expect(tags->Dict.get("reventless:role"))->toEqual(Some("QueryDb"))
  })

  testSync("two QueryDb tables under different owners differ in kind", () => {
    let readModel = queryDbTagsFor(
      ~owner={kind: ReventlessCore.ComponentType.ReadModel, name: "Products"},
    )
    let stateView = queryDbTagsFor(
      ~owner={kind: ReventlessCore.ComponentType.StateViewSlice, name: "ProductAvailability"},
    )
    expect(readModel->Dict.get("reventless:kind"))->toEqual(Some("ReadModel"))
    expect(stateView->Dict.get("reventless:kind"))->toEqual(Some("StateViewSlice"))
    // …while both still report the same piece role.
    expect(readModel->Dict.get("reventless:role"))->toEqual(Some("QueryDb"))
    expect(stateView->Dict.get("reventless:role"))->toEqual(Some("QueryDb"))
  })

  testSync("the owner also supplies the component stem, not the resource name", () => {
    let tags = queryDbTagsFor(
      ~owner={kind: ReventlessCore.ComponentType.ReadModel, name: "Products"},
    )
    expect(tags->Dict.get("Name"))->toEqual(Some("ProductsQueryDb"))
    expect(tags->Dict.get("reventless:component"))->toEqual(Some("Products"))
  })

  testSync("a Plugin-kinded owner attributes substrate to the plugin", () => {
    // A plugin IS a model element, so shared substrate is owned by it rather than
    // by nothing. The owner implies plugin scope even though the piece adapter
    // passed no ~scope, and it names the plugin.
    let tags =
      AWS_Tags.make(
        ~name="OrderingDcbEventTopic",
        ~kind=ReventlessCore.ComponentType.EventTopic,
        ~role=EventTopic,
        ~owner={kind: ReventlessCore.ComponentType.Plugin, name: "Ordering"},
      )->toDict
    expect(tags->Dict.get("reventless:kind"))->toEqual(Some("Plugin"))
    expect(tags->Dict.get("reventless:scope"))->toEqual(Some("plugin"))
    expect(tags->Dict.get("reventless:plugin"))->toEqual(Some("Ordering"))
    expect(tags->Dict.get("reventless:component"))->toEqual(Some(""))
    // …and the piece it plays is still legible.
    expect(tags->Dict.get("reventless:role"))->toEqual(Some("EventTopic"))
  })

  testSync("an owner does not leak a component onto plugin substrate", () => {
    let tags =
      AWS_Tags.make(
        ~name="OrderingDcbEventLog",
        ~kind=ReventlessCore.ComponentType.DcbEventLog,
        ~role=DcbEventLog,
        ~scope=Plugin,
        ~owner={kind: ReventlessCore.ComponentType.Aggregate, name: "Order"},
      )->toDict
    expect(tags->Dict.get("reventless:component"))->toEqual(Some(""))
  })
})

describe("AWS_Tags — scope", () => {
  testSync("component scope names the component, defaulting to the resource name", () => {
    let tags = tagsFor(~name="Products", ~kind=ReventlessCore.ComponentType.ReadModel, ~role=QueryDb)
    expect(tags->Dict.get("reventless:scope"))->toEqual(Some("component"))
    expect(tags->Dict.get("reventless:component"))->toEqual(Some("Products"))
  })

  testSync("an explicit component stem survives a suffixed resource name", () => {
    let tags = tagsFor(
      ~name="ProductsStateTopic",
      ~kind=ReventlessCore.ComponentType.ReadModel,
      ~role=StateTopic,
      ~component="Products",
    )
    expect(tags->Dict.get("Name"))->toEqual(Some("ProductsStateTopic"))
    expect(tags->Dict.get("reventless:component"))->toEqual(Some("Products"))
  })

  testSync("plugin substrate carries no component, but keeps its plugin", () => {
    let tags = tagsFor(
      ~name="OrderingDcbEventLog",
      ~kind=ReventlessCore.ComponentType.DcbEventLog,
      ~role=DcbEventLog,
      ~scope=Plugin,
      ~plugin="Ordering",
    )
    expect(tags->Dict.get("reventless:scope"))->toEqual(Some("plugin"))
    expect(tags->Dict.get("reventless:component"))->toEqual(Some(""))
    expect(tags->Dict.get("reventless:plugin"))->toEqual(Some("Ordering"))
  })

  testSync("platform substrate carries neither component nor plugin", () => {
    let tags = tagsFor(
      ~name="UIFragmentsLambda",
      ~kind=ReventlessCore.ComponentType.ReadModel,
      ~role=Runtime,
      ~scope=Platform,
      ~plugin="Ordering",
      ~platform="online-shop",
    )
    expect(tags->Dict.get("reventless:scope"))->toEqual(Some("platform"))
    expect(tags->Dict.get("reventless:component"))->toEqual(Some(""))
    expect(tags->Dict.get("reventless:plugin"))->toEqual(Some(""))
    expect(tags->Dict.get("reventless:platform"))->toEqual(Some("online-shop"))
  })
})

describe("AWS_Tags — plugin attribution", () => {
  testSync("falls back to the ambient plugin published by Plugin_Builder", () => {
    // Adapters sit far below the builder that knows the plugin name, so the
    // ambient context is how a DynamoDB table learns it belongs to Ordering.
    let previous = Attribution.enter(~platform="online-shop", ~plugin="Ordering")
    let tags = tagsFor(~name="OrderEventLog", ~kind=ReventlessCore.ComponentType.Aggregate, ~role=EventLog)
    Attribution.restore(previous)
    expect(tags->Dict.get("reventless:plugin"))->toEqual(Some("Ordering"))
    expect(tags->Dict.get("reventless:platform"))->toEqual(Some("online-shop"))
  })

  testSync("an explicit plugin beats the ambient one", () => {
    let previous = Attribution.enter(~platform="online-shop", ~plugin="Ordering")
    let tags = tagsFor(
      ~name="CatalogTable",
      ~kind=ReventlessCore.ComponentType.ReadModel,
      ~role=QueryDb,
      ~plugin="Catalog",
    )
    Attribution.restore(previous)
    expect(tags->Dict.get("reventless:plugin"))->toEqual(Some("Catalog"))
  })
})
