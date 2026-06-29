// Unit tests for DomainGraph.build — Event-Modeling node/edge assembly over
// synthetic pluginStructures. Pure (no reventless-local import), so it runs under
// Jest. The real end-to-end shape over the example plugins is exercised by the
// LocalHost integration; here hand-built fixtures pin the edge wiring.

open JestGlobals

let command = (~name, ~mutationField, ~apiExposed=None): Reventless.Plugin.commandDef => {
  name,
  schema: "",
  level: Instance,
  aggregateIdField: None,
  mutationField,
  references: [],
  allowedStates: None,
  apiExposed,
}

let evt = (~name): Reventless.Plugin.eventDef => {name, schema: "", references: []}

let writable = (~name, ~commands=[], ~produces=[], ~consumes=[], ~linkedViews=[], ~events=[]): Reventless.Plugin.writableDef => {
  name,
  commands,
  producedEventTypes: produces,
  consumedEventTypes: consumes,
  linkedViews,
  consistencyRead: None,
  events,
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

let automation = (~name, ~consumes=[], ~produces=[], ~target=""): Reventless.Plugin.automationSliceDef => {
  name,
  consumedEventTypes: consumes,
  producedCommandTypes: produces,
  targetName: target,
}

let inbound = (~name, ~produces=[], ~target="", ~ext=None): Reventless.Plugin.inboundTranslationSliceDef => {
  name,
  commandTypes: produces,
  targetName: target,
  externalSystem: ext,
}

let outbound = (~name, ~consumes=[], ~produces=[], ~target=None, ~ext=None): Reventless.Plugin.outboundTranslationSliceDef => {
  name,
  consumedEventTypes: consumes,
  inboundCommandTypes: produces,
  targetName: target,
  externalSystem: ext,
}

let structure = (
  ~aggregates=[],
  ~readModels=[],
  ~stateViewSlices=[],
  ~stateChangeSlices=[],
  ~automationSlices=[],
  ~outboundTranslationSlices=[],
  ~inboundTranslationSlices=[],
  ~extensionPoints=[],
): Reventless.Plugin.pluginStructure => {
  readModels,
  stateViewSlices,
  stateChangeSlices,
  aggregates,
  automationSlices,
  outboundTranslationSlices,
  inboundTranslationSlices,
  extensions: [],
  extensionPoints: Some(extensionPoints),
}

let hasEdge = (g: DomainGraph.graph, from, to, kind) =>
  g.edges->Array.some(e => e.from == from && e.to == to && e.kind == kind)
let edgeLabel = (g: DomainGraph.graph, from, to, kind) =>
  g.edges->Array.find(e => e.from == from && e.to == to && e.kind == kind)->Option.flatMap(e => e.label)
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
    let g = DomainGraph.build(~structures=[("Shop", shop)])
    expect(nodeKind(g, "Shop_Order_Place"))->toEqual(Some("Command"))
    expect(nodeKind(g, "Shop:Order"))->toEqual(Some("Aggregate"))
    expect(nodeKind(g, "Shop.Placed"))->toEqual(Some("Event"))
    expect(nodeKind(g, "Shop:OrderView"))->toEqual(Some("StateViewSlice"))
    expect(hasEdge(g, "Shop_Order_Place", "Shop:Order", "handles"))->toBe(true)
    expect(hasEdge(g, "Shop:Order", "Shop.Placed", "emits"))->toBe(true)
    expect(hasEdge(g, "Shop.Placed", "Shop:OrderView", "projects"))->toBe(true)
  })

  testPromise("payload-less events (in `events`, not producedEventTypes) still get an emitted node", async () => {
    // Mirrors an aggregate whose `| Archived` variant is payload-less: DCB drops it from
    // producedEventTypes, but the full `events` list carries it so the graph draws the
    // emitted (orphan) event node. The payloaded `Added` appears in both lists and dedups.
    let shop = structure(
      ~aggregates=[
        writable(
          ~name="Category",
          ~produces=["Catalog.Added"],
          ~events=[evt(~name="Added"), evt(~name="Archived")],
        ),
      ],
    )
    let g = DomainGraph.build(~structures=[("Catalog", shop)])
    expect(nodeKind(g, "Catalog.Added"))->toEqual(Some("Event"))
    expect(nodeKind(g, "Catalog.Archived"))->toEqual(Some("Event"))
    expect(hasEdge(g, "Catalog:Category", "Catalog.Added", "emits"))->toBe(true)
    expect(hasEdge(g, "Catalog:Category", "Catalog.Archived", "emits"))->toBe(true)
  })

  testPromise("a payload-less event also projects into the aggregate's linked view", async () => {
    // Classic aggregate → linked view: the projection drew only producedEventTypes, which
    // drops payload-less events — so a bare `| Archived` emitted but never reached the view.
    // It must now project too (matching the emit), just like the payloaded `Added`.
    let shop = structure(
      ~aggregates=[
        writable(
          ~name="Category",
          ~produces=["Catalog.Added"],
          ~events=[evt(~name="Added"), evt(~name="Archived")],
          ~linkedViews=["Categories"],
        ),
      ],
    )
    let g = DomainGraph.build(~structures=[("Catalog", shop)])
    expect(hasEdge(g, "Catalog.Added", "Catalog:Categories", "projects"))->toBe(true)
    expect(hasEdge(g, "Catalog.Archived", "Catalog:Categories", "projects"))->toBe(true)
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
    let g = DomainGraph.build(~structures=[("Shop", shop)])
    expect(nodeKind(g, "Shop:AvailableView"))->toEqual(Some("StateViewSlice"))
    expect(hasEdge(g, "Shop.Placed", "Shop:AvailableView", "projects"))->toBe(true)
  })

  testPromise("classic linkedViews draws each produced event into the linked read model", async () => {
    let shop = structure(
      ~aggregates=[writable(~name="Order", ~produces=["Shop.Placed", "Shop.Shipped"], ~linkedViews=["Orders"])],
      ~readModels=[queryable(~name="Orders")],
    )
    let g = DomainGraph.build(~structures=[("Shop", shop)])
    expect(hasEdge(g, "Shop.Placed", "Shop:Orders", "projects"))->toBe(true)
    expect(hasEdge(g, "Shop.Shipped", "Shop:Orders", "projects"))->toBe(true)
  })

  testPromise("automation slices are triggered by their consumed events", async () => {
    let shop = structure(
      ~aggregates=[writable(~name="Order", ~produces=["Shop.Placed"])],
      ~automationSlices=[automation(~name="Notify", ~consumes=["Shop.Placed"])],
    )
    let g = DomainGraph.build(~structures=[("Shop", shop)])
    expect(nodeKind(g, "Shop:Notify"))->toEqual(Some("AutomationSlice"))
    expect(hasEdge(g, "Shop.Placed", "Shop:Notify", "triggers"))->toBe(true)
  })

  testPromise("an automation routes to the specific command it raises on its target", async () => {
    // AutoShipOrder reacts to OrderPlaced and raises a ShipOrder command on the Ship
    // write-side. The produce side is drawn slice → command "delegatesTo" (unified with
    // Command → write-side "handles"); only the named command is linked, not Place too.
    let shop = structure(
      ~stateChangeSlices=[
        writable(
          ~name="Ship",
          ~commands=[
            command(~name="ShipOrder", ~mutationField="Shop_Ship_ShipOrder"),
            command(~name="Place", ~mutationField="Shop_Ship_Place"),
          ],
          ~produces=["Shop.Shipped"],
        ),
      ],
      ~automationSlices=[
        automation(~name="AutoShip", ~consumes=["Shop.Placed"], ~produces=["AutoShip.ShipOrder"], ~target="Ship"),
      ],
    )
    let g = DomainGraph.build(~structures=[("Shop", shop)])
    expect(hasEdge(g, "Shop:AutoShip", "Shop_Ship_ShipOrder", "delegatesTo"))->toBe(true)
    // Matched by name — the target's other command is not linked.
    expect(hasEdge(g, "Shop:AutoShip", "Shop_Ship_Place", "delegatesTo"))->toBe(false)
  })

  testPromise("an inbound translation routes to the command it raises on its target", async () => {
    // ImportProduct (external input → command) was a sink before; it now links to the
    // Add command on its target write-side.
    let shop = structure(
      ~stateChangeSlices=[
        writable(~name="Product", ~commands=[command(~name="Add", ~mutationField="Shop_Product_Add")]),
      ],
      ~inboundTranslationSlices=[
        inbound(~name="ImportProduct", ~produces=["ImportProduct.Add"], ~target="Product"),
      ],
    )
    let g = DomainGraph.build(~structures=[("Shop", shop)])
    expect(nodeKind(g, "Shop:ImportProduct"))->toEqual(Some("InboundTranslationSlice"))
    expect(hasEdge(g, "Shop:ImportProduct", "Shop_Product_Add", "delegatesTo"))->toBe(true)
  })

  testPromise("an outbound translation with a target routes to the command it raises", async () => {
    let shop = structure(
      ~stateChangeSlices=[
        writable(~name="Product", ~commands=[command(~name="Sync", ~mutationField="Shop_Product_Sync")]),
      ],
      ~outboundTranslationSlices=[
        outbound(~name="ExportProduct", ~consumes=["Shop.Added"], ~produces=["ExportProduct.Sync"], ~target=Some("Product")),
      ],
    )
    let g = DomainGraph.build(~structures=[("Shop", shop)])
    expect(hasEdge(g, "Shop:ExportProduct", "Shop_Product_Sync", "delegatesTo"))->toBe(true)
  })

  testPromise("an inbound translation naming an external system draws a box feeding it", async () => {
    let shop = structure(
      ~inboundTranslationSlices=[
        inbound(~name="ImportProduct", ~produces=["ImportProduct.Add"], ~target="Product", ~ext=Some("SupplierFeed")),
      ],
    )
    let g = DomainGraph.build(~structures=[("Shop", shop)])
    // External box: drawn OUTSIDE the plugin (plugin: "") with a stable "ext:<name>" id.
    expect(nodeKind(g, "ext:SupplierFeed"))->toEqual(Some("ExternalSystem"))
    expect(g.nodes->Array.find(n => n.id == "ext:SupplierFeed")->Option.map(n => n.plugin))->toEqual(Some(""))
    // Inbound direction: external → slice (unlabelled — the arrowhead carries the meaning).
    expect(hasEdge(g, "ext:SupplierFeed", "Shop:ImportProduct", "translatesIn"))->toBe(true)
    expect(edgeLabel(g, "ext:SupplierFeed", "Shop:ImportProduct", "translatesIn"))->toEqual(None)
  })

  testPromise("an outbound translation naming an external system feeds the box", async () => {
    let shop = structure(
      ~outboundTranslationSlices=[
        outbound(~name="SendEmail", ~consumes=["Shop.Placed"], ~target=None, ~ext=Some("EmailService")),
      ],
    )
    let g = DomainGraph.build(~structures=[("Shop", shop)])
    expect(nodeKind(g, "ext:EmailService"))->toEqual(Some("ExternalSystem"))
    // Outbound direction: slice → external (unlabelled — the arrowhead carries the meaning).
    expect(hasEdge(g, "Shop:SendEmail", "ext:EmailService", "translatesOut"))->toBe(true)
    expect(edgeLabel(g, "Shop:SendEmail", "ext:EmailService", "translatesOut"))->toEqual(None)
  })

  testPromise("translation slices with no external system draw no box (opt-in)", async () => {
    let shop = structure(
      ~inboundTranslationSlices=[inbound(~name="ImportProduct", ~target="Product")],
    )
    let g = DomainGraph.build(~structures=[("Shop", shop)])
    expect(g.nodes->Array.some(n => n.kind == "ExternalSystem"))->toBe(false)
  })

  testPromise("two slices naming the same external system share one deduped box", async () => {
    let a = structure(
      ~outboundTranslationSlices=[
        outbound(~name="SendEmailA", ~consumes=["A.X"], ~target=None, ~ext=Some("EmailService")),
      ],
    )
    let b = structure(
      ~inboundTranslationSlices=[
        inbound(~name="FromEmail", ~produces=["FromEmail.Record"], ~target="Inbox", ~ext=Some("EmailService")),
      ],
    )
    let g = DomainGraph.build(~structures=[("PluginA", a), ("PluginB", b)])
    // One shared box (per-platform dedup by name) with both an out- and an in-edge.
    expect(g.nodes->Array.filter(n => n.id == "ext:EmailService")->Array.length)->toBe(1)
    expect(hasEdge(g, "PluginA:SendEmailA", "ext:EmailService", "translatesOut"))->toBe(true)
    expect(hasEdge(g, "ext:EmailService", "PluginB:FromEmail", "translatesIn"))->toBe(true)
  })

  testPromise("an event produced by two write-sides is one node with two emit edges", async () => {
    let shop = structure(
      ~aggregates=[
        writable(~name="A", ~produces=["Shop.Touched"]),
        writable(~name="B", ~produces=["Shop.Touched"]),
      ],
    )
    let g = DomainGraph.build(~structures=[("Shop", shop)])
    expect(g.nodes->Array.filter(n => n.id == "Shop.Touched")->Array.length)->toBe(1)
    expect(hasEdge(g, "Shop:A", "Shop.Touched", "emits"))->toBe(true)
    expect(hasEdge(g, "Shop:B", "Shop.Touched", "emits"))->toBe(true)
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
    let g = DomainGraph.build(~structures=[("Catalog", catalog)])
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

  testPromise("an extension wires to the command(s) it creates, not straight to the delegate", async () => {
    // The extension issues the delegate's RecordDemand command (its own commandTypes are
    // empty — the commands belong to the delegate), so the arrow lands on the command
    // node, which the ProductDemand slice handles — not straight on the slice.
    let extension: Reventless.Plugin.extensionDef = {
      name: "Ordering.Orders",
      delegateNames: ["ProductDemand"],
      eventTypes: ["Ordering.Orders.ItemOrdered"],
      commandTypes: [],
    }
    let catalog = {
      ...structure(
        ~stateChangeSlices=[
          writable(
            ~name="ProductDemand",
            ~commands=[command(~name="RecordDemand", ~mutationField="Catalog_ProductDemand_RecordDemand")],
            ~produces=["Catalog.Recorded"],
          ),
        ],
      ),
      extensions: [extension],
    }
    let g = DomainGraph.build(~structures=[("Catalog", catalog)])
    // Extension → the command it creates …
    expect(
      hasEdge(g, "Catalog:ext:Ordering.Orders", "Catalog_ProductDemand_RecordDemand", "delegatesTo"),
    )->toBe(true)
    // … the command is handled by the slice (so the full path is Extension → Command → slice) …
    expect(hasEdge(g, "Catalog_ProductDemand_RecordDemand", "Catalog:ProductDemand", "handles"))->toBe(true)
    // … and the extension no longer points straight at the slice.
    expect(hasEdge(g, "Catalog:ext:Ordering.Orders", "Catalog:ProductDemand", "delegatesTo"))->toBe(false)
  })

  testPromise("an extension with no commands falls back to delegating to the write-side", async () => {
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
    let g = DomainGraph.build(~structures=[("Catalog", catalog)])
    expect(hasEdge(g, "Catalog:ext:Ordering.Orders", "Catalog:ProductDemand", "delegatesTo"))->toBe(true)
  })

  testPromise("an owned extension point is fed by the producers of its source events", async () => {
    // Catalog owns the Catalog.Products EP; its source events are the internal
    // Catalog events produced by AddProduct, so the producing write-side feeds
    // the EP through those events.
    let ep: Reventless.Plugin.extensionPointDef = {
      name: "Catalog.Products",
      delegateNames: ["CatalogDcbEventLog"],
      sourceEventTypes: ["Catalog.ProductAdded"],
      // `command = unit`: notification-only, no inbound command protocol.
      commandTypes: Some([]),
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
    let g = DomainGraph.build(~structures=[("Catalog", catalog)])
    expect(nodeKind(g, "Catalog:ep:Catalog.Products"))->toEqual(Some("ExtensionPoint"))
    // The producing write-side emits the source event…
    expect(hasEdge(g, "Catalog:AddProduct", "Catalog.ProductAdded", "emits"))->toBe(true)
    // …which feeds the extension point — so EP focus reaches the producer.
    expect(hasEdge(g, "Catalog.ProductAdded", "Catalog:ep:Catalog.Products", "feeds"))->toBe(true)
    // …but the EP has NO inbound command protocol (command = unit), so it routes
    // nothing: no backwards EP → Command edge mislabelling the producer's own command.
    expect(hasEdge(g, "Catalog:ep:Catalog.Products", "Catalog_AddProduct", "routesTo"))->toBe(false)
  })

  testPromise("an extension point with an inbound command protocol routes to its delegate's commands", async () => {
    // The same shape, but the EP declares a non-unit `command` type — so it DOES
    // accept commands inward and routes them to the write-side that produces its
    // source events: EP → Command → write-side ("handles").
    let ep: Reventless.Plugin.extensionPointDef = {
      name: "Catalog.Products",
      delegateNames: ["AddProduct"],
      sourceEventTypes: ["Catalog.ProductAdded"],
      commandTypes: Some(["Catalog.Products.RequestAddProduct"]),
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
    let g = DomainGraph.build(~structures=[("Catalog", catalog)])
    expect(hasEdge(g, "Catalog:ep:Catalog.Products", "Catalog_AddProduct", "routesTo"))->toBe(true)
    expect(hasEdge(g, "Catalog_AddProduct", "Catalog:AddProduct", "handles"))->toBe(true)
  })
})
