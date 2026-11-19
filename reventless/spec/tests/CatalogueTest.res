open JestGlobals

// An app's words derived from its structure, and what a rerun does with what a person wrote.

let customers: Plugin.readSideDef = {
  name: "Customers",
  queryField: "Ordering_Customers",
  singleQueryField: "Ordering_Customer",
  schema: `{"type": "object", "properties": {
    "customerId": {"type": "string"},
    "email": {"type": "string"},
    "accountStatus": {"type": "string", "enum": ["Active", "Deactivated"]}
  }}`,
  consumedEventTypes: [],
  linkedWriteSide: [],
  labelField: "email",
  searchableFields: [],
  lifecycleField: "accountStatus",
}

let orders: Plugin.writeSideDef = {
  name: "CancelOrder",
  commands: [
    {
      name: "CancelOrder",
      schema: `{"type": "object", "properties": {"orderId": {"type": "string"}}}`,
      level: Instance,
      mutationField: "Ordering_CancelOrder",
      references: [],
      requiredRoles: ["Fulfilment"],
    },
  ],
  producedEventTypes: [],
  consumedEventTypes: [],
  linkedViews: [],
  events: [],
  errors: [{name: "OrderAlreadyShipped", schema: "{}", references: []}],
}

let structure: Plugin.pluginStructure = {
  readModels: [customers],
  stateViewSlices: [],
  stateChangeSlices: [orders],
  aggregates: [],
  automationSlices: [],
  outboundTranslationSlices: [],
  inboundTranslationSlices: [],
  extensions: [],
  admission: [{role: "Shopper", strategy: SelfServiceWord}],
}

let generated = Catalogue.entries(~plugin="Ordering", structure)
let texts = generated->Array.map(e => (e.key, e.text))->Dict.fromArray

describe("Catalogue.entries", () => {
  testSync("names a view, its fields, its states, a command, a refusal and the roles", () =>
    expect(texts)->toEqual(
      dict{
        "Ordering.Customers.name": "Customer",
        "Ordering.Customers.plural": "Customers",
        "Ordering.Customers.count": "{count, plural, one {# customer} other {# customers}}",
        "Ordering.Customers.field.customerId": "Customer ID",
        "Ordering.Customers.field.email": "Email",
        "Ordering.Customers.field.accountStatus": "Account Status",
        "Ordering.Customers.state.Active": "Active",
        "Ordering.Customers.state.Deactivated": "Deactivated",
        "Ordering.CancelOrder.name": "Cancel Order",
        "Ordering.CancelOrder.field.orderId": "Order ID",
        "Ordering.CancelOrder.error.OrderAlreadyShipped": "Order already shipped",
        "Ordering.role.Shopper": "Shopper",
        "Ordering.role.Fulfilment": "Fulfilment",
        "Ordering.plugin.name": "Ordering",
      },
    )
  )

  testSync("names a state change slice that its command does not name", () => {
    let checkout = {...orders, name: "Checkout"}
    let keys =
      Catalogue.entries(~plugin="Ordering", {...structure, stateChangeSlices: [checkout]})
      ->Array.filter(e => e.key->String.endsWith(".name"))
      ->Array.map(e => (e.key, e.text))
    expect(keys)->toEqual([
      ("Ordering.CancelOrder.name", "Cancel Order"),
      ("Ordering.Checkout.name", "Checkout"),
      ("Ordering.Customers.name", "Customer"),
      ("Ordering.plugin.name", "Ordering"),
    ])
  })

  testSync(
    "names the values of an enum field other than the lifecycle, on a view and a command",
    () => {
      let tiered = {
        ...customers,
        schema: `{"type": "object", "properties": {
        "tier": {"type": "string", "enum": ["Gold", "SilverPlus"]},
        "accountStatus": {"type": "string", "enum": ["Active"]}
      }}`,
      }
      let ship = {
        ...orders,
        commands: [
          {
            ...orders.commands->Array.getUnsafe(0),
            schema: `{"type": "object", "properties": {"mode": {"oneOf": [{"const": "Express"}]}}}`,
          },
        ],
      }
      let values =
        Catalogue.entries(
          ~plugin="Ordering",
          {...structure, readModels: [tiered], stateChangeSlices: [ship]},
        )
        ->Array.filter(e => e.key->String.includes(".value."))
        ->Array.map(e => (e.key, e.text))
      expect(values)->toEqual([
        ("Ordering.CancelOrder.value.mode.Express", "Express"),
        ("Ordering.Customers.value.tier.Gold", "Gold"),
        ("Ordering.Customers.value.tier.SilverPlus", "Silver Plus"),
      ])
    },
  )

  testSync("names a field inside a record or a list of records by its path", () => {
    let withLines = {
      ...customers,
      schema: `{"type": "object", "properties": {
        "address": {"type": "object", "properties": {"postCode": {"type": "string"}}},
        "lines": {"type": "array", "items": {"type": "object", "properties": {"unitPrice": {"type": "integer"}}}}
      }}`,
      lifecycleField: ?None,
    }
    let fields =
      Catalogue.entries(~plugin="Ordering", {...structure, readModels: [withLines]})
      ->Array.filter(e => e.key->String.startsWith("Ordering.Customers.field."))
      ->Array.map(e => (e.key, e.text))
    expect(fields)->toEqual([
      ("Ordering.Customers.field.address", "Address"),
      ("Ordering.Customers.field.address.postCode", "Post Code"),
      ("Ordering.Customers.field.lines", "Lines"),
      ("Ordering.Customers.field.lines.unitPrice", "Unit Price"),
    ])
  })

  testSync("keys are sorted, so a file written from them is stable", () =>
    expect(generated->Array.map(e => e.key))->toEqual(
      generated->Array.map(e => e.key)->Array.toSorted(String.compare),
    )
  )

  testSync("records the element each key came from", () =>
    expect(
      generated
      ->Array.find(e => e.key == "Ordering.Customers.state.Deactivated")
      ->Option.map(e => e.element),
    )->toEqual(
      Some({Catalogue.plugin: "Ordering", identifier: "Customers", kind: StateText("Deactivated")}),
    )
  )

  testSync("a declared plural is the view's plural; a derived one is not read", () => {
    let status = {
      ...customers,
      name: "Status",
      queryField: "Ordering_Statuses",
      singleQueryField: "Ordering_Status",
      schema: `{"type": "object", "properties": {}}`,
      lifecycleField: ?None,
    }
    let textsOf = (view: Plugin.readSideDef) =>
      Catalogue.entries(~plugin="Ordering", {...structure, readModels: [view]})
      ->Array.filter(e => e.key->String.startsWith("Ordering.Status."))
      ->Array.map(e => (e.key, e.text))
      ->Dict.fromArray
    expect((
      textsOf({...status, plural: "Statuses", pluralSource: "declared"}),
      textsOf({...status, plural: "Statuss", pluralSource: "derived"})->Dict.get(
        "Ordering.Status.plural",
      ),
    ))->toEqual((
      dict{
        "Ordering.Status.name": "Status",
        "Ordering.Status.plural": "Statuses",
        "Ordering.Status.count": "{count, plural, one {# status} other {# statuses}}",
      },
      Some("Status"),
    ))
  })

  testSync("reads the plugin's name off its GraphQL fields", () =>
    expect(Catalogue.pluginNameOf(structure))->toEqual(Some("Ordering"))
  )

  testSync("humanizes camelCase, capital runs and acronyms", () =>
    expect((
      Catalogue.humanizeKey("primaryResourceArn"),
      Catalogue.humanizeKey("ARNValue"),
      Catalogue.sentence("OrderNotYetPaid"),
    ))->toEqual(("Primary Resource ARN", "ARN Value", "Order not yet paid"))
  )

  testSync("keeps a unit whole and spelled as written", () =>
    expect((
      Catalogue.humanizeKey("deliveredKWh"),
      Catalogue.humanizeKey("kWh"),
      Catalogue.humanizeKey("priceMWh"),
      Catalogue.humanizeKey("maxKW"),
      Catalogue.humanizeKey("kwhPrice"),
      Catalogue.humanizeKey("whatever"),
      Catalogue.sentence("CapacityAboveMWh"),
    ))->toEqual((
      "Delivered kWh",
      "kWh",
      "Price MWh",
      "Max kW",
      "kWh Price",
      "Whatever",
      "Capacity above MWh",
    ))
  )
})

