type t =
  | Transient(string)
  | Permanent(string)

let isTransient = err =>
  switch err {
  | Transient(_) => true
  | Permanent(_) => false
  }

let classify = (err: unknown): t => {
  let msg = ReventlessCore.Util.Error.messageFromUnknown(err, "SNS error")
  if (
    err->Util_AwsError.hasAnyCode([
      "ThrottlingException",
      "ServiceUnavailable",
      "InternalServerError",
      "RequestLimitExceeded",
    ])
  ) {
    Transient(msg)
  } else {
    Permanent(msg)
  }
}

let message = err =>
  switch err {
  | Transient(msg) | Permanent(msg) => msg
  }

let retrySchedule: Schedule.t<Duration.t, t, unit> =
  Schedule.exponential(Duration.millis(1000))
  ->Schedule.jittered
  ->Schedule.intersect(Schedule.recurs(5))
  ->Schedule.whileInput(isTransient)
