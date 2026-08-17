// The DynamoDB backend narrows retirement on every door the rule names, not
// only on the list.
//
// These assert the *generated resolver source*, which is the only artifact that
// exists before a deploy: the predicate runs inside AppSync's JS runtime, so a
// unit test cannot execute it against a table, and what can be checked here is
// that each door carries the guard, in the half of the template its operation
// allows, and that a view declaring no retirement is untouched.

open JestGlobals

open PulumiAws.AppSync
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
