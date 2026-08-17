open JestGlobals

// A multi-variant command union serializes as a sury `Union`, the same shape an
// aggregate command produces. The generator must decide whether to inject the
// aggregate-style `id: ID!` argument from the entry's `injectIdArg` flag, not
// from the schema shape — otherwise a multi-variant DCB slice (e.g. CancelOrder
// + @noApi ReopenOrder) wrongly inherits a spurious `id: ID!` and callers that
// send only the slice's own key field get `MissingFieldArgument: id`.
module OrderSliceCmd = {
  @schema
  type command =
    | CancelOrder({orderId: string})
    | ReopenOrder({orderId: string})
}

let mutationFor = (fragment, needle) =>
  GraphQL_Stitcher.decode(fragment).mutations->Array.find(m => m->String.includes(needle))

describe("GraphQL_FragmentGenerator.generate mutation id injection", () => {
  testSync("multi-variant slice entry (injectIdArg: false) omits the id argument", () => {
    let fragment = GraphQL_FragmentGenerator.generate(
      ~mutationEntries=[
        {
          ReventlessInfra.Api.fieldNames: ["Ordering_CancelOrder"],
          commandSchema: OrderSliceCmd.commandSchema->S.castToUnknown,
          injectIdArg: false,
        },
      ],
      ~queryEntries=[],
    )
    let field = mutationFor(fragment, "Ordering_CancelOrder")->Option.getOr("")
    expect(field->String.includes("orderId"))->toBe(true)
    expect(field->String.includes("id: ID!"))->toBe(false)
  })

  testSync("aggregate-style entry (default) injects id: ID! ahead of the payload", () => {
    let fragment = GraphQL_FragmentGenerator.generate(
      ~mutationEntries=[
        {
          ReventlessInfra.Api.fieldNames: ["Ordering_CancelOrder"],
          commandSchema: OrderSliceCmd.commandSchema->S.castToUnknown,
        },
      ],
      ~queryEntries=[],
    )
    let field = mutationFor(fragment, "Ordering_CancelOrder")->Option.getOr("")
    expect(field->String.includes("id: ID!, orderId"))->toBe(true)
  })
})

// A slice TODO row stores its work item as `JSON.t`, which the IR can only call
// `Unknown` — and `Unknown` renders as `String!`. Serving a stored object
// through a String field fails at execution ("String cannot represent value:
// { … }") as soon as a client selects it, so `Dcb_Builder` describes the row
// with `todoRowSchemaFor` and the item's own schema instead.
module GeocodeItem = {
  @schema
  type outboundItem = {customerId: string, address: string}
}

let typeDefFor = (fragment, needle) =>
  GraphQL_Stitcher.decode(fragment).types->Array.find(t => t->String.includes(needle))

describe("GraphQL_FragmentGenerator slice TODO rows", () => {
  testSync("item carries the slice's item type, not String", () => {
    let fragment = GraphQL_FragmentGenerator.generate(
      ~mutationEntries=[],
      ~queryEntries=[
        {
          ReventlessInfra.Api.singleFieldName: "Ordering_GeocodeCustomerAddressTodo",
          listFieldName: "Ordering_GeocodeCustomerAddressTodos",
          returnTypeName: "Ordering_GeocodeCustomerAddressTodo",
          stateSchema: OutboundTranslationSlice_Callback.todoRowSchemaFor(
            GeocodeItem.outboundItemSchema,
          )->S.castToUnknown,
          authorization: None,
          connectionSpec: true,
        },
      ],
    )
    let row = typeDefFor(fragment, "type Ordering_GeocodeCustomerAddressTodo ")->Option.getOr("")
    expect(row->String.includes("item: Ordering_GeocodeCustomerAddressTodoItem!"))->toBe(true)

    let item =
      typeDefFor(fragment, "type Ordering_GeocodeCustomerAddressTodoItem ")->Option.getOr("")
    expect(item->String.includes("customerId: ID!"))->toBe(true)
    expect(item->String.includes("address: String!"))->toBe(true)
  })
})

