// Counts requests per door and source in fixed windows, in a DynamoDB table: what
// the doors of a deployment need, where each request may reach a different copy
// of the function. The same windows as the in-memory limiter the local platform
// uses, so one configured limit means one thing on both.
//
// One item per door, source and window, counted up by an atomic add and removed
// by the table's expiry once its window has passed. The source is never stored:
// an address is personal data, so the item's key holds a keyed fingerprint of it,
// and nothing here prints either.

let keyAttribute = "id"
let countAttribute = "count"
/** Seconds since the epoch, as DynamoDB's expiry reads it. */
let expiryAttribute = "expiresAt"

/** The one call the limiter makes, so a test stands in for the table. */
type store = {
  /** Adds one to the count under `key`, which stops being kept at `expiresAt`,
      and answers the count after it. */
  increment: (~key: string, ~expiresAt: float) => promise<int>,
}

/** The window `at` (milliseconds) falls in, for windows of `windowSeconds`. */
let windowOf = (~windowSeconds: int, at: float): float =>
  Math.floor(at /. 1000. /. Int.toFloat(windowSeconds))

/** The key a request counts under. */
let keyOf = (~door: string, ~fingerprint: string, ~window: float): string =>
  `${door}#${fingerprint}#${window->Float.toString}`

/**
Whether one more request from `source` reaches `door`.

`fingerprint` turns the source into what is stored, and may refuse: a deployment
with no fingerprint key cannot count without storing addresses, so it admits
nobody. The deploy refuses a door for visitors without a key, so a request does
not get here that way.
*/
let admit = async (
  ~store: store,
  ~limit: Reventless.AnonymousRequestLimit.t,
  ~fingerprint: string => result<string, 'e>,
  ~door: string,
  ~source: string,
  ~now: unit => float=Date.now,
): bool =>
  switch fingerprint(source) {
  | Error(_) => false
  | Ok(fingerprint) =>
    let at = now()
    let window = windowOf(~windowSeconds=limit.windowSeconds, at)
    let count = await store.increment(
      ~key=keyOf(~door, ~fingerprint, ~window),
      // Kept one window past its own end, so a late read never finds it gone early.
      ~expiresAt=(window +. 2.) *. Int.toFloat(limit.windowSeconds),
    )
    count <= limit.requests
  }

/** The table `tableName`, through the document client. */
let dynamoDb = (~tableName: string): store => {
  increment: async (~key, ~expiresAt) => {
    let out = await AwsSdk.DynamoDb_DocumentClient.UpdateCommand.make({
      tableName,
      key: Dict.fromArray([(keyAttribute, JSON.Encode.string(key))]),
      updateExpression: "ADD #count :one SET #expiresAt = :expiresAt",
      expressionAttributeNames: Dict.fromArray([
        ("#count", countAttribute),
        ("#expiresAt", expiryAttribute),
      ]),
      expressionAttributeValues: Dict.fromArray([
        (":one", JSON.Encode.int(1)),
        (":expiresAt", JSON.Encode.float(expiresAt)),
      ]),
      returnValues: #UPDATED_NEW,
    })->AwsSdk.DynamoDb_DocumentClient.UpdateCommand.send
    switch out.attributes->Option.flatMap(a => a->Dict.get(countAttribute)) {
    | Some(Number(n)) => Float.toInt(n)
    // An answer with no count is not one to admit on.
    | _ => Int.Constants.maxValue
    }
  },
}
