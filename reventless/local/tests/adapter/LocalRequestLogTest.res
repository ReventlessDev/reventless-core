// The line the app's API writes for each GraphQL operation: how it reads, and at which level.

open JestGlobals

let report = (
  ~kind="query",
  ~operationName=?,
  ~fields=["Catalog_Products"],
  ~user=?,
  ~ms=12.,
  ~errors=[],
  (),
): GraphqlYoga.requestReport => {kind, ?operationName, fields, ?user, ms, errors}

let line = r => LocalRequestLog.lineOf(r)

testSync("a query is a debug line naming it, who asked and how long it took", () => {
  let l = line(report(~operationName="Products", ~user="alice", ()))
  expect(l.message)->toBe("query Products by alice in 12 ms")
  expect(l.level == Debug)->toBe(true)
})

testSync("an operation without a name goes by its root fields", () => {
  let l = line(report(~fields=["Catalog_Products", "Catalog_Categories"], ()))
  expect(l.message)->toBe("query Catalog_Products, Catalog_Categories in 12 ms")
})

testSync("a mutation is an info line", () => {
  let l = line(report(~kind="mutation", ~fields=["Catalog_AddProduct"], ~user="bob", ~ms=40., ()))
  expect(l.message)->toBe("mutation Catalog_AddProduct by bob in 40 ms")
  expect(l.level == Info)->toBe(true)
})

testSync("an operation that answered with errors is a warning with the first of them", () => {
  let l = line(
    report(~kind="mutation", ~fields=["Catalog_AddProduct"], ~errors=["Forbidden", "Other"], ()),
  )
  expect(l.message)->toBe("mutation Catalog_AddProduct failed in 12 ms: Forbidden (and 1 more)")
  expect(l.level == Warn)->toBe(true)
})

testSync("a subscription is said when it starts, with no time", () => {
  let l = line(report(~kind="subscription", ~fields=["onOrderChanged"], ~ms=0., ()))
  expect(l.message)->toBe("subscription onOrderChanged")
  expect(l.level == Debug)->toBe(true)
})
