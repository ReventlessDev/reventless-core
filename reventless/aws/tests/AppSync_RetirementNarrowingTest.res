// The DynamoDB backend narrows retirement on every door the rule names, not only
// on the list. These assert the generated resolver source — the only artifact
// that exists before a deploy — for the guard, the half of the template its
// operation allows, and a view declaring no retirement staying untouched.

open JestGlobals

module F = AppSync_Resolver_Retrying.Functions

// The templates are `Pulumi.Input.t<string>` — a string at rest, wrapped for the
// provider. Read it back as one so the assertions can be about text.
external asString: Pulumi.Input.t<string> => string = "%identity"

let elevated = ["Admin"]

// A product view: retired by two states of its lifecycle, unowned.
let shelf = (~includeOwner: bool) =>
  F.getItemById(
    ~ownerField=?includeOwner ? Some("customerId") : None,
    ~elevatedGroups=elevated,
    ~retiredField="shelfStatus",
    ~retiredValues=["Archived", "Discontinued"],
  )->asString

describe("the single-entity door", () => {
  testSync("withholds a retired row until an exempt caller asks", () => {
    let code = shelf(~includeOwner=false)
    expect(code->String.includes("const _wantsRetired = _exempt && ctx.args.includeRetired === true"))
    ->Expect.toBe(true)
    expect(code->String.includes("_live(ctx.result) ? ctx.result : null"))->Expect.toBe(true)
  })

  // Absent attribute keeps the row: a row written before the annotation existed
  // is not retired, which is what stops a view emptying the day it lands.
  testSync("reads a missing attribute as not retired", () =>
    expect(shelf(~includeOwner=false)->String.includes("row['shelfStatus'] == null"))->Expect.toBe(true)
  )

  testSync("tests membership of the retiring states, not equality with one", () =>
    expect(
      shelf(~includeOwner=false)->String.includes(
        "['Archived', 'Discontinued'].indexOf(row['shelfStatus']) >= 0",
      ),
    )->Expect.toBe(true)
  )

  // Two `const _exempt` in one function body is a syntax error, so the owner
  // preamble's copy is the only one when both guards are present.
  testSync("declares the exemption test once when owner scoping is also on", () => {
    let code = shelf(~includeOwner=true)
    let occurrences =
      code->String.split("const _exempt =")->Array.length - 1
    expect((occurrences, code->String.includes("_owns(ctx.result) && _live(ctx.result)")))
    ->Expect.toEqual((1, true))
  })

  testSync("is unchanged for a view that declares no retirement", () => {
    let code = F.getItemById(~elevatedGroups=elevated)->asString
    expect((code->String.includes("_wantsRetired"), code->String.includes("includeRetired")))
    ->Expect.toEqual((false, false))
  })
})

describe("the by-ids door", () => {
  let code = F.batchGetItemsByIds(
    ~retiredField="shelfStatus",
    ~retiredValues=["Archived"],
    ~elevatedGroups=elevated,
  )("ProductsTable")

  // BatchGetItem has no FilterExpression, so the predicate is a filter over what
  // came back — beside the null-drop the non-null list type already needs.
  testSync("drops retired rows from the returned array", () =>
    expect(code->String.includes("item !== null && _live(item)"))->Expect.toBe(true)
  )

  testSync("still names the table it batches against", () =>
    expect(code->String.includes("ctx.result?.data?.['ProductsTable']"))->Expect.toBe(true)
  )

  testSync("is unchanged for a view that declares no retirement", () =>
    expect(F.batchGetItemsByIds()("ProductsTable")->String.includes("_live"))
    ->Expect.toBe(false)
  )
})

