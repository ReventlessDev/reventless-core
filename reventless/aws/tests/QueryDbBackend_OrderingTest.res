// A read model on DynamoDB orders by its keys; on Postgres by any field. Admin stores stay on
// DynamoDB under a Postgres selection, and order as it does.

open JestGlobals

describe("QueryDbBackend_Ordering.forReadModel", () => {
  testSync("answers Keys while no Postgres selection is recorded", () =>
    expect(QueryDbBackend_Ordering.forReadModel("Orders"))->toEqual(
      ReventlessCore.QueryDb_Ordering.Keys,
    )
  )

  testSync("answers AnyField for an app read model and Keys for an admin store on Postgres", () => {
    // isPostgresFor reads only whether a selection exists.
    QueryDbBackend.set(Obj.magic(Dict.make()))
    QueryDbBackend.exempt(ReventlessCore.PluginsReadModelSpec.name)
    expect((
      QueryDbBackend_Ordering.forReadModel("Orders"),
      QueryDbBackend_Ordering.forReadModel(ReventlessCore.PluginsReadModelSpec.name),
    ))->toEqual((ReventlessCore.QueryDb_Ordering.AnyField, ReventlessCore.QueryDb_Ordering.Keys))
  })
})
