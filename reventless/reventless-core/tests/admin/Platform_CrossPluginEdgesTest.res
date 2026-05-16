// Phase 6b validation: Platform_CrossPluginEdges.computeEdges emits the four
// cross-plugin mechanisms (EventTypeMatch with broad consumer types,
// AutomationSlice, InboundTranslation, Extension).

open Jest
open Expect
open Reventless.Plugin

let emptyStructure: pluginStructure = {
  readModels: [],
  stateViewSlices: [],
  stateChangeSlices: [],
  aggregates: [],
  automationSlices: [],
  outboundTranslationSlices: [],
  inboundTranslationSlices: [],
  extensions: [],
}

let writable = (
  ~name,
  ~producedEventTypes=[],
  ~consumedEventTypes=[],
  ~linkedViews=[],
): writableDef => {
  name,
  commands: [],
  producedEventTypes,
  consumedEventTypes,
  linkedViews,
  consistencyRead: None,
}

let queryable = (~name, ~consumedEventTypes=[]): queryableDef => {
  name,
  queryField: name,
  schema: "",
  consumedEventTypes,
  linkedWriteSide: [],
  labelField: "id",
  searchableFields: ["id"],
  statusField: None,
}

let automation = (~name, ~consumedEventTypes, ~producedCommandTypes, ~targetName): automationSliceDef => {
  name,
  consumedEventTypes,
  producedCommandTypes,
  targetName,
}

let outbound = (~name, ~consumedEventTypes, ~inboundCommandTypes, ~targetName=?): outboundTranslationSliceDef => {
  name,
  consumedEventTypes,
  inboundCommandTypes,
  targetName,
}

let inbound = (~name, ~commandTypes, ~targetName): inboundTranslationSliceDef => {
  name,
  commandTypes,
  targetName,
}

let extension = (~name, ~delegateNames=[], ~eventTypes=[], ~commandTypes=[]): extensionDef => {
  name,
  delegateNames,
  eventTypes,
  commandTypes,
}

// Single-edge summary tuple used to compress the assertion into one expect call.
let summarize = (e: graphEdge) => (
  e.source.pluginName,
  e.source.componentName,
  e.source.kind,
  e.target.pluginName,
  e.target.componentName,
  e.target.kind,
  e.mechanism,
  e.viaEvents,
)

