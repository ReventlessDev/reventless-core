// Unit tests for DomainGraph.build — Event-Modeling node/edge assembly over
// synthetic pluginStructures. Pure (no reventless-local import), so it runs under
// Jest. The real end-to-end shape over the example plugins is exercised by the
// LocalHost integration; here hand-built fixtures pin the edge wiring.

open JestGlobals

let command = (~name, ~mutationField): Reventless.Plugin.commandDef => {
  name,
  schema: "",
  level: Instance,
  aggregateIdField: None,
  mutationField,
  references: [],
  allowedStates: None,
}

let writable = (~name, ~commands=[], ~produces=[], ~consumes=[], ~linkedViews=[]): Reventless.Plugin.writableDef => {
  name,
  commands,
  producedEventTypes: produces,
  consumedEventTypes: consumes,
  linkedViews,
  consistencyRead: None,
}

let queryable = (~name, ~consumes=[], ~visibility=None): Reventless.Plugin.queryableDef => {
  name,
  queryField: "",
  schema: "",
  consumedEventTypes: consumes,
  linkedWriteSide: [],
  labelField: "id",
  searchableFields: [],
  statusField: None,
  visibility,
}

let automation = (~name, ~consumes=[]): Reventless.Plugin.automationSliceDef => {
  name,
  consumedEventTypes: consumes,
  producedCommandTypes: [],
  targetName: "",
}

let structure = (
  ~aggregates=[],
  ~readModels=[],
  ~stateViewSlices=[],
  ~stateChangeSlices=[],
  ~automationSlices=[],
  ~extensionPoints=[],
): Reventless.Plugin.pluginStructure => {
  readModels,
  stateViewSlices,
  stateChangeSlices,
  aggregates,
  automationSlices,
  outboundTranslationSlices: [],
  inboundTranslationSlices: [],
  extensions: [],
  extensionPoints: Some(extensionPoints),
}

let hasEdge = (g: DomainGraph.graph, from, to, kind) =>
  g.edges->Array.some(e => e.from == from && e.to == to && e.kind == kind)
let nodeKind = (g: DomainGraph.graph, id) =>
  g.nodes->Array.find(n => n.id == id)->Option.map(n => n.kind)

