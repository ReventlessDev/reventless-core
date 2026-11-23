/**
How many requests visitors made to a plugin's doors and to its views, counted
per minute and per hour, and how many of those the limit refused.

Kept beside the limit, not in the log: like the limit it is a transport concern,
and nothing in the log knows a request was made. The rows are the deployment's
operators' to read, through a view the framework gives every plugin with a door
or view for visitors (`<Plugin>_VisitorRequestCountsByIds`).

A row is one kind's bucket. Its id names the kind, the bucket's length and its
start in seconds since the epoch, `door/60/1795431360`, so a reader asks for
exactly the buckets it needs by id: the minutes of the first hour from the minute
something began, then every hour after. A row that is not there counted nothing.
A client that cannot import this module computes the same ids.

One more row per kind holds every request since counting began: length and start
`0` (`door/0/0`), kept for good.
*/
@schema
type row = {
  /** `door` or `view`. */
  kind: string,
  /** The bucket's start, as an ISO time. */
  startsAt: string,
  /** The bucket's length: 60 or 3600, or 0 for the row of every request. */
  seconds: int,
  /** Absent until a request is counted, like `refused` until one is refused. */
  requests?: int,
  refused?: int,
}

/** The view's name; its fields are `<Plugin>_VisitorRequestCount…`. */
let queryDbName = "VisitorRequestCount"

let minute = 60
let hour = 3600
/** The length of the row that holds every request since counting began. */
let ever = 0

/** How long a bucket of each length is kept: minutes for a week, so the first
    hour of a window opened days ago still counts from its minute; hours for
    forty days. Past that, what is left undercounts. The row of every request is
    kept for good. */
let keptSeconds = (seconds: int): option<int> =>
  if seconds == ever {
    None
  } else {
    Some(seconds == minute ? 8 * 86_400 : 40 * 86_400)
  }

let kindName = (kind: AnonymousRequestLimit.kind): string =>
  switch kind {
  | Door => "door"
  | View => "view"
  }

/** The start, in seconds since the epoch, of the bucket of `seconds` that holds `at`. */
let startOf = (~seconds: int, at: Date.t): float => {
  let length = Int.toFloat(seconds)
  Math.floor(Date.getTime(at) /. 1000. /. length) *. length
}

let idOf = (~kind: string, ~seconds: int, ~start: float): string =>
  `${kind}/${seconds->Int.toString}/${start->Float.toString}`

/** The buckets a request at `at` is counted in: its minute, its hour, and every request. */
let bucketsAt = (at: Date.t): array<(int, float)> => [
  (minute, startOf(~seconds=minute, at)),
  (hour, startOf(~seconds=hour, at)),
  (ever, 0.),
]

/** The id of the row that holds every request of `kind`. */
let everId = (~kind: string): string => idOf(~kind, ~seconds=ever, ~start=0.)

/** A bucket's row before anything is counted in it. */
let empty = (~kind: string, ~seconds: int, ~start: float): row => {
  kind,
  startsAt: Date.fromTime(start *. 1000.)->Date.toISOString,
  seconds,
}

/**
The ids whose rows add up to the requests of `kind` from the minute of `since` to
`now`: each minute of `since`'s hour from its minute on, then each hour after, up
to and including the one `now` is in. Within `since`'s own hour, only its minutes
up to `now`'s. Empty when `since` is after `now`.
*/
let idsSince = (~kind: string, ~since: Date.t, ~now: Date.t): array<string> => {
  let firstMinute = startOf(~seconds=minute, since)
  let lastMinute = startOf(~seconds=minute, now)
  let firstHour = startOf(~seconds=hour, since)
  let lastHour = startOf(~seconds=hour, now)
  let step = (~from, ~to_, ~seconds) => {
    let length = Int.toFloat(seconds)
    let count = from > to_ ? 0 : Float.toInt((to_ -. from) /. length) + 1
    Array.fromInitializer(~length=count, i =>
      idOf(~kind, ~seconds, ~start=from +. Int.toFloat(i) *. length)
    )
  }
  if firstMinute > lastMinute {
    []
  } else if firstHour == lastHour {
    step(~from=firstMinute, ~to_=lastMinute, ~seconds=minute)
  } else {
    let endOfFirstHour = firstHour +. Int.toFloat(hour - minute)
    Array.concat(
      step(~from=firstMinute, ~to_=endOfFirstHour, ~seconds=minute),
      step(~from=firstHour +. Int.toFloat(hour), ~to_=lastHour, ~seconds=hour),
    )
  }
}
