/**
How many requests one source may make to a door open to callers who are not
signed in, per window.

A transport concern, not a domain one. How many times an address may be sent a
challenge is the domain's, counted in a `decide`; how many requests one network
source may make is not, because nothing in the log knows where a request came
from. So this is deployment configuration — what an environment fixes and a
repository cannot know — read by whichever door serves the anonymous traffic:
the local platform's GraphQL server, and on AWS the door anonymous callers will
reach.

Every door whose rule is `AllowAnonymous` is limited, whoever the caller turns
out to be: the limit is on the door, because the door is what an abuser aims at.
*/
type t = {requests: int, windowSeconds: int}

/** Enough for a person to sign up, mistype a code and ask again; few enough that
    a script cannot mail strangers from the deployment's address. */
let default: t = {requests: 10, windowSeconds: 3600}

/** The configuration key, as an environment variable. On AWS the same value
    travels as `platform:anonymousRequestLimit`. */
let envKey = "REVENTLESS_ANONYMOUS_REQUEST_LIMIT"

let toString = ({requests, windowSeconds}: t): string =>
  `${requests->Int.toString}/${windowSeconds->Int.toString}`

/**
`"10/3600"`: requests, then the window in seconds. Refuses rather than defaults
on anything else, because a limit someone set and mistyped would otherwise be
silently replaced by one they did not choose.
*/
let parse = (raw: string): result<t, string> =>
  switch raw->String.trim->String.split("/")->Array.map(s => s->String.trim->Int.fromString) {
  | [Some(requests), Some(windowSeconds)] if requests > 0 && windowSeconds > 0 =>
    Ok({requests, windowSeconds})
  | _ =>
    Error(
      `${envKey}: "${raw}" is not a limit — write requests/seconds, such as ${default->toString}`,
    )
  }
