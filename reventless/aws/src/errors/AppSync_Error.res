type t =
  | Transient(string)
  | Permanent(string)

let isTransient = err =>
  switch err {
  | Transient(_) => true
  | Permanent(_) => false
  }

let classify = (err: unknown): t => {
  let msg = ReventlessCore.Util.Error.messageFromUnknown(err, "AppSync error")
  if (
    err->Util_AwsError.hasAnyCode([
      "ConcurrentModificationException",
      "Schema is currently being altered",
      "ThrottlingException",
      "TooManyRequestsException",
      "ServiceUnavailable",
      "InternalFailureException",
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
  Schedule.exponential(Duration.millis(2000))
  ->Schedule.jittered
  ->Schedule.intersect(Schedule.recurs(6))
  ->Schedule.whileInput(isTransient)
