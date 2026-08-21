// Behavioural tests for the in-memory cross-table field resolvers
// (`@resolves` / `@resolvesMany`). An Orders view carries a foreign `productId`
// and a `productIds` array; both follow into a Products view's rows.
//
// The rows handed back are the TARGET's, so the target's `@retired` rule narrows
// them — the same reading the AppSync response bakes in. A nested field takes no
// `includeRetired` argument, so a retired row never travels through one.

@@warning("-44")

open JestGlobals

let _ = TestRunner.setup()

@schema
type productRow = {productId: string, name: string, archived: bool}

@schema
type orderRow = {orderId: string, productId: string, productIds: array<string>}

let annotations = (~retired: option<Reventless.StateAnnotations.retiredSpec>) => {
  Reventless.StateAnnotations.ids: [],
  compositeIds: [],
  subIds: [],
  compositeSubIds: [],
  indexes: [],
  hidden: [],
  summary: [],
  drillTargets: [],
  drillTargetKeys: [],
  collapsed: [],
  scan: [],
  scanSort: [],
  semantic: [],
  metric: [],
  lifecycle: None,
  groupBy: None,
  visibility: None,
  live: None,
  retired,
}

let ctxFor = (~groups: array<string>): JSON.t =>
  JSON.Encode.object(
    Dict.fromArray([
      (
        "request",
        JSON.Encode.object(Dict.fromArray([("headers", JSON.Encode.object(Dict.make()))])),
      ),
      (
        "identity",
        (
          {
            ...Reventless.Identity.anonymous,
            userId: "test-user",
            username: "test-user",
            groups,
          }: Reventless.Identity.t
        )->Obj.magic,
      ),
    ]),
  )

let plainCtx = ctxFor(~groups=["User"])

let noArgs: JSON.t = JSON.Encode.object(Dict.make())

let getString = (json: JSON.t, key: string): option<string> =>
  json->JSON.Decode.object->Option.flatMap(d => d->Dict.get(key))->Option.flatMap(JSON.Decode.string)

let names = (json: JSON.t): array<string> =>
  json->JSON.Decode.array->Option.getOr([])->Array.filterMap(item => item->getString("name"))

// One Bus carrying both views, resolvers registered for the Orders view with the
// two configs the PPX writes from `@resolves` / `@resolvesMany`.
let buildFixture = async (~suffix: string, ~retired: option<Reventless.StateAnnotations.retiredSpec>) => {
  module Bus = LocalBus.Make()
  module Storage = LocalQueryDbStorage.Make(Bus)
  module Resolvers = QueryDbResolvers_GraphQL.Make(Bus)

  let productsName = "Products" ++ suffix
  let ordersName = "Orders" ++ suffix
  let orderTypeName = "Shop_Order" ++ suffix

  module ProductsSpec = {
    module Id = Reventless.Id.StringPure
    let name = productsName
    let moduleUrl: string = %raw(`import.meta.url`)
    @schema
    type state = productRow
    let config = Reventless.ReadModel.config()
    let subIdConfig = None
    let authorization: Reventless.Authorization.permission = AllowAuthenticated
    let visibility: Reventless.Visibility.t = Public
  }

  module OrdersSpec = {
    module Id = Reventless.Id.StringPure
    let name = ordersName
    let moduleUrl: string = %raw(`import.meta.url`)
    @schema
    type state = orderRow
    let config = Reventless.ReadModel.config(
      ~idResolvers=[
        {
          source: {
            Reventless.ReadModel.idField: "productId",
            subId: NoSubId,
            resolvedField: Single("product"),
          },
          target: {Reventless.ReadModel.tableName: productsName, idField: Id},
        },
      ],
      ~idsResolvers=[
        {
          source: {Reventless.ReadModel.idsField: "productIds", resolvedField: "products"},
          target: {Reventless.ReadModel.tableName: productsName},
        },
      ],
    )
    let subIdConfig = None
    let authorization: Reventless.Authorization.permission = AllowAuthenticated
    let visibility: Reventless.Visibility.t = Public
  }

  module NoResolvers = ReventlessCore.QueryDb_Adapter.NoResolvers(Storage)
  module ProductsDb = ReventlessCore.QueryDb_Builder.Make(ProductsSpec, Storage, NoResolvers)
  module OrdersDb = ReventlessCore.QueryDb_Builder.Make(OrdersSpec, Storage, NoResolvers)

  let register = (~viewName, ~returnTypeName) =>
    ReventlessCore.Plugin_Helpers.queryFieldNamesRegistry->Dict.set(
      viewName,
      {
        singleFieldName: returnTypeName,
        listFieldName: returnTypeName ++ "s",
        returnTypeName,
        pluralTypeName: returnTypeName ++ "s",
        includeIdParam: true,
        connectionSpec: true,
      },
    )
  register(~viewName=productsName, ~returnTypeName="Shop_Product" ++ suffix)
  register(~viewName=ordersName, ~returnTypeName=orderTypeName)
  ReventlessCore.Plugin_Helpers.stateSchemaRegistry->Dict.set(
    productsName,
    productRowSchema
    ->S.Metadata.set(
      ~id=Reventless.StateAnnotations.stateAnnotationsId,
      annotations(~retired),
    )
    ->S.castToUnknown,
  )

  let productsDb = ProductsDb.make(~api=(), ~apiRole=())
  let productOps = await productsDb->ReventlessCore.Component.operations->TestRunner.resolve
  let ordersDb = OrdersDb.make(~api=(), ~apiRole=())
  let orderOps = await ordersDb->ReventlessCore.Component.operations->TestRunner.resolve

  let _: ReventlessCore.QueryDb_Adapter.resolvers = Resolvers.make(
    ~name=ordersName,
    ~api=(),
    ~apiRole=(),
    ~dataSourceName=""->Pulumi.Output.make,
    ~indexes=[],
    ~subIdField=None,
    ~idResolverConfigs=OrdersSpec.config.idResolvers,
    ~idsResolverConfigs=OrdersSpec.config.idsResolvers,
    ~authorization=Reventless.Authorization.AllowAuthenticated,
    ~opts=({}: Pulumi.CustomResourceOptions.t),
  )

  let _ = await productOps.save("p-1", {productId: "p-1", name: "Book", archived: false}, Init, None)
  let _ = await productOps.save("p-2", {productId: "p-2", name: "Pen", archived: true}, Init, None)
  let _ = await orderOps.save(
    "o-1",
    {orderId: "o-1", productId: "p-1", productIds: ["p-1", "gone", "p-2"]},
    Init,
    None,
  )

  let resolverFor = field =>
    switch DomainGraphQL_Server.getFieldResolver(~typeName=orderTypeName, field) {
    | Some(r) => r
    | None => JsError.throwWithMessage("field resolver not registered: " ++ field)
    }

  let order = JSON.Encode.object(
    Dict.fromArray([
      ("orderId", JSON.Encode.string("o-1")),
      ("productId", JSON.Encode.string("p-1")),
      (
        "productIds",
        ["p-1", "gone", "p-2"]->Array.map(JSON.Encode.string)->JSON.Encode.array,
      ),
    ]),
  )

  (resolverFor, order)
}