describe("the by-index door", () => {
  let code = F.queryByIndexFiltered(
    ~index="byCategory",
    ~idField="categoryId",
    ~retiredField="shelfStatus",
    ~retiredValues=["Archived", "Discontinued"],
    ~elevatedGroups=elevated,
  )->asString

  // A Query takes a FilterExpression, so the predicate is pushed into the read.
  // Narrowing after it would hand back fewer rows than `limit` asked for and say
  // nothing about why.
  testSync("pushes the predicate into the FilterExpression", () => {
    expect(code->String.includes("names['#retired'] = 'shelfStatus'"))->Expect.toBe(true)
    expect(
      code->String.includes(
        "attribute_not_exists(#retired) OR (#retired <> :retiredValue0 AND #retired <> :retiredValue1)",
      ),
    )->Expect.toBe(true)
  })

  // It composes with the caller's own filter arguments rather than replacing them.
  testSync("ANDs onto an expression the caller may already have built", () =>
    expect(code->String.includes("if (expression) expression += ' AND '"))->Expect.toBe(true)
  )

  testSync("is unchanged for a view that declares no retirement", () =>
    expect(
      F.queryByIndexFiltered(~index="byCategory", ~idField="categoryId")
      ->asString
      ->String.includes("#retired"),
    )->Expect.toBe(false)
  )
})

describe("the boolean form", () => {
  testSync("tests the flag rather than a set of states", () => {
    let code =
      F.getItemById(~elevatedGroups=elevated, ~retiredField="archived")->asString
    expect((
      code->String.includes("row['archived'] === true"),
      code->String.includes("indexOf(row["),
    ))->Expect.toEqual((true, false))
  })
})

// ── Ownership, on the two doors that never had it ────────────────────────────

describe("the by-ids door's owner scoping", () => {
  let code = F.batchGetItemsByIds(
    ~ownerField="customerId",
    ~retiredField="shelfStatus",
    ~retiredValues=["Archived"],
    ~elevatedGroups=elevated,
  )("Orders")

  // Dropped from the array rather than refused, for the reason the single-key
  // door answers null: telling "not yours" apart from "not there" makes the door
  // an oracle for which ids exist.
  testSync("drops a row the caller does not own", () =>
    expect(code->String.includes("item !== null && _owns(item) && _live(item)"))->Expect.toBe(true)
  )

  testSync("declares the exemption test once, shared with the retirement guard", () =>
    expect(code->String.split("const _exempt =")->Array.length - 1)->Expect.toBe(1)
  )

  testSync("is unchanged for a view with neither rule", () => {
    let plain = F.batchGetItemsByIds()("Orders")
    expect((plain->String.includes("_owns"), plain->String.includes("_live")))
    ->Expect.toEqual((false, false))
  })
})

describe("the by-index door's owner scoping", () => {
  let code = F.queryByIndexFiltered(
    ~index="byCategory",
    ~idField="categoryId",
    ~ownerField="customerId",
    ~elevatedGroups=elevated,
  )->asString

  testSync("pushes the owner predicate into the read", () =>
    expect(code->String.includes("names['#owner'] = 'customerId'"))->Expect.toBe(true)
  )

  // The predicate must not be readable off the arguments: a rule about what the
  // caller may see cannot arrive on a channel the caller controls.
  testSync("reads the owner from the identity, never from ctx.args", () =>
    expect(code->String.includes("values[':owner'] = _osub"))->Expect.toBe(true)
  )

  testSync("exempts an elevated caller and an IAM service call", () =>
    expect(
      code->String.includes("if (!(_osub == null || _ogroups.some(g => _oelevated.indexOf(g) >= 0)))"),
    )->Expect.toBe(true)
  )

  // The generic argument loop turns an unrecognised arg into a `contains` filter.
  // `includeRetired` is a request to lift a restriction, and filtering on it
  // would match no row at all.
  testSync("never treats includeRetired as a column to match on", () =>
    expect(code->String.includes("key === 'includeRetired'"))->Expect.toBe(true)
  )
})