// A state that declares no `@id` used to produce `emptyCapability` — no per-field
// filter and no order-by at all, so every narrowing a client asked for happened
// client-side over one page. The key is knowable without the annotation in the
// common cases; these pin which cases those are, and which still need `@id`.
describe("resolveKeyField — the ladder", () => {
  let rungFor = (~entityName, schema) =>
    GraphQL_FragmentGenerator.resolveKeyField(~entityName, schema->S.castToUnknown)

  testSync("a lone `*Id` field is the only thing the key could be", () => {
    let schema = S.schema(s => {"productId": s.matches(S.string), "name": s.matches(S.string)})
    expect(rungFor(~entityName="AvailableProducts", schema))->toEqual(Some(("productId", "sole")))
  })

  testSync("several `*Id` fields are disambiguated by the component name", () => {
    let schema = S.schema(s =>
      {"productId": s.matches(S.string), "categoryId": s.matches(S.string)}
    )
    expect(rungFor(~entityName="Products", schema))->toEqual(Some(("productId", "convention")))
  })

  // The `-ies` plural the naive singulariser gets wrong, on the key side too.
  testSync("the convention rung singularises the way Api_Naming does", () => {
    let schema = S.schema(s =>
      {"categoryId": s.matches(S.string), "ownerId": s.matches(S.string)}
    )
    expect(rungFor(~entityName="Categories", schema))->toEqual(Some(("categoryId", "convention")))
  })

  // ProductDemand: two `*Id` fields, and the name yields `productDemandId`, which
  // is not a field. Declining is the honest answer — this is what `@id` is for.
  testSync("several `*Id` fields with no name match declines", () => {
    let schema = S.schema(s =>
      {"productId": s.matches(S.string), "categoryId": s.matches(S.string)}
    )
    expect(rungFor(~entityName="ProductDemand", schema))->toEqual(None)
  })

  testSync("no `*Id` field at all declines", () => {
    let schema = S.schema(s => {"email": s.matches(S.string), "address": s.matches(S.string)})
    expect(rungFor(~entityName="Customers", schema))->toEqual(None)
  })

  // `paid` / `valid` end with a lowercase "id". SchemaType.isIdFieldName accepts
  // them (it lowercases first, which is right for its own use); a key field must
  // not be nominated that way.
  testSync("a word merely ending in `id` is not a key", () => {
    let schema = S.schema(s => {"paid": s.matches(S.string), "valid": s.matches(S.string)})
    expect(rungFor(~entityName="Invoices", schema))->toEqual(None)
  })
})

describe("deriveServerCapability — inferred keys reach the SDL surface", () => {
  let capabilityFor = (~entityName, schema) =>
    GraphQL_FragmentGenerator.deriveServerCapability(~entityName, schema->S.castToUnknown)

  testSync("an inferred key yields an eq filter and a sort field", () => {
    let schema = S.schema(s => {"orderId": s.matches(S.string), "total": s.matches(S.float)})
    let c = capabilityFor(~entityName="Orders", schema)
    expect(c.filterFields->Array.map(f => f.name))->toEqual(["orderId"])
    expect(c.sortFields)->toEqual(["orderId"])
  })

  testSync("an unresolvable key still yields nothing — the old behaviour, now narrowed", () => {
    let schema = S.schema(s => {"email": s.matches(S.string)})
    let c = capabilityFor(~entityName="Customers", schema)
    expect((c.filterFields->Array.length, c.sortFields->Array.length))->toEqual((0, 0))
  })

  testSync("the filter input carries the inferred key's eq field", () => {
    let schema = S.schema(s => {"orderId": s.matches(S.string)})
    let input = GraphQL_FragmentGenerator.deriveConnectionFilterType(
      ~filterTypeName="Ordering_OrderFilter",
      ~capability=capabilityFor(~entityName="Orders", schema),
    )
    // `ID`, not `String`: a `*Id`-named field is an EntityId in the IR, and the
    // filter input mirrors the field's own GraphQL type.
    expect(input->String.includes("orderIdEq: ID"))->toBe(true)
  })

  // No OrderBy type is emitted at all when nothing is sortable, so an inferred
  // key is the difference between having the type and not having it.
  testSync("the order-by pair exists because of the inferred key", () => {
    let schema = S.schema(s => {"orderId": s.matches(S.string)})
    let types = GraphQL_FragmentGenerator.deriveConnectionOrderByType(
      ~singularTypeName="Ordering_Order",
      ~capability=capabilityFor(~entityName="Orders", schema),
    )
    expect(types->Array.length)->toBe(2)
    expect(types->Array.join("\n")->String.includes("enum Ordering_OrderOrderField"))->toBe(true)
  })
})

