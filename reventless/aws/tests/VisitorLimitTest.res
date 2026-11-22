// The limit on the narrow API for visitors: requests are counted per door, source
// and window, under a fingerprint of the source and never the address; past the
// limit a door answers Throttled; and the firewall's ceiling sits well above it.

open JestGlobals

module L = AnonymousLimiter_DynamoDb

/** A table in memory that remembers every key it was asked to count under. */
let table = () => {
  let counts: dict<int> = Dict.make()
  let expiries: dict<float> = Dict.make()
  let store: L.store = {
    increment: async (~key, ~expiresAt) => {
      let next = counts->Dict.get(key)->Option.getOr(0) + 1
      counts->Dict.set(key, next)
      expiries->Dict.set(key, expiresAt)
      next
    },
  }
  (store, counts, expiries)
}

let limit: Reventless.AnonymousRequestLimit.t = {requests: 2, windowSeconds: 600}
let fingerprint = source => Ok(`fp(${source->String.length->Int.toString})`)

describe("AnonymousLimiter_DynamoDb", () => {
  testPromise("admits up to the limit per door and source, then no more", async () => {
    let (store, _, _) = table()
    let ask = (~door, ~source) =>
      L.admit(
        ~store,
        ~limit,
        ~fingerprint=s => Ok(`fp:${s}`),
        ~door,
        ~source,
        ~now=() => 1_000_000.,
      )
    let first = await ask(~door="SignUp", ~source="203.0.113.7")
    let second = await ask(~door="SignUp", ~source="203.0.113.7")
    let third = await ask(~door="SignUp", ~source="203.0.113.7")
    let otherDoor = await ask(~door="Complete", ~source="203.0.113.7")
    let otherSource = await ask(~door="SignUp", ~source="198.51.100.9")
    expect((first, second, third, otherDoor, otherSource))->toEqual((true, true, false, true, true))
  })

  testPromise("a new window starts the count again", async () => {
    let (store, _, _) = table()
    let clock = ref(1_000_000.)
    let ask = () =>
      L.admit(~store, ~limit, ~fingerprint, ~door="SignUp", ~source="s", ~now=() => clock.contents)
    let _ = await ask()
    let _ = await ask()
    let spent = await ask()
    clock := 1_000_000. +. 600_000.
    let again = await ask()
    expect((spent, again))->toEqual((false, true))
  })

  testPromise("the address is never a key, and a count is kept two windows at most", async () => {
    let (store, counts, expiries) = table()
    let _ = await L.admit(
      ~store,
      ~limit,
      ~fingerprint,
      ~door="SignUp",
      ~source="203.0.113.7",
      ~now=() => 1_200_000.,
    )
    let keys = counts->Dict.keysToArray
    expect((
      keys,
      keys->Array.some(k => k->String.includes("203.0.113.7")),
      expiries->Dict.valuesToArray,
    ))->toEqual((["SignUp#fp(11)#2"], false, [2400.]))
  })

  testPromise(
    "with no fingerprint to store under, nobody is admitted and nothing is kept",
    async () => {
      let (store, counts, _) = table()
      let admitted = await L.admit(
        ~store,
        ~limit,
        ~fingerprint=_ => Error("no fingerprint key"),
        ~door="SignUp",
        ~source="203.0.113.7",
      )
      expect((admitted, counts->Dict.keysToArray))->toEqual((false, []))
    },
  )
})

describe("the function's limit on a visitor's request", () => {
  testSync("the caller's address is the first the API was forwarded", () =>
    expect([
      VisitorLimit_Ops.sourceOf(Nullable.make("203.0.113.7, 130.176.0.1")),
      VisitorLimit_Ops.sourceOf(Nullable.make(" 203.0.113.7 ")),
      VisitorLimit_Ops.sourceOf(Nullable.make("")),
      VisitorLimit_Ops.sourceOf(Nullable.null),
    ])->toEqual(["203.0.113.7", "203.0.113.7", "unknown", "unknown"])
  )

  testPromise("a function handed no count table admits nobody", async () => {
    let before = NodeProcess.env->Dict.get(VisitorLimit_Ops.tableVariable)
    NodeProcess.env->Dict.delete(VisitorLimit_Ops.tableVariable)
    let admitted = await VisitorLimit_Ops.admits("SignUp", Nullable.make("203.0.113.7"))
    before->Option.forEach(v => NodeProcess.env->Dict.set(VisitorLimit_Ops.tableVariable, v))
    expect(admitted)->toBe(false)
  })

  testSync("past the limit a door answers the rejection the local platform gives", () => {
    let field = (j: JSON.t, k) =>
      switch j {
      | Object(d) => d->Dict.get(k)
      | _ => None
      }
    let answer = VisitorLimit_Ops.throttled("Registration_SignUp")
    expect((field(answer, "__typename"), field(answer, "errorCode")))->toEqual((
      Some(JSON.String("CommandRejected")),
      Some(JSON.String("Throttled")),
    ))
  })
})

describe("the narrow API's limit, as deployed", () => {
  testSync("the firewall's ceiling is ten times the limit, and never under a hundred", () =>
    expect([
      AppSync_VisitorLimit.ceiling(Reventless.AnonymousRequestLimit.default),
      AppSync_VisitorLimit.ceiling({requests: 50, windowSeconds: 60}),
    ])->toEqual([100, 500])
  )

  testSync("its rule blocks per source address, and keeps no sample of requests", () => {
    let rule = JSON.stringify(AppSync_VisitorLimit.rateRule(~name="R", ~ceiling=100))
    expect((
      rule->String.includes(`"aggregateKeyType":"IP"`),
      rule->String.includes(`"limit":100`),
      rule->String.includes(`"block":{}`),
      rule->String.includes(`"sampledRequestsEnabled":false`),
    ))->toEqual((true, true, true, true))
  })

  testSync("the function may only count, on the one table", () => {
    let policy = AppSync_VisitorLimit.policy(
      ~id="p",
      "arn:aws:dynamodb:eu-west-1:1:table/VisitorLimit",
    )
    expect((
      AppSync_VisitorLimit.actions,
      policy->String.includes(`table/VisitorLimit"`),
    ))->toEqual((["dynamodb:UpdateItem"], true))
  })
})