// The by-index door was, until this landed, unreachable rather than merely
// un-widenable: the SDL declared `id` while the template below read the index
// key, and the template answered with DynamoDB's `{items, nextToken}` against a
// field that promised a Connection. These assert the two halves that were wrong,
// beside the paging arguments the field actually offers.
describe("the by-index door answers the field it is attached to", () => {
  let code =
    F.queryByIndexFiltered(~index="byCategory", ~idField="categoryId")->asString

  testSync("keys the read on the index column the SDL offers", () =>
    expect(code->String.includes("util.dynamodb.toDynamoDB(args.categoryId)"))->Expect.toBe(true)
  )

  testSync("returns a Relay connection, not the raw DynamoDB result", () =>
    expect((
      code->String.includes("edges,"),
      code->String.includes("hasNextPage: _more || !!_next"),
      code->String.includes("return ctx.result;"),
    ))->Expect.toEqual((true, true, false))
  )

  // `first`/`after` are what the field declares; `limit`/`nextToken` were what
  // the template read, and nothing translated between the two. `limit` counts
  // rows examined, so a filtered read looks wider than the page it serves.
  testSync("pages on the Relay arguments the field declares", () =>
    expect((
      code->String.includes("const _first = args.first ?? 50;"),
      code->String.includes("expression ? (_first > 1000 ? _first : 1000)"),
      code->String.includes("util.base64Decode(args.after)"),
    ))->Expect.toEqual((true, true, true))
  )

  // Every declared argument has a job other than matching a column, so each one
  // reaching the generic filter loop would filter on an attribute no row has.
  testSync("keeps every paging argument out of the filter loop", () =>
    expect(
      ["first", "after", "last", "before", "includeRetired"]->Array.every(arg =>
        code->String.includes(`key === '${arg}'`)
      ),
    )->Expect.toBe(true)
  )
})

// Backward paging is refused rather than ignored. The cursor is DynamoDB's own
// continuation token, which walks one way, so `last: 2` could only ever be
// answered with the first two rows — a different question, answered silently.
// `listAllItemsConnection` set this rule; the local backend refuses with the
// same sentence, so the door reads the same either side of a deploy.
describe("the by-index door's backward paging", () => {
  let refusal = "Backward pagination (last/before) is not supported on by-index connections"

  testSync("refuses last/before on the plain index read", () =>
    expect(
      F.queryByIndexFiltered(~index="byCategory", ~idField="categoryId")
      ->asString
      ->String.includes(refusal),
    )->Expect.toBe(true)
  )

  testSync("refuses them on the sort-key index read too", () =>
    expect(
      F.queryByIndexSortFiltered(~index="byCustomer", ~idField="customerId", ~sortField="placedAt")
      ->asString
      ->String.includes(refusal),
    )->Expect.toBe(true)
  )

  // Before the key condition is built, so a refused request never reaches the
  // read — and `util.error` is what AppSync returns to the caller as the field
  // error, rather than an empty page that looks like an answer.
  testSync("refuses before doing any work, and says so to the caller", () => {
    let code = F.queryByIndexFiltered(~index="byCategory", ~idField="categoryId")->asString
    let guardAt = code->String.indexOf("args.before != null")
    let queryAt = code->String.indexOf("expressionValues")
    expect((guardAt >= 0 && guardAt < queryAt, code->String.includes("'UnsupportedPagination'")))
    ->Expect.toEqual((true, true))
  })
})