// A semantic composite is one type wherever it appears. Named from the field
// path that reached it, two commands taking a price produced two identical
// `{amount, currency}` inputs and, beside each, its own copy of the 165-value
// ISO 4217 enum — six copies of it across one example schema.
module AddProductCmd = {
  @schema
  type command =
    | AddProduct({productId: string, price: Reventless.Money.t})
    | ArchiveProduct({productId: string})
}

module ChangePriceCmd = {
  @schema
  type command =
    | ChangeProductPrice({productId: string, price: Reventless.Money.t})
    | ClearProductPrice({productId: string})
}

describe("semantic composites are named once, not once per field", () => {
  let countDefs = (types, keyword, name) =>
    types->Array.filter(t => t->String.startsWith(`${keyword} ${name} {`))->Array.length

  let fragmentTypes = GraphQL_Stitcher.decode(
    GraphQL_FragmentGenerator.generate(
      ~mutationEntries=[
        {
          ReventlessInfra.Api.fieldNames: ["Catalog_AddProduct"],
          commandSchema: AddProductCmd.commandSchema->S.castToUnknown,
          injectIdArg: false,
        },
        {
          ReventlessInfra.Api.fieldNames: ["Catalog_ChangeProductPrice"],
          commandSchema: ChangePriceCmd.commandSchema->S.castToUnknown,
          injectIdArg: false,
        },
      ],
      ~queryEntries=[],
    ),
  ).types

  testSync("two commands taking a price share one input definition", () =>
    expect(fragmentTypes->countDefs("input", "MoneyInput"))->toBe(1)
  )

  testSync("and one currency enum between them", () =>
    expect(fragmentTypes->countDefs("enum", "MoneyCurrency"))->toBe(1)
  )

  // The control: these are the names the field-path naming produced, and their
  // absence is the whole change. Without this the assertions above would pass
  // just as well against a schema that emitted both namings.
  testSync("nothing is named after the field path that reached it", () =>
    expect(fragmentTypes->Array.some(t => t->String.includes("AddProductPrice")))->toBe(false)
  )

  // GraphQL forbids one name serving as both an object and an input, so the two
  // positions differ by suffix — while sharing the enum, which has no such
  // restriction and would otherwise be emitted twice over.
  testSync("the output position keeps the bare name", () => {
    let types = GraphQL_FragmentGenerator.deriveObjectTypeWithNested(
      ~typeName="Catalog_Product",
      ~includeIdParam=false,
      S.schema(s =>
        {
          "productId": s.matches(S.string),
          "price": s.matches(Reventless.Money.schema),
        }
      )->S.castToUnknown,
    )
    expect((
      types->countDefs("type", "Money"),
      types->countDefs("enum", "MoneyCurrency"),
      types->Array.some(t => t->String.includes("price: Money!")),
    ))->toEqual((1, 1, true))
  })
})

// `mutationArgTypes` is what a client that assembles its own mutation document
// reads instead of guessing the variable types. Its whole value is that it
// agrees with the SDL, so the last case here checks every published string
// against the argument the generator emitted for the same command.
module PlaceOrder = {
  @schema
  type shippingMethod = Standard | Express

  // A single-payload command reaches the generator as a plain object schema —
  // the `Object(_)` branch of `generate` — which is also the shape one variant
  // of a union presents to `mutationArgTypes`.
  let schema =
    S.schema(s =>
      {
        "orderId": s.matches(S.string),
        "shippingMethod": s.matches(shippingMethodSchema),
        "total": s.matches(Reventless.Money.schema),
        "tip": s.matches(S.option(Reventless.Money.schema)),
        "itemCount": s.matches(S.int),
      }
    )->S.castToUnknown
}

