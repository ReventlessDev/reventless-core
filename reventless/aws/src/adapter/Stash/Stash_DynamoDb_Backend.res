// A stash over a DynamoDB table: what a deployed platform provisions, since the
// door that puts and the slice that takes run in different functions there.
//
// One item per key: its value and when it stops being handed over. `take` is a
// delete that returns what it removed, so of two takes at once only one gets the
// value. DynamoDB removes an expired item late, sometimes by days, so `take` reads
// the expiry itself and answers `None` past it; the table's own expiry only cleans
// up what nobody took.

let keyAttribute = "id"
let valueAttribute = "value"
/** Seconds since the epoch, as DynamoDB's expiry reads it. */
let expiryAttribute = "expiresAt"

/** The two calls the stash makes, so a test stands in for the table. */
type store = {
  put: (~item: dict<JSON.t>) => promise<unit>,
  /** Removes the item under `key` and answers it as it was, if there was one. */
  remove: (~key: string) => promise<option<dict<JSON.t>>>,
}

let reasonOf = (exn: exn): string =>
  switch exn {
  | JsExn(e) => e->JsExn.message->Option.getOr("the stash did not answer")
  | _ => "the stash did not answer"
  }

/** A stash over `store`. `now` is injected so a test can move time. */
let make = (~store: store, ~now: unit => float=Date.now): Reventless.Stash.t => {
  let seconds = () => Math.floor(now() /. 1000.)
  {
    put: async (~key, ~value, ~ttl) =>
      try {
        await store.put(
          ~item=Dict.fromArray([
            (keyAttribute, JSON.Encode.string(key)),
            (valueAttribute, JSON.Encode.string(value)),
            (expiryAttribute, JSON.Encode.float(seconds() +. Int.toFloat(ttl))),
          ]),
        )
        Ok()
      } catch {
      | exn => Error(Reventless.Stash.Unavailable(reasonOf(exn)))
      },
    take: async (~key) =>
      try {
        let held = await store.remove(~key)
        Ok(
          held->Option.flatMap(item =>
            switch (item->Dict.get(valueAttribute), item->Dict.get(expiryAttribute)) {
            | (Some(String(value)), Some(Number(expiresAt))) if expiresAt > seconds() => Some(value)
            | _ => None
            }
          ),
        )
      } catch {
      | exn => Error(Reventless.Stash.Unavailable(reasonOf(exn)))
      },
  }
}

/** The table `tableName`, through the document client. */
let dynamoDb = (~tableName: string): store => {
  put: async (~item) => {
    let _ = await AwsSdk.DynamoDb_DocumentClient.PutCommand.make({
      tableName,
      item: JSON.Encode.object(item),
    })->AwsSdk.DynamoDb_DocumentClient.PutCommand.send
  },
  remove: async (~key) => {
    let out = await AwsSdk.DynamoDb_DocumentClient.DeleteCommand.make({
      tableName,
      key: Dict.fromArray([(keyAttribute, JSON.Encode.string(key))]),
      returnValues: #ALL_OLD,
    })->AwsSdk.DynamoDb_DocumentClient.DeleteCommand.send
    out.attributes
  },
}

/** The deployment's stash: the table a function is handed, or none where the
    platform it was deployed against provisions no stash, which refuses both
    calls rather than forgetting what it is given. */
let provider = (~tableName: string): Reventless.Stash.t =>
  tableName == ""
    ? Reventless.Stash.unavailable(~reason="no stash is provisioned for this deployment")
    : make(~store=dynamoDb(~tableName))
