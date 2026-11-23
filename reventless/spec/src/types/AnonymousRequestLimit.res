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

Every door and view whose rule is `AllowAnonymous` is limited, whoever the caller
turns out to be: the limit is on the door, because the door is what an abuser
aims at.

A door and a view have limits of their own. A door does work that costs (a
challenge mailed, an account made), so a person needs only a few; a view is read
on every visit to a page, so the same few would hide it from someone who reloads.
*/
type t = {requests: int, windowSeconds: int}

/** What a limit is on: a door (a mutation) or a view (a query). */
type kind =
  | Door
  | View

/** Enough for a person to sign up, mistype a code and ask again; few enough that
    a script cannot mail strangers from the deployment's address. */
let default: t = {requests: 20, windowSeconds: 3600}

/** Five reads a minute for an hour: a page reloaded often, or several people
    behind one address, and still a ceiling on a script. */
let viewDefault: t = {requests: 300, windowSeconds: 3600}

/** The doors' configuration key, as an environment variable. On AWS the same
    value travels as `platform:anonymousRequestLimit`. */
let envKey = "REVENTLESS_ANONYMOUS_REQUEST_LIMIT"

/** The views' key, as an environment variable; `platform:anonymousViewLimit` on AWS. */
let viewEnvKey = "REVENTLESS_ANONYMOUS_VIEW_LIMIT"

let defaultOf = (kind: kind): t =>
  switch kind {
  | Door => default
  | View => viewDefault
  }

let envKeyOf = (kind: kind): string =>
  switch kind {
  | Door => envKey
  | View => viewEnvKey
  }

/** The key on a platform stack, under `platform:`. */
let configKeyOf = (kind: kind): string =>
  switch kind {
  | Door => "anonymousRequestLimit"
  | View => "anonymousViewLimit"
  }

let toString = ({requests, windowSeconds}: t): string =>
  `${requests->Int.toString}/${windowSeconds->Int.toString}`

/**
`"10/3600"`: requests, then the window in seconds. Refuses rather than defaults
on anything else, because a limit someone set and mistyped would otherwise be
silently replaced by one they did not choose.
*/
let parse = (~kind: kind=Door, raw: string): result<t, string> => {
  // Digits only: a number reader takes `1.5` as 1 and `5x` as 5, a limit nobody chose.
  let whole = (s: string) => {
    let s = s->String.trim
    RegExp.test(/^\d+$/, s) ? Int.fromString(s) : None
  }
  switch raw->String.trim->String.split("/")->Array.map(whole) {
  | [Some(requests), Some(windowSeconds)] if requests > 0 && windowSeconds > 0 =>
    Ok({requests, windowSeconds})
  | _ =>
    Error(
      `${envKeyOf(kind)}: "${raw}" is not a limit — write requests/seconds, such as ${defaultOf(
          kind,
        )->toString}`,
    )
  }
}

/** The limit a setting says: the kind's default where it is unset or empty. */
let fromSetting = (~kind: kind, setting: option<string>): result<t, string> =>
  switch setting {
  | None | Some("") => Ok(defaultOf(kind))
  | Some(raw) => parse(~kind, raw)
  }
