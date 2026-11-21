// A view with a lifecycle trail answers `<trail>Entered` over GraphQL: per state,
// the first and latest visit and how many; and when the row entered its current
// state. Read off the attributes the save derives from the trail.

open JestGlobals

let _ = TestRunner.setup()

@schema
type lifecycle =
  | Placed
  | Shipped
  | Cancelled

@schema
type order = {
  orderId: string,
  lifecycle: lifecycle,
  trail: Reventless.Lifecycle.Trail.t<lifecycle>,
}

let nine = "2026-03-02T09:00:00Z"
let ten = "2026-03-02T10:00:00Z"
let eleven = "2026-03-02T11:00:00Z"

let viewName = "TrailOrders"
let typeName = "Shop_TrailOrder"

let identity: Reventless.Identity.t = {
  ...Reventless.Identity.anonymous,
  userId: "test-user",
  username: "test-user",
  groups: ["User"],
}

let execute = async source =>
  await GraphqlYoga.graphql({
    "schema": DomainGraphQL_Server.composeSchema(),
    "source": source,
    "contextValue": Dict.fromArray([("identity", identity->Obj.magic)])->JSON.Encode.object,
  })

let entry: ReventlessInfra.Api.querySchemaEntry = {
  singleFieldName: typeName,
  listFieldName: typeName ++ "s",
  returnTypeName: typeName,
  stateSchema: orderSchema->S.castToUnknown,
  specName: viewName,
  authorization: None,
  includeIdParam: true,
}

let fragment = () =>
  ReventlessCore.GraphQL_FragmentGenerator.generate(~mutationEntries=[], ~queryEntries=[entry])

let setup = async () => {
  module Bus = LocalBus.Make()
  module Storage = LocalQueryDbStorage.Make(Bus)
  module Resolvers = QueryDbResolvers_GraphQL.Make(Bus)
  module Spec = {
    module Id = Reventless.Id.StringPure
    let name = viewName
    let moduleUrl: string = %raw(`import.meta.url`)
    type state = order
    let stateSchema = orderSchema
    let config = Reventless.ReadModel.config()
    let subIdConfig = None
    type role = Reventless.Role.name
    let authorization: Reventless.Authorization.rule<role> = AllowAuthenticated
    let visibility: Reventless.Visibility.t = Public
  }
  module NoResolvers = ReventlessCore.QueryDb_Adapter.NoResolvers(Storage)
  module Db = ReventlessCore.QueryDb_Builder.Make(Spec, Storage, NoResolvers)

  ReventlessCore.Plugin_Helpers.queryFieldNamesRegistry->Dict.set(
    viewName,
    {
      singleFieldName: typeName,
      listFieldName: typeName ++ "s",
      returnTypeName: typeName,
      pluralTypeName: typeName ++ "s",
      includeIdParam: true,
      connectionSpec: true,
    },
  )
  ReventlessCore.Plugin_Helpers.stateSchemaRegistry->Dict.set(
    viewName,
    orderSchema->S.castToUnknown,
  )
  DomainGraphQL_Server.registerTypes(~sdlTypes=ReventlessCore.GraphQL_Stitcher.relayBaseTypes)
  DomainGraphQL_Server.registerTypes(
    ~sdlTypes=ReventlessCore.GraphQL_Stitcher.decode(fragment()).types,
  )

  let db = Db.make(~api=(), ~apiRole=())
  let ops = await db->ReventlessCore.Component.operations->TestRunner.resolve
  let _: ReventlessCore.QueryDb_Adapter.resolvers = Resolvers.make(
    ~name=viewName,
    ~api=(),
    ~apiRole=(),
    ~dataSourceName=""->Pulumi.Output.make,
    ~indexes=[],
    ~subIdField=None,
    ~idResolverConfigs=[],
    ~idsResolverConfigs=[],
    ~authorization=Reventless.Authorization.AllowAuthenticated,
    ~opts=({}: Pulumi.CustomResourceOptions.t),
  )
  ops
}

describe("a trail's dates over GraphQL", () => {
  beforeEach(() => DomainGraphQL_Server.reset())
  afterAll(() => DomainGraphQL_Server.reset())

  testSync("the view's type carries the dates object, one entry per state", () => {
    let sdl = ReventlessCore.GraphQL_SchemaInspector.inspectFragment(fragment()).sdlPreview
    expect(sdl->String.includes(`trailEntered: ${typeName}TrailEntered`))->toBe(true)
    expect(
      sdl->String.includes(
        `type ${typeName}TrailEntered {\n  placed: ${typeName}TrailVisits\n  shipped: ${typeName}TrailVisits\n  cancelled: ${typeName}TrailVisits\n  current: String\n}`,
      ),
    )->toBe(true)
    expect(
      sdl->String.includes(
        `type ${typeName}TrailVisits {\n  latest: String!\n  first: String!\n  visits: Int!\n}`,
      ),
    )->toBe(true)
    // The stored attributes stay off the API.
    expect(sdl->String.includes("_entered_"))->toBe(false)
  })

  testPromise("a reopened row reads both visits to a state apart", async () => {
    let ops = await setup()
    let _ = await ops.save(
      "o-1",
      {
        orderId: "o-1",
        lifecycle: Placed,
        trail: [
          {state: Placed, at: nine},
          {state: Cancelled, at: ten},
          {state: Placed, at: eleven},
        ],
      },
      Init,
      None,
    )
    let result = await execute(
      `{ ${typeName}(id: "o-1") { trailEntered { placed { latest first visits } cancelled { latest first visits } shipped { visits } current } } }`,
    )
    let entered =
      (result->Obj.magic: JSON.t)
      ->JSON.Decode.object
      ->Option.flatMap(r => r->Dict.get("data"))
      ->Option.flatMap(JSON.Decode.object)
      ->Option.flatMap(d => d->Dict.get(typeName))
      ->Option.flatMap(JSON.Decode.object)
      ->Option.flatMap(o => o->Dict.get("trailEntered"))
    let visits = (latest, first, n) =>
      Dict.fromArray([
        ("latest", JSON.Encode.string(latest)),
        ("first", JSON.Encode.string(first)),
        ("visits", JSON.Encode.int(n)),
      ])->JSON.Encode.object
    expect(entered)->toEqual(
      Some(
        Dict.fromArray([
          ("placed", visits(eleven, nine, 2)),
          ("cancelled", visits(ten, ten, 1)),
          ("shipped", JSON.Encode.null),
          ("current", JSON.Encode.string(eleven)),
        ])->JSON.Encode.object,
      ),
    )
  })
})
