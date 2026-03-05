open AwsSdk.DynamoDb.DocumentClient

type t =
  | Transient(string)
  | StaleState(string)
  | Permanent(string)

let isTransient = err =>
  switch err {
  | Transient(_) => true
  | StaleState(_) | Permanent(_) => false
  }

let classify = (err: unknown): t => {
  let jsErr: JsExn.t = Obj.magic(err)
  switch jsErr->PutError.classify {
  | ConditionCheckFailedException(_) => StaleState(jsErr->ReventlessCore.Util.Error.message)
  | InternalServerError(_)
  | ProvisionedThroughputExceededException(_)
  | RequestLimitExceeded(_)
  | TransactionConflictException(_) =>
    Transient(jsErr->ReventlessCore.Util.Error.message)
  | _ =>
    let msg = ReventlessCore.Util.Error.messageFromUnknown(err, "DynamoDB error")
    if (
      msg->String.includes("ThrottlingException") ||
      msg->String.includes("ServiceUnavailable") ||
      msg->String.includes("InternalServerError")
    ) {
      Transient(msg)
    } else {
      Permanent(msg)
    }
  }
}

let message = err =>
  switch err {
  | Transient(msg) | StaleState(msg) | Permanent(msg) => msg
  }

let retrySchedule: Schedule.t<(Duration.t, int), t, unit> =
  Schedule.exponential(Duration.millis(500))
  ->Schedule.jittered
  ->Schedule.intersect(Schedule.recurs(5))
  ->Schedule.whileInput(isTransient)
