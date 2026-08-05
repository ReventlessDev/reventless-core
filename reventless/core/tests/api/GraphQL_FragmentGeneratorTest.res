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