describe("GraphQL_FragmentGenerator.mutationArgTypes", () => {
  let argTypes =
    GraphQL_FragmentGenerator.mutationArgTypes(
      ~fieldName="Ordering_PlaceOrder",
      PlaceOrder.schema,
    )->Option.getOr(Dict.make())

  let typeOf = (name: string) => argTypes->Dict.get(name)

  // The defect this exists for: a client that fell back to `String!` here got
  // `Variable "$shippingMethod" of type "String!" used in position expecting
  // type "Ordering_PlaceOrderShippingMethod!"` — a 200 carrying no data. The
  // name is composed from the mutation field, so nothing downstream of the
  // JSON Schema can reconstruct it.
  testSync("names an enum by the type the mutation field composes", () =>
    expect(typeOf("shippingMethod"))->toEqual(Some("Ordering_PlaceOrderShippingMethod!"))
  )

  // A semantic composite is named after the semantic, and takes the `Input`
  // suffix in argument position.
  testSync("names a semantic composite by its input type", () =>
    expect(typeOf("total"))->toEqual(Some("MoneyInput!"))
  )

  // Nullability is the other half of the answer: with the right name and an
  // unconditional `!` appended, the declaration still would not match.
  testSync("distinguishes an optional argument from a required one", () =>
    expect((typeOf("tip"), typeOf("total")))->toEqual((Some("MoneyInput"), Some("MoneyInput!")))
  )

  // Both of these differ from what the JSON-Schema type alone suggests —
  // `orderId` is a plain string there and `itemCount` an integer — which is the
  // narrower reason a client cannot derive even the scalars itself.
  testSync("reports the scalar the server chose, not the JSON-Schema one", () =>
    expect((typeOf("orderId"), typeOf("itemCount")))->toEqual((Some("ID!"), Some("Float!")))
  )

  // The property that makes publishing worth more than re-deriving downstream:
  // one producer, so what a client declares and what the server declares cannot
  // drift apart.
  testSync("agrees with every argument the SDL declares", () => {
    let fragment = GraphQL_FragmentGenerator.generate(
      ~mutationEntries=[
        {
          ReventlessInfra.Api.fieldNames: ["Ordering_PlaceOrder"],
          commandSchema: PlaceOrder.schema,
          injectIdArg: false,
        },
      ],
      ~queryEntries=[],
    )
    let field = mutationFor(fragment, "Ordering_PlaceOrder")->Option.getOr("")
    let mismatched =
      argTypes
      ->Dict.toArray
      ->Array.filter(((arg, gqlType)) => !(field->String.includes(`${arg}: ${gqlType}`)))
      ->Array.map(((arg, gqlType)) => `${arg}: ${gqlType}`)
    expect((mismatched, field->String.length > 0))->toEqual(([], true))
  })
})

// What a caller holding a pointer to a withheld row may learn about it, and what
// the two doors that could never answer for one can now be asked.
describe("the reference door and the archive argument", () => {
  open Expect

  // The narrowness is the type's, not a rule each backend re-implements: a caller
  // cannot ask this door for a price, because there is no price on it.
  testSync("projects a reference to id, label and the state that retired it", () => {
    let sdl = GraphQL_FragmentGenerator.deriveRefTypeSdl(~returnTypeName="Catalog_Product")
    expect((
      sdl->String.includes("type Catalog_ProductRef"),
      sdl->String.includes("label: String!"),
      sdl->String.includes("retiredState: String"),
      sdl->String.includes("price"),
    ))->toEqual((true, true, true, false))
  })

  // Emitted for every view rather than only the annotated ones, on the reasoning
  // `includeRetired` already states: a field that appears with an annotation makes
  // adding or removing it a breaking schema change.
  testSync("names the door after the list field it resolves against", () =>
    expect(
      GraphQL_FragmentGenerator.deriveRefsQueryField(
        ~listFieldName="Catalog_Products",
        ~returnTypeName="Catalog_Product",
      ),
    )->toEqual("  Catalog_ProductsRefs(ids: [ID!]!): [Catalog_ProductRef!]!")
  )

  // The dead end this closes: the archive toggle put retired rows on screen and
  // clicking one read a door that refused them to every caller alive, elevated
  // included, because there was no way to ask.
  testSync("lets the single-entity and by-ids doors be asked for the archive", () =>
    expect((
      GraphQL_FragmentGenerator.deriveObjectQueryField(
        ~singleFieldName="Catalog_Product",
        ~typeName="Catalog_Product",
      )->String.includes("includeRetired: Boolean"),
      GraphQL_FragmentGenerator.deriveByIdsQueryField(
        ~listFieldName="Catalog_Products",
        ~returnTypeName="Catalog_Product",
      )->String.includes("includeRetired: Boolean"),
    ))->toEqual((true, true))
  )

  // A sub-id read keeps its sort-key argument beside the new one; dropping it
  // would silently turn a two-key door into a one-key one.
  testSync("keeps the sub-id argument when the view has one", () =>
    expect(
      GraphQL_FragmentGenerator.deriveObjectQueryField(
        ~singleFieldName="Ordering_OrderLine",
        ~typeName="Ordering_OrderLine",
        ~subIdField="lineNo",
      ),
    )->toEqual("  Ordering_OrderLine(id: ID!, lineNo: String!, includeRetired: Boolean): Ordering_OrderLine")
  )
})

