// The narrow API for visitors: the fields a plugin declares `AllowAnonymous` land
// in its schema and nowhere else, with only the types they reach; a plugin that
// declares none keeps the schema it had; and a deployment that hosts no narrow
// API still refuses them.

open JestGlobals

module V = AppSync_VisitorSchema
module Stitcher = ReventlessCore.GraphQL_Stitcher

let anonymous = Reventless.Authorization.AllowAnonymous
let shoppers = Reventless.Authorization.AllowRoles([Reventless.Role.make("Shopper")])

let mutationEntries: array<ReventlessInfra.Api.mutationSchemaEntry> = [
  {
    fieldNames: ["R_SignUp"],
    commandSchema: S.unknown,
    fieldPermissions: Dict.fromArray([("R_SignUp", anonymous)]),
  },
  {
    fieldNames: ["R_PlaceOrder"],
    commandSchema: S.unknown,
    fieldPermissions: Dict.fromArray([("R_PlaceOrder", shoppers)]),
  },
]

let view = (~single, ~list, ~permission): ReventlessInfra.Api.querySchemaEntry => {
  singleFieldName: single,
  listFieldName: list,
  returnTypeName: single,
  stateSchema: S.unknown,
  authorization: None,
  permission,
}

let queryEntries = [
  view(~single="R_Window", ~list="R_Windows", ~permission=anonymous),
  view(~single="R_Order", ~list="R_Orders", ~permission=shoppers),
]

let fragment = Stitcher.encode({
  types: [
    "type R_Window {\n  role: ID!\n  isOpen: Boolean!\n}",
    "type R_WindowConnection {\n  edges: [R_WindowEdge!]!\n}",
    "type R_WindowEdge {\n  node: R_Window!\n}",
    "type R_Order {\n  orderId: ID!\n  lines: [R_Line!]!\n}",
    "type R_Line {\n  productId: ID!\n}",
    "union CommandResult = CommandAccepted | CommandRejected",
    "type CommandAccepted {\n  eventCount: Int\n}",
    "type CommandRejected {\n  errorCode: String!\n}",
  ],
  mutations: [
    "R_SignUp(email: String!, role: String): CommandResult!",
    "R_PlaceOrder(orderId: ID!): CommandResult!",
  ],
  queries: [
    "R_Window(id: ID!): R_Window",
    "R_Windows(first: Int, after: String): R_WindowConnection!",
    "R_Order(id: ID!): R_Order",
    "R_Orders(first: Int, after: String): R_OrderConnection!",
  ],
  subscriptions: ["onR_SignUp(id: ID): CommandResult", "onR_PlaceOrder(id: ID): CommandResult"],
  subscriptionSources: [
    {field: "onR_SignUp", mutations: ["R_SignUp"]},
    {field: "onR_PlaceOrder", mutations: ["R_PlaceOrder"]},
  ],
})

let fields = V.fieldsOf(~mutationEntries, ~queryEntries)
let names = (xs: array<string>) => xs->Array.map(Stitcher.extractLeadingName)

describe("AppSync_VisitorSchema", () => {
  testSync("the fields for visitors are those whose rule is AllowAnonymous", () =>
    expect((
      fields.mutations,
      fields.queries->Array.filter(q => q->String.startsWith("R_Order")),
    ))->toEqual((["R_SignUp"], []))
  )

  testSync("a view for visitors goes with every field made from it", () =>
    expect((
      fields.queries->Array.includes("R_Window"),
      fields.queries->Array.includes("R_Windows"),
    ))->toEqual((true, true))
  )

  testSync("the plugin's own schema loses them, and the subscription that announced one", () => {
    let parts = Stitcher.decode(V.without(fragment, fields))
    expect((
      names(parts.mutations),
      names(parts.queries),
      names(parts.subscriptions),
      parts.subscriptionSources->Array.map(s => s.field),
    ))->toEqual((["R_PlaceOrder"], ["R_Order", "R_Orders"], ["onR_PlaceOrder"], ["onR_PlaceOrder"]))
  })

  testSync("the narrow schema has them, with the types they reach and no other", () => {
    let parts = Stitcher.decode(V.only(fragment, fields))
    expect((
      names(parts.mutations),
      names(parts.queries),
      names(parts.types),
      parts.subscriptions,
    ))->toEqual((
      ["R_SignUp"],
      ["R_Window", "R_Windows"],
      [
        "R_Window",
        "R_WindowConnection",
        "R_WindowEdge",
        "CommandResult",
        "CommandAccepted",
        "CommandRejected",
      ],
      [],
    ))
  })

  testSync("its document names no field of the plugin's own, and no directive", () => {
    let sdl = V.sdl(V.only(fragment, fields))
    expect((
      sdl->String.includes("R_SignUp"),
      sdl->String.includes("R_PlaceOrder"),
      sdl->String.includes("R_Line"),
      sdl->String.includes("@aws_"),
    ))->toEqual((true, false, false, false))
  })

  testSync("a plugin with no field for visitors keeps the schema it had", () => {
    let none = V.fieldsOf(
      ~mutationEntries=mutationEntries->Array.slice(~start=1),
      ~queryEntries=queryEntries->Array.slice(~start=1),
    )
    expect((V.isEmpty(none), V.without(fragment, none) == fragment))->toEqual((true, true))
  })
})

describe("the adapter and the narrow API", () => {
  let generated = () => AppSync_Adapter.generateFragment(~mutationEntries, ~queryEntries=[])

  testSync("a deployment that hosts none refuses a field for visitors, as before", () =>
    expect(
      switch generated() {
      | _ => false
      | exception _ => true
      },
    )->toBe(true)
  )

  testSync(
    "one that hosts it keeps the field off the plugin's schema, and says which it is",
    () => {
      AppSync_VisitorApi.host()
      let parts = Stitcher.decode(generated())
      let got = (
        names(parts.mutations)->Array.includes("R_SignUp"),
        AppSync_VisitorApi.fields().mutations,
        AppSync_VisitorApi.servesMutation("R_SignUp"),
        AppSync_VisitorApi.servesMutation("R_PlaceOrder"),
      )
      AppSync_VisitorApi.hostedRef := false
      expect(got)->toEqual((false, ["R_SignUp"], true, false))
    },
  )

  testSync(
    "the key lives a year less a day from the start of the day, so it moves once a day",
    () =>
      expect((
        AppSync_VisitorApi.keyExpiry(Date.fromString("2026-11-22T09:30:00Z")),
        AppSync_VisitorApi.keyExpiry(Date.fromString("2026-11-22T23:59:59Z")),
      ))->toEqual(("2027-11-21T00:00:00Z", "2027-11-21T00:00:00Z")),
  )

  testSync("the narrow API's role may read a view's table and nothing more", () => {
    let policy = AppSync_VisitorView.policy(~id="p", ~tableName="Windows-abc")
    expect((
      policy->String.includes("dynamodb:PutItem") || policy->String.includes(`"dynamodb:*"`),
      policy->String.includes("arn:aws:dynamodb:*:*:table/Windows-abc"),
      AppSync_VisitorView.readActions,
    ))->toEqual((
      false,
      true,
      ["dynamodb:GetItem", "dynamodb:BatchGetItem", "dynamodb:Query", "dynamodb:Scan"],
    ))
  })
})