describe("DomainGraph.build", () => {
  testPromise("Command → Aggregate → Event → ReadModel (DCB consumedEventTypes)", async () => {
    let shop = structure(
      ~aggregates=[
        writable(
          ~name="Order",
          ~commands=[command(~name="Place", ~mutationField="Shop_Order_Place")],
          ~produces=["Shop.Placed"],
        ),
      ],
      ~stateViewSlices=[queryable(~name="OrderView", ~consumes=["Shop.Placed"])],
    )
    let g = DomainGraph.build(~structures=[("Shop", shop)], ~edges=[])
    expect(nodeKind(g, "Shop_Order_Place"))->toEqual(Some("Command"))
    expect(nodeKind(g, "Shop:Order"))->toEqual(Some("Aggregate"))
    expect(nodeKind(g, "Shop.Placed"))->toEqual(Some("Event"))
    expect(nodeKind(g, "Shop:OrderView"))->toEqual(Some("StateViewSlice"))
    expect(hasEdge(g, "Shop_Order_Place", "Shop:Order", "handles"))->toBe(true)
    expect(hasEdge(g, "Shop:Order", "Shop.Placed", "emits"))->toBe(true)
    expect(hasEdge(g, "Shop.Placed", "Shop:OrderView", "projects"))->toBe(true)
  })

  testPromise("an Internal StateViewSlice still gets a node + projects edge (dev graph shows it)", async () => {
    // Internal components are hidden from the deployed AutoUI but carried in pluginStructure
    // so the developer-facing domain graph can render them — see Plugin_Structure.res /
    // Visibility.res. Mirrors the AvailableProducts case (a consume-only Internal slice).
    let shop = structure(
      ~aggregates=[writable(~name="Order", ~produces=["Shop.Placed"])],
      ~stateViewSlices=[
        queryable(~name="AvailableView", ~consumes=["Shop.Placed"], ~visibility=Some("Internal")),
      ],
    )
    let g = DomainGraph.build(~structures=[("Shop", shop)], ~edges=[])
    expect(nodeKind(g, "Shop:AvailableView"))->toEqual(Some("StateViewSlice"))
    expect(hasEdge(g, "Shop.Placed", "Shop:AvailableView", "projects"))->toBe(true)
  })

  testPromise("classic linkedViews draws each produced event into the linked read model", async () => {
    let shop = structure(
      ~aggregates=[writable(~name="Order", ~produces=["Shop.Placed", "Shop.Shipped"], ~linkedViews=["Orders"])],
      ~readModels=[queryable(~name="Orders")],
    )
    let g = DomainGraph.build(~structures=[("Shop", shop)], ~edges=[])
    expect(hasEdge(g, "Shop.Placed", "Shop:Orders", "projects"))->toBe(true)
    expect(hasEdge(g, "Shop.Shipped", "Shop:Orders", "projects"))->toBe(true)
  })

  testPromise("automation slices are triggered by their consumed events", async () => {
    let shop = structure(
      ~aggregates=[writable(~name="Order", ~produces=["Shop.Placed"])],
      ~automationSlices=[automation(~name="Notify", ~consumes=["Shop.Placed"])],
    )
    let g = DomainGraph.build(~structures=[("Shop", shop)], ~edges=[])
    expect(nodeKind(g, "Shop:Notify"))->toEqual(Some("AutomationSlice"))
    expect(hasEdge(g, "Shop.Placed", "Shop:Notify", "triggers"))->toBe(true)
  })

  testPromise("an event produced by two write-sides is one node with two emit edges", async () => {
    let shop = structure(
      ~aggregates=[
        writable(~name="A", ~produces=["Shop.Touched"]),
        writable(~name="B", ~produces=["Shop.Touched"]),
      ],
    )
    let g = DomainGraph.build(~structures=[("Shop", shop)], ~edges=[])
    expect(g.nodes->Array.filter(n => n.id == "Shop.Touched")->Array.length)->toBe(1)
    expect(hasEdge(g, "Shop:A", "Shop.Touched", "emits"))->toBe(true)
    expect(hasEdge(g, "Shop:B", "Shop.Touched", "emits"))->toBe(true)
  })

  testPromise("non-Extension computeEdges become graph edges with synthesized endpoints", async () => {
    let edge: Reventless.Plugin.graphEdge = {
      source: {pluginName: "Shop", componentName: "Order", kind: "Aggregate"},
      target: {pluginName: "Analytics", componentName: "OrderStats", kind: "StateViewSlice"},
      mechanism: "EventTypeMatch",
      viaEvents: ["Shop.Placed"],
      implicit: false,
    }
    let g = DomainGraph.build(~structures=[], ~edges=[edge])
    expect(hasEdge(g, "Shop:Order", "Analytics:OrderStats", "EventTypeMatch"))->toBe(true)
  })

  testPromise("an extension renders the cross-plugin event flow EP→event→Extension→delegate", async () => {
    // Catalog's ProductDemand handles the "Ordering.Orders" extension point's events.
    let extension: Reventless.Plugin.extensionDef = {
      name: "Ordering.Orders",
      delegateNames: ["ProductDemand"],
      eventTypes: ["Ordering.Orders.ItemOrdered"],
      commandTypes: [],
    }
    let catalog = {
      ...structure(~aggregates=[writable(~name="ProductDemand", ~produces=["Catalog.Recorded"])]),
      extensions: [extension],
    }
    let g = DomainGraph.build(~structures=[("Catalog", catalog)], ~edges=[])
    // EP (owned by Ordering) publishes its event; the Catalog extension consumes it…
    expect(nodeKind(g, "Ordering:ep:Ordering.Orders"))->toEqual(Some("ExtensionPoint"))
    expect(hasEdge(g, "Ordering:ep:Ordering.Orders", "Ordering.Orders.ItemOrdered", "publishes"))->toBe(true)
    expect(hasEdge(g, "Ordering.Orders.ItemOrdered", "Catalog:ext:Ordering.Orders", "consumes"))->toBe(true)
    // …and delegates to ProductDemand.
    expect(hasEdge(g, "Catalog:ext:Ordering.Orders", "Catalog:ProductDemand", "delegatesTo"))->toBe(true)
    // The protocol event is top-level (empty plugin) so it sits between the boxes…
    let protoEvent =
      g.nodes->Array.find(n => n.id == "Ordering.Orders.ItemOrdered")->Option.getOrThrow
    expect(protoEvent.plugin)->toBe("")
    // …and the extension is named by its EP + consuming plugin.
    let ext = g.nodes->Array.find(n => n.id == "Catalog:ext:Ordering.Orders")->Option.getOrThrow
    expect(ext.label)->toBe("Ordering.Orders.Catalog")
  })

  testPromise("an owned extension point is fed by the producers of its source events", async () => {
    // Catalog owns the Catalog.Products EP; its source events are the internal
    // Catalog events produced by AddProduct, so the producing write-side feeds
    // the EP through those events.
    let ep: Reventless.Plugin.extensionPointDef = {
      name: "Catalog.Products",
      delegateNames: ["CatalogDcbEventLog"],
      sourceEventTypes: ["Catalog.ProductAdded"],
    }
    let catalog = structure(
      ~stateChangeSlices=[
        writable(
          ~name="AddProduct",
          ~commands=[command(~name="AddProduct", ~mutationField="Catalog_AddProduct")],
          ~produces=["Catalog.ProductAdded"],
        ),
      ],
      ~extensionPoints=[ep],
    )
    let g = DomainGraph.build(~structures=[("Catalog", catalog)], ~edges=[])
    expect(nodeKind(g, "Catalog:ep:Catalog.Products"))->toEqual(Some("ExtensionPoint"))
    // The producing write-side emits the source event…
    expect(hasEdge(g, "Catalog:AddProduct", "Catalog.ProductAdded", "emits"))->toBe(true)
    // …which feeds the extension point — so EP focus reaches the producer.
    expect(hasEdge(g, "Catalog.ProductAdded", "Catalog:ep:Catalog.Products", "feeds"))->toBe(true)
  })
})