describe("Catalogue.merge", () => {
  let hash = (s: string) => `#${s}`
  let first = Catalogue.merge(~generated, ~existing=Dict.make(), ~locks=Dict.make(), ~hash)

  testSync("a first run adds every key", () =>
    expect((first.added->Array.length, first.updated, first.edited, first.orphans))->toEqual((
      Array.length(generated),
      [],
      [],
      [],
    ))
  )

  testSync("a rerun with nothing new writes the same files", () => {
    let again = Catalogue.merge(~generated, ~existing=first.catalogue, ~locks=first.locks, ~hash)
    expect((
      Catalogue.catalogueText(again.catalogue) == Catalogue.catalogueText(first.catalogue),
      Catalogue.lockText(again.locks) == Catalogue.lockText(first.locks),
      again.added,
    ))->toEqual((true, true, []))
  })

  testSync("a text a person edited is kept; one still generated follows the structure", () => {
    let edited = first.catalogue->Dict.copy
    edited->Dict.set("Ordering.Customers.name", "Client")
    let renamed =
      generated->Array.map(
        e => e.key == "Ordering.CancelOrder.name" ? {...e, text: "Cancel the Order"} : e,
      )
    let next = Catalogue.merge(~generated=renamed, ~existing=edited, ~locks=first.locks, ~hash)
    expect((
      next.catalogue->Dict.get("Ordering.Customers.name"),
      next.catalogue->Dict.get("Ordering.CancelOrder.name"),
      next.edited,
      next.updated,
    ))->toEqual((
      Some("Client"),
      Some("Cancel the Order"),
      ["Ordering.Customers.name"],
      ["Ordering.CancelOrder.name"],
    ))
  })

  testSync("a key the structure lost is reported and kept, not deleted", () => {
    let withoutRefusal =
      generated->Array.filter(e => e.key != "Ordering.CancelOrder.error.OrderAlreadyShipped")
    let next = Catalogue.merge(
      ~generated=withoutRefusal,
      ~existing=first.catalogue,
      ~locks=first.locks,
      ~hash,
    )
    expect((
      next.orphans,
      next.catalogue->Dict.get("Ordering.CancelOrder.error.OrderAlreadyShipped"),
    ))->toEqual((["Ordering.CancelOrder.error.OrderAlreadyShipped"], Some("Order already shipped")))
  })

  testSync("the files read back as they were written", () =>
    expect((
      Catalogue.readCatalogue(Catalogue.catalogueText(first.catalogue)) == first.catalogue,
      Catalogue.lockText(Catalogue.readLocks(Catalogue.lockText(first.locks))) ==
        Catalogue.lockText(first.locks),
    ))->toEqual((true, true))
  )
})