describe("QueryDb cross-table field resolvers", () => {
  beforeEach(() => {
    DomainGraphQL_Server.reset()
  })

  testPromise("@resolves follows the foreign key into the target's row", async () => {
    let (resolverFor, order) = await buildFixture(~suffix="A", ~retired=None)
    let product = await resolverFor("product")(order, noArgs, plainCtx)
    expect((product->getString("name"), product->getString("id")))->toEqual((
      Some("Book"),
      Some("p-1"),
    ))
  })

  testPromise("@resolvesMany batch-follows the id array", async () => {
    let (resolverFor, order) = await buildFixture(~suffix="B", ~retired=None)
    let products = await resolverFor("products")(order, noArgs, plainCtx)
    // "gone" names no row and drops out rather than becoming a null, matching
    // BatchGetItem and the by-ids door built on it.
    expect(products->names)->toEqual(["Book", "Pen"])
  })

  testPromise("a foreign key naming no row resolves to nothing", async () => {
    let (resolverFor, _) = await buildFixture(~suffix="C", ~retired=None)
    let orphan = JSON.Encode.object(
      Dict.fromArray([("productId", JSON.Encode.string("nope"))]),
    )
    let product = await resolverFor("product")(orphan, noArgs, plainCtx)
    expect(product)->toBe(JSON.Encode.null)
  })

  // The narrowing is the target's: Products declares the retirement, Orders
  // declares the field, and the caller reading through Orders is answered by
  // the Products rule.
  testPromise("a retired target row is withheld from both forms", async () => {
    let retired: Reventless.StateAnnotations.retiredSpec = {
      field: "archived",
      label: "",
      showWhenFalse: false,
      values: None,
      namedWhenRetired: false,
    }
    let (resolverFor, order) = await buildFixture(~suffix="D", ~retired=Some(retired))
    let products = await resolverFor("products")(order, noArgs, plainCtx)
    expect(products->names)->toEqual(["Book"])

    let archivedOnly = JSON.Encode.object(
      Dict.fromArray([("productId", JSON.Encode.string("p-2"))]),
    )
    let product = await resolverFor("product")(archivedOnly, noArgs, plainCtx)
    expect(product)->toBe(JSON.Encode.null)
  })
})
