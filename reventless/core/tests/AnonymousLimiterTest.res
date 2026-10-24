open JestGlobals

// The limit on doors open to anonymous callers: counted per door and source, in
// fixed windows, and parsed from one setting that refuses rather than guesses.

let clock = () => {
  let at = ref(1_000_000.)
  (() => at.contents, seconds => at := at.contents +. seconds *. 1000.)
}

let limit: Reventless.AnonymousRequestLimit.t = {requests: 2, windowSeconds: 60}

describe("AnonymousLimiter", () => {
  testSync("admits up to the limit, then refuses", () => {
    let (now, _) = clock()
    let l = AnonymousLimiter.make(~limit, ~now)
    let admitted = [
      l.admit(~door="SignUp", ~source="1.2.3.4"),
      l.admit(~door="SignUp", ~source="1.2.3.4"),
      l.admit(~door="SignUp", ~source="1.2.3.4"),
    ]
    expect(admitted)->toEqual([true, true, false])
  })

  testSync("a new window starts the count again", () => {
    let (now, advance) = clock()
    let l = AnonymousLimiter.make(~limit, ~now)
    let _ = l.admit(~door="SignUp", ~source="1.2.3.4")
    let _ = l.admit(~door="SignUp", ~source="1.2.3.4")
    advance(60.)
    expect(l.admit(~door="SignUp", ~source="1.2.3.4"))->toBe(true)
  })

  testSync("sources and doors are counted apart", () => {
    let (now, _) = clock()
    let l = AnonymousLimiter.make(~limit, ~now)
    let _ = l.admit(~door="SignUp", ~source="1.2.3.4")
    let _ = l.admit(~door="SignUp", ~source="1.2.3.4")
    expect((
      l.admit(~door="SignUp", ~source="5.6.7.8"),
      l.admit(~door="CompleteRegistration", ~source="1.2.3.4"),
    ))->toEqual((true, true))
  })
})

describe("AnonymousRequestLimit.parse", () => {
  testSync("reads requests per seconds", () =>
    expect(Reventless.AnonymousRequestLimit.parse(" 5 / 600 "))->toEqual(
      Ok({Reventless.AnonymousRequestLimit.requests: 5, windowSeconds: 600}),
    )
  )

  testSync("refuses anything else rather than defaulting", () => {
    expect(Reventless.AnonymousRequestLimit.parse("5")->Result.isError)->toBe(true)
    expect(Reventless.AnonymousRequestLimit.parse("0/60")->Result.isError)->toBe(true)
    expect(Reventless.AnonymousRequestLimit.parse("lots/hour")->Result.isError)->toBe(true)
  })

  testSync("the default round-trips through its spelling", () =>
    expect(
      Reventless.AnonymousRequestLimit.parse(
        Reventless.AnonymousRequestLimit.default->Reventless.AnonymousRequestLimit.toString,
      ),
    )->toEqual(Ok(Reventless.AnonymousRequestLimit.default))
  )
})
