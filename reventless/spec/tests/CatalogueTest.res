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
  admission: [{role: "Shopper", strategy: "SelfService"}],
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
      Some({Catalogue.plugin: "Ordering", identifier: "Customers", kind: "state.Deactivated"}),
    )
  )

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
