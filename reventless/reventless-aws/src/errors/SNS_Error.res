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
    msg->String.includes("ThrottlingException") ||
    msg->String.includes("ServiceUnavailable") ||
    msg->String.includes("InternalServerError") ||
    msg->String.includes("RequestLimitExceeded")
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
  Schedule.exponential(Duration.millis(1000))
  ->Schedule.jittered
  ->Schedule.intersect(Schedule.recurs(5))
  ->Schedule.whileInput(isTransient)
