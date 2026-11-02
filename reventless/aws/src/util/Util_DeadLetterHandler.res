// The dead-letter function's handler. `Util_DeadLetterQueue` ships this module's compiled file
// as the function's whole code, so it must compile to a file that imports nothing: it keeps
// working when the layer or the handlers of a deploy are broken, which is when dead letters
// arrive. So only the Stdlib's externals (which compile inline) and plain switches here: no
// Stdlib function such as `Option.getOr`, which compiles to an import, and no `try`, whose
// compiled form imports the runtime's exception helpers.
//
// It logs what arrived, then FAILS the invocation on purpose.
//
// Returning success would let SQS delete the message, which is what this handler used to do,
// and it made a dead letter unobservable twice over: the queue's depth returned to 0, so a
// depth alarm could never fire, and the function's `Errors` metric stayed at 0, so neither
// could an error alarm. A plugin whose commands failed every 5 minutes for two days produced
// 217 dead letters and no signal at all; it was found by a person noticing a stale UI.
//
// Failing instead keeps the message on the queue and keeps `Errors` non-zero while the
// condition lasts. Both are conventional alarm subjects, and a monitoring backend attached
// through the `DeadLetterSink` seam now has something to attach to.
//
// The transport retries by design too: a failed batch returns to the queue and is redelivered
// until retention expires. A handler that fails forever, on a transport that retries forever,
// is a loop, and it outlives its cause, because nothing about a fixed bug removes the message
// that was stranded by it. So what the loop costs is a function of the line, not the count:
// the first delivery here writes the record's ids, kind, size and attribute names (never its
// body, which is a command or event and may be about a person), and every redelivery after it
// writes a single identity line. A stranded message is ~150 KB over a fortnight rather than
// ~17 MB, small enough that ending the loop early is an operator's job.

// How many times a consuming queue delivers a message before it moves it here. Every redrive
// policy in the framework takes it from here. SQS keeps a message's receive count when it
// moves it, so a dead letter's first delivery here reports `maxReceiveCount + 1`; a message
// sent here directly starts at 1.
let maxReceiveCount = 5
let firstDeliveryCount = maxReceiveCount + 1

type record = {
  messageId?: string,
  body?: string,
  attributes?: dict<string>,
  messageAttributes?: dict<JSON.t>,
  eventSourceARN?: string,
}
type event = {@as("Records") records?: array<record>}

// The body parsed, or nothing when it is not JSON. A `try` would import the runtime, so the
// parse is guarded in plain JS.
let parseOrNull: string => Nullable.t<JSON.t> = %raw(`function (text) {
  try { return JSON.parse(text) } catch (_) { return null }
}`)

// `Option.getOr` would import the Stdlib, so the default is given here.
let orElse = (value: option<string>, fallback: string) =>
  switch value {
  | Some(v) => v
  | None => fallback
  }

// The command's or event's tag, "sns" for an SNS envelope, else "unknown".
let kindOf = (body: string): string =>
  switch parseOrNull(body)->Nullable.toOption {
  | Some(JSON.Object(d)) =>
    let tagOf = key =>
      switch d->Dict.get(key) {
      | Some(JSON.Object(inner)) =>
        switch inner->Dict.get("TAG") {
        | Some(JSON.String(tag)) => Some(tag)
        | _ => None
        }
      | _ => None
      }
    switch (tagOf("command"), tagOf("event"), d->Dict.get("Message")) {
    | (Some(tag), _, _) | (None, Some(tag), _) => tag
    | (None, None, Some(_)) => "sns"
    | (None, None, None) => "unknown"
    }
  | _ => "unknown"
  }

let receiveCountOf = (attrs: dict<string>): int =>
  switch attrs->Dict.get("ApproximateReceiveCount") {
  | Some(text) =>
    let n = Float.parseFloat(text)
    Float.isNaN(n) ? 1 : Float.toInt(n)
  | None => 1
  }

// The line a record writes: the full one on its first delivery here, the short one after.
let lineOf = (record: record): string => {
  let attrs = switch record.attributes {
  | Some(a) => a
  | None => Dict.make()
  }
  let receiveCount = receiveCountOf(attrs)
  let body = record.body->orElse("")
  let source = switch attrs->Dict.get("DeadLetterQueueSourceArn") {
  | Some(arn) => arn
  | None => record.eventSourceARN->orElse("unknown")
  }
  let identity =
    "messageId=" ++
    record.messageId->orElse("unknown") ++
    " source=" ++
    source ++
    " receiveCount=" ++
    Int.toString(receiveCount) ++
    " bodyBytes=" ++
    Int.toString(String.length(body))
  if receiveCount <= firstDeliveryCount {
    let attributeNames = switch record.messageAttributes {
    | Some(m) => m->Dict.keysToArray
    | None => []
    }
    "DEAD LETTER ITEM: " ++
    identity ++
    " kind=" ++
    kindOf(body) ++
    " attributes=" ++
    attributeNames->Array.join(",")
  } else {
    "DEAD LETTER REDELIVERY: " ++ identity
  }
}

let handler = async (event: event): unit => {
  let records = switch event.records {
  | Some(r) => r
  | None => []
  }
  records->Array.forEach(record => Console.error(lineOf(record)))
  JsError.throw(
    JsError.make(
      "Dead-lettered " ++
      Int.toString(
        Array.length(records),
      ) ++ " message(s); see DEAD LETTER ITEM above. Failing so the messages are retained and Errors is non-zero.",
    ),
  )
}
