// The local platform's read models live in memory or in SQLite, and both order by any field.

open JestGlobals

describe("QueryDbBackend_Ordering.forBackend", () => {
  testSync("answers AnyField for the in-memory and the SQLite store", () =>
    expect((
      QueryDbBackend_Ordering.forBackend(Memory),
      QueryDbBackend_Ordering.forBackend(Sqlite({path: ":memory:", resetOnStart: false})),
    ))->toEqual((
      ReventlessCore.QueryDb_Ordering.AnyField,
      ReventlessCore.QueryDb_Ordering.AnyField,
    ))
  )
})
