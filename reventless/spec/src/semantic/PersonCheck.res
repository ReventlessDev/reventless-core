/**
A check that a person, not a script, is at the sign-up form.

The form renders the check's widget, the widget hands it a token, and the door
asks this capability whether the token holds before it relays anything. The
check's secret is the deployment's and reaches only the door's function; what the
shell is told is `widget`, public by construction.

**Two failures, told apart.** `Rejected` is the check's answer: the token is
missing, wrong, expired or used. `Unavailable` is a check that could not be asked.
A door refuses on both, so a check that is down never lets sign-ups through
unchecked; a platform also counts the second, so someone hears of it.
*/
type failure =
  | Rejected(string)
  | Unavailable(string)

/** What the shell needs to render the widget: its public site key. */
type widget = {siteKey: string}

type t = {
  /** Whether `token` shows a person; `""` is no token. */
  verify: (~token: string) => promise<result<unit, failure>>,
}

/** A check that passes everyone, with no widget: the local platform's, where the
    one signing up is the developer. */
let alwaysPasses: t = {verify: async (~token as _) => Ok()}

/** A check that cannot be asked: what a platform that provisions none answers, so
    a door declaring the need refuses rather than lets anyone through. */
let unavailable = (~reason: string): t => {
  verify: async (~token as _) => Error(Unavailable(reason)),
}

let failureReason = (failure: failure): string =>
  switch failure {
  | Rejected(reason) | Unavailable(reason) => reason
  }

/** The settings a deployment turns its check on with: both, or neither. */
let siteKeyConfigKey = "platform:personCheckSiteKey"
let secretConfigKey = "platform:personCheckSecret"

/** The secret, as a deployed function is handed it. */
let secretEnvKey = "REVENTLESS_PERSON_CHECK_SECRET"
