// The deployed stash: a value is handed over once, an item DynamoDB has not yet
// removed after its time reads as gone, and a function is granted the two calls
// the stash makes on the one table.

open JestGlobals

/** A table in memory: `remove` answers what it deleted, as DynamoDB's delete does. */
let table = () => {
  let items: dict<dict<JSON.t>> = Dict.make()
  let store: Stash_DynamoDb_Backend.store = {
    put: async (~item) =>
      switch item->Dict.get(Stash_DynamoDb_Backend.keyAttribute) {
      | Some(String(key)) => items->Dict.set(key, item)
      | _ => ()
      },
    remove: async (~key) => {
      let held = items->Dict.get(key)
      items->Dict.delete(key)
      held
    },
  }
  (store, items)
}

let failing: Stash_DynamoDb_Backend.store = {
  put: async (~item as _) => JsError.throwWithMessage("AccessDenied"),
  remove: async (~key as _) => JsError.throwWithMessage("AccessDenied"),
}

describe("Stash_DynamoDb_Backend", () => {
  testPromise("a value is held with its expiry, in seconds", async () => {
    let (store, items) = table()
    let stash = Stash_DynamoDb_Backend.make(~store, ~now=() => 1_000_000.)
    let put = await stash.put(~key="k", ~value="secret", ~ttl=600)
    expect((put, items->Dict.get("k")))->toEqual((
      Ok(),
      Some(
        Dict.fromArray([
          ("id", JSON.String("k")),
          ("value", JSON.String("secret")),
          ("expiresAt", JSON.Number(1600.)),
        ]),
      ),
    ))
  })

  testPromise("a value is handed over once, to one of two takes", async () => {
    let (store, _) = table()
    let stash = Stash_DynamoDb_Backend.make(~store, ~now=() => 1_000_000.)
    let _ = await stash.put(~key="k", ~value="secret", ~ttl=600)
    let (first, second) = await Promise.all2((stash.take(~key="k"), stash.take(~key="k")))
    let third = await stash.take(~key="k")
    let got = [first, second]->Array.filter(r => r == Ok(Some("secret")))->Array.length
    let none = [first, second]->Array.filter(r => r == Ok(None))->Array.length
    expect((got, none, third))->toEqual((1, 1, Ok(None)))
  })

  testPromise("past its time a value reads as gone, though the table still held it", async () => {
    let (store, items) = table()
    let clock = ref(1_000_000.)
    let stash = Stash_DynamoDb_Backend.make(~store, ~now=() => clock.contents)
    let _ = await stash.put(~key="k", ~value="secret", ~ttl=600)
    clock := 1_600_000.
    let held = items->Dict.get("k")->Option.isSome
    let taken = await stash.take(~key="k")
    expect((held, taken, items->Dict.get("k")))->toEqual((true, Ok(None), None))
  })

  testPromise("a table that does not answer is said, not read as nothing held", async () => {
    let stash = Stash_DynamoDb_Backend.make(~store=failing)
    let put = await stash.put(~key="k", ~value="v", ~ttl=60)
    let take = await stash.take(~key="k")
    expect((put, take))->toEqual((
      Error(Reventless.Stash.Unavailable("AccessDenied")),
      Error(Reventless.Stash.Unavailable("AccessDenied")),
    ))
  })

  testPromise("a deployment with no stash table refuses both calls", async () => {
    let stash = Stash_DynamoDb_Backend.provider(~tableName="")
    let put = await stash.put(~key="k", ~value="v", ~ttl=60)
    let take = await stash.take(~key="k")
    expect((put->Result.isError, take->Result.isError))->toEqual((true, true))
  })
})

describe("the stash's grant", () => {
  testSync("allows the two calls the stash makes, on the one table", () => {
    let policy = JSON.parseOrThrow(
      Stash_DynamoDb_Grant.policy(~id="p", "arn:aws:dynamodb:eu-west-1:1:table/Stash"),
    )
    let statements = switch policy {
    | Object(d) =>
      switch d->Dict.get("Statement") {
      | Some(Array(xs)) => xs
      | _ => []
      }
    | _ => []
    }
    let field = (j: JSON.t, k) =>
      switch j {
      | Object(d) => d->Dict.get(k)
      | _ => None
      }
    expect(statements->Array.map(s => (field(s, "Action"), field(s, "Resource"))))->toEqual([
      (
        Some(JSON.Array([JSON.String("dynamodb:PutItem"), JSON.String("dynamodb:DeleteItem")])),
        Some(JSON.String("arn:aws:dynamodb:eu-west-1:1:table/Stash")),
      ),
    ])
  })

  testSync("what a door is handed: a stash only where a table is named, and a closed start", () => {
    let before = NodeProcess.env->Dict.get("STASH_TABLE")
    NodeProcess.env->Dict.delete("STASH_TABLE")
    let handed = DoorCapabilities.capabilities()
    before->Option.forEach(v => NodeProcess.env->Dict.set("STASH_TABLE", v))
    expect((handed.selfRegistrationInitially, handed.messaging.channels))->toEqual((
      Reventless.Admission.InitiallyClosed,
      [],
    ))
  })
})