describe("Platform_CrossPluginEdges.computeEdges", () => {
  describe("EventTypeMatch — broad consumer types", () => {
    test("aggregate → cross-plugin StateViewSlice produces edge with kind StateViewSlice", () => {
      let entries = [
        (
          "PluginA",
          {
            ...emptyStructure,
            aggregates: [
              writable(~name="Order", ~producedEventTypes=["PluginA.OrderPlaced"]),
            ],
          },
        ),
        (
          "PluginB",
          {
            ...emptyStructure,
            stateViewSlices: [
              queryable(~name="Orders", ~consumedEventTypes=["PluginA.OrderPlaced"]),
            ],
          },
        ),
      ]
      let edges = Platform_CrossPluginEdges.computeEdges(entries)
      expect(edges->Array.map(summarize))->toEqual([
        (
          "PluginA",
          "Order",
          "Aggregate",
          "PluginB",
          "Orders",
          "StateViewSlice",
          "EventTypeMatch",
          ["PluginA.OrderPlaced"],
        ),
      ])
    })

    test("aggregate → cross-plugin AutomationSlice consumer produces edge with kind AutomationSlice", () => {
      let entries = [
        (
          "PluginA",
          {
            ...emptyStructure,
            aggregates: [
              writable(~name="Order", ~producedEventTypes=["PluginA.OrderPlaced"]),
            ],
          },
        ),
        (
          "PluginB",
          {
            ...emptyStructure,
            stateChangeSlices: [writable(~name="ShipOrder")],
            automationSlices: [
              automation(
                ~name="AutoShipOrder",
                ~consumedEventTypes=["PluginA.OrderPlaced"],
                ~producedCommandTypes=["PluginB.ShipOrder"],
                ~targetName="ShipOrder",
              ),
            ],
          },
        ),
      ]
      let edges =
        Platform_CrossPluginEdges.computeEdges(entries)
        ->Array.filter(e => e.mechanism == "EventTypeMatch")
      expect(edges->Array.map(summarize))->toEqual([
        (
          "PluginA",
          "Order",
          "Aggregate",
          "PluginB",
          "AutoShipOrder",
          "AutomationSlice",
          "EventTypeMatch",
          ["PluginA.OrderPlaced"],
        ),
      ])
    })

    test("aggregate → cross-plugin OutboundTranslationSlice consumer produces edge with kind OutboundTranslationSlice", () => {
      let entries = [
        (
          "PluginA",
          {
            ...emptyStructure,
            aggregates: [
              writable(~name="Order", ~producedEventTypes=["PluginA.OrderPlaced"]),
            ],
          },
        ),
        (
          "PluginB",
          {
            ...emptyStructure,
            outboundTranslationSlices: [
              outbound(
                ~name="SendOrderConfirmation",
                ~consumedEventTypes=["PluginA.OrderPlaced"],
                ~inboundCommandTypes=[],
              ),
            ],
          },
        ),
      ]
      let edges =
        Platform_CrossPluginEdges.computeEdges(entries)
        ->Array.filter(e => e.mechanism == "EventTypeMatch")
      expect(edges->Array.map(summarize))->toEqual([
        (
          "PluginA",
          "Order",
          "Aggregate",
          "PluginB",
          "SendOrderConfirmation",
          "OutboundTranslationSlice",
          "EventTypeMatch",
          ["PluginA.OrderPlaced"],
        ),
      ])
    })

    test("same-plugin event consumers do not produce cross-plugin edges", () => {
      let entries = [
        (
          "PluginA",
          {
            ...emptyStructure,
            aggregates: [
              writable(~name="Order", ~producedEventTypes=["PluginA.OrderPlaced"]),
            ],
            stateViewSlices: [
              queryable(~name="Orders", ~consumedEventTypes=["PluginA.OrderPlaced"]),
            ],
          },
        ),
      ]
      expect(Platform_CrossPluginEdges.computeEdges(entries)->Array.length)->toBe(0)
    })
  })

  describe("AutomationSlice mechanism", () => {
    test("cross-plugin command routing produces AutomationSlice edge with target kind StateChangeSlice", () => {
      let entries = [
        (
          "PluginA",
          {
            ...emptyStructure,
            automationSlices: [
              automation(
                ~name="AutoShipOrder",
                ~consumedEventTypes=[],
                ~producedCommandTypes=["PluginB.ShipOrder"],
                ~targetName="ShipOrder",
              ),
            ],
          },
        ),
        (
          "PluginB",
          {
            ...emptyStructure,
            stateChangeSlices: [writable(~name="ShipOrder")],
          },
        ),
      ]
      let edges =
        Platform_CrossPluginEdges.computeEdges(entries)
        ->Array.filter(e => e.mechanism == "AutomationSlice")
      expect(edges->Array.map(summarize))->toEqual([
        (
          "PluginA",
          "AutoShipOrder",
          "AutomationSlice",
          "PluginB",
          "ShipOrder",
          "StateChangeSlice",
          "AutomationSlice",
          ["PluginB.ShipOrder"],
        ),
      ])
    })

    test("same-plugin AutomationSlice target produces no cross-plugin edge", () => {
      let entries = [
        (
          "PluginA",
          {
            ...emptyStructure,
            stateChangeSlices: [writable(~name="ShipOrder")],
            automationSlices: [
              automation(
                ~name="AutoShipOrder",
                ~consumedEventTypes=[],
                ~producedCommandTypes=["PluginA.ShipOrder"],
                ~targetName="ShipOrder",
              ),
            ],
          },
        ),
      ]
      let edges =
        Platform_CrossPluginEdges.computeEdges(entries)
        ->Array.filter(e => e.mechanism == "AutomationSlice")
      expect(edges->Array.length)->toBe(0)
    })

    test("AutomationSlice routing into a cross-plugin Aggregate marks target kind Aggregate", () => {
      let entries = [
        (
          "PluginA",
          {
            ...emptyStructure,
            automationSlices: [
              automation(
                ~name="AutoAdd",
                ~consumedEventTypes=[],
                ~producedCommandTypes=["PluginB.AddProduct"],
                ~targetName="Product",
              ),
            ],
          },
        ),
        (
          "PluginB",
          {
            ...emptyStructure,
            aggregates: [writable(~name="Product")],
          },
        ),
      ]
      let edges =
        Platform_CrossPluginEdges.computeEdges(entries)
        ->Array.filter(e => e.mechanism == "AutomationSlice")
      expect(edges->Array.map(e => e.target.kind))->toEqual(["Aggregate"])
    })
  })

  describe("InboundTranslation mechanism", () => {
    test("cross-plugin command routing produces InboundTranslation edge", () => {
      let entries = [
        (
          "PluginA",
          {
            ...emptyStructure,
            inboundTranslationSlices: [
              inbound(
                ~name="ImportProduct",
                ~commandTypes=["PluginB.AddProduct"],
                ~targetName="Product",
              ),
            ],
          },
        ),
        (
          "PluginB",
          {
            ...emptyStructure,
            aggregates: [writable(~name="Product")],
          },
        ),
      ]
      let edges =
        Platform_CrossPluginEdges.computeEdges(entries)
        ->Array.filter(e => e.mechanism == "InboundTranslation")
      expect(edges->Array.map(summarize))->toEqual([
        (
          "PluginA",
          "ImportProduct",
          "InboundTranslationSlice",
          "PluginB",
          "Product",
          "Aggregate",
          "InboundTranslation",
          ["PluginB.AddProduct"],
        ),
      ])
    })

    test("same-plugin InboundTranslation target produces no cross-plugin edge", () => {
      let entries = [
        (
          "PluginA",
          {
            ...emptyStructure,
            aggregates: [writable(~name="Product")],
            inboundTranslationSlices: [
              inbound(
                ~name="ImportProduct",
                ~commandTypes=["PluginA.AddProduct"],
                ~targetName="Product",
              ),
            ],
          },
        ),
      ]
      let edges =
        Platform_CrossPluginEdges.computeEdges(entries)
        ->Array.filter(e => e.mechanism == "InboundTranslation")
      expect(edges->Array.length)->toBe(0)
    })
  })

  describe("Extension mechanism (regression coverage)", () => {
    test("dotted EP-name prefix in another plugin produces Extension edge", () => {
      let entries = [
        (
          "Catalog",
          {
            ...emptyStructure,
            aggregates: [writable(~name="Product")],
          },
        ),
        (
          "Ordering",
          {
            ...emptyStructure,
            extensions: [
              extension(
                ~name="Catalog.Products",
                ~delegateNames=["AddProduct"],
                ~commandTypes=["Catalog.Products.AddProduct"],
              ),
            ],
          },
        ),
      ]
      let edges =
        Platform_CrossPluginEdges.computeEdges(entries)
        ->Array.filter(e => e.mechanism == "Extension")
      expect(edges->Array.map(summarize))->toEqual([
        (
          "Catalog",
          "Catalog.Products",
          "ExtensionPoint",
          "Ordering",
          "Catalog.Products",
          "Extension",
          "Extension",
          ["Catalog.Products.AddProduct"],
        ),
      ])
    })
  })
})