// APPSYNC_JS is type-checked, so the emitted source has to type-check as well as
// read correctly. The stub a door emits when a view declares no `@owner` is
// still *called* with the row on the doors that narrow retirement, and a
// zero-parameter `() => true` makes that call TS2554 — which AppSync reports at
// create time as "The code contains one or more errors", failing the deploy on
// a resolver whose text looks perfectly reasonable.
describe("the unowned stub is callable where the door calls it", () => {
  // Retirement without an owner is the combination that emits the stub and then
  // calls it: with neither rule the guard is not emitted at all, and with an
  // owner the real one-parameter test replaces it.
  testSync("declares a parameter on the single-entity door", () => {
    let code =
      F.ownerScopedResultResponse(
        ~ownerField=None,
        ~elevatedGroups=elevated,
        ~retiredField="lifecycle",
        ~retiredValues=["Archived"],
      )
    expect((
      code->String.includes("const _owns = (row) => true;"),
      code->String.includes("const _owns = () => true;"),
    ))->Expect.toEqual((true, false))
  })

  testSync("declares a parameter on the reference door", () => {
    let code = F.refsByIds(
      ~labelField="name",
      ~retiredField=None,
      ~retiredValues=None,
      ~namedWhenRetired=false,
    )("Products")
    expect((
      code->String.includes("const _owns = (row) => true;"),
      code->String.includes("_owns(row)"),
    ))->Expect.toEqual((true, true))
  })
})

// ── The cross-table doors (`@resolves` / `@resolvesMany`) ────────────────────
//
// A field that follows a foreign key hands back the TARGET's rows, so the
// target's rules narrow them. The field takes no `includeRetired` argument, so
// `_wantsRetired` is never true through one — `{list}Refs` is the door that
// names a row the archive took.

describe("the cross-table batch door", () => {
  let code = F.resolveIds(
    ~idsField="productIds",
    ~sortField=None,
    ~retiredField="shelfStatus",
    ~retiredValues=["Archived"],
    ~elevatedGroups=elevated,
  )("ProductsTable")

  // BatchGetItem answers `{data: {<table>: [...]}}`; returning `ctx.result`
  // handed the whole envelope to a field typed as a list, which fails at
  // execution for every caller that selects it.
  testSync("returns the rows out of the batch envelope", () =>
    expect(code->String.includes("ctx.result?.data?.['ProductsTable']"))->Expect.toBe(true)
  )

  testSync("drops retired rows from the returned array", () =>
    expect(code->String.includes("item !== null && _live(item)"))->Expect.toBe(true)
  )

  // An empty id array used to fall through to a GetItem on the PARENT's own id
  // against the target's table — a read that answers a shape the field cannot be.
  testSync("short-circuits an empty id array instead of reading", () =>
    expect((
      code->String.includes("if (idList.length === 0) return runtime.earlyReturn([]);"),
      code->String.includes("operation: 'GetItem'"),
    ))->toEqual((true, false))
  )

  testSync("is unchanged for a target that declares neither rule", () => {
    let plain = F.resolveIds(~idsField="productIds", ~sortField=None)("ProductsTable")
    expect((plain->String.includes("_owns"), plain->String.includes("_live")))->toEqual((
      false,
      false,
    ))
  })
})

describe("the cross-table single door", () => {
  let response = (~multi) =>
    F.resolvedFieldResponse(
      ~multi,
      ~ownerField=Some("customerId"),
      ~elevatedGroups=elevated,
      ~retiredField="shelfStatus",
      ~retiredValues=["Archived"],
    )

  testSync("narrows the one row it hands back", () =>
    expect(response(~multi=false)->String.includes("_owns(_row) && _live(_row) ? _row : null"))
    ->Expect.toBe(true)
  )

  testSync("narrows every row of the list form", () =>
    expect(
      response(~multi=true)->String.includes("filter(_row => _owns(_row) && _live(_row))"),
    )->Expect.toBe(true)
  )

  // The list form used to answer with the first row alone, whatever the SDL said.
  testSync("the list form returns the list", () =>
    expect(response(~multi=true)->String.includes("ctx.result.items[0]"))->Expect.toBe(false)
  )

  testSync("a target with neither rule keeps the plain response", () => {
    let plain = F.resolvedFieldResponse(~multi=false, ~ownerField=None, ~elevatedGroups=elevated)
    expect((plain->String.includes("_owns"), plain->String.includes("ctx.result.items[0]")))
    ->toEqual((false, true))
  })
})