// The by-index door is asserted whole rather than by `String.includes`, because
// what was wrong with it was never a missing substring: the field declared an
// `id` its resolver did not read and omitted the key its resolver did, so every
// part of the signature is load-bearing.
describe("the by-index door", () => {
  let index = (~index, ~idField=?, ~subIdField=?): Reventless.ReadModel.indexConfig => {
    index,
    type_: "S",
    idField: ?idField,
    subIdField: ?subIdField,
    projectionType: ALL,
  }

  testSync("takes the index value it filters on, and can be asked for the archive", () =>
    expect(
      GraphQL_FragmentGenerator.deriveIndexQueryField(
        ~singleFieldName="Catalog_Product",
        ~indexConfig=index(~index="categoryId"),
        ~connectionTypeName="Catalog_ProductConnection",
      ),
    )->toEqual(
      "  Catalog_ProductByCategoryId(categoryId: String!, first: Int, after: String, last: Int, before: String, includeRetired: Boolean): Catalog_ProductConnection!",
    )
  )

  // A named index has two different strings in play — `byOwner` names the index,
  // `ownerId` names the column. The field is named after the first and keyed on
  // the second, and swapping them is how the local adapter came to offer an
  // argument the row had no field for.
  testSync("names the field after the index and keys it on the column", () =>
    expect(
      GraphQL_FragmentGenerator.deriveIndexQueryField(
        ~singleFieldName="Ordering_Order",
        ~indexConfig=index(~index="byOwner", ~idField="ownerId"),
        ~connectionTypeName="Ordering_OrderConnection",
      ),
    )->toEqual(
      "  Ordering_OrderByOwner(ownerId: String!, first: Int, after: String, last: Int, before: String, includeRetired: Boolean): Ordering_OrderConnection!",
    )
  )

  // Optional, unlike the partition argument: naming the index value is the point
  // of the door, narrowing to one sort value is a refinement.
  testSync("offers the sort key the sort template has always read", () =>
    expect(
      GraphQL_FragmentGenerator.deriveIndexQueryField(
        ~singleFieldName="Ordering_Order",
        ~indexConfig=index(~index="byCustomer", ~idField="customerId", ~subIdField="placedAt"),
        ~connectionTypeName="Ordering_OrderConnection",
      ),
    )->toEqual(
      "  Ordering_OrderByCustomer(customerId: String!, placedAt: String, first: Int, after: String, last: Int, before: String, includeRetired: Boolean): Ordering_OrderConnection!",
    )
  )

  // One derivation, called by every backend. The local adapter used to spell the
  // name out itself and produced `XByByOwner` where this produces `XByOwner`.
  testSync("drops a leading `by` exactly once", () =>
    expect((
      GraphQL_FragmentGenerator.indexQueryFieldName(~singleFieldName="X", ~index="byOwner"),
      GraphQL_FragmentGenerator.indexQueryFieldName(~singleFieldName="X", ~index="ownerId"),
      GraphQL_FragmentGenerator.indexQueryFieldName(~singleFieldName="X", ~index="by"),
    ))->toEqual(("XByOwner", "XByOwnerId", "XByBy"))
  )
})
