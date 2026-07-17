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
    msg->String.includes("ConcurrentModificationException") ||
    msg->String.includes("Schema is currently being altered") ||
    msg->String.includes("ThrottlingException") ||
    msg->String.includes("TooManyRequestsException") ||
    msg->String.includes("ServiceUnavailable") ||
    msg->String.includes("InternalFailureException")
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

let retrySchedule: Schedule.t<(Duration.t, int), t, unit> =
  Schedule.exponential(Duration.millis(2000))
  ->Schedule.jittered
  ->Schedule.intersect(Schedule.recurs(6))
  ->Schedule.whileInput(isTransient)
