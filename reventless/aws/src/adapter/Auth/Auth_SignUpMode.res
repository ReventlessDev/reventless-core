// Whether a stranger can create their own account. One definition, two consumers:
// the auto pool the platform stack declares, and the provisioning script that
// makes a pool no stack owns. Free of Pulumi and of the AWS SDK so both can
// import it — the same shape, and the same drift it prevents, as
// [Auth_LoginIdentifier].

/**
Who may create a principal in this pool.

Unlike the sign-in attribute, this **is** updatable in place: `AdminCreateUserConfig`
is a member of `UpdateUserPoolRequest`, so a pool full of accounts can be flipped
either way at any time, for free and reversibly. It is a setting, not a
first-deploy-or-never decision.

🚨 **On a shared pool the flip is pool-wide, not stack-wide.** The setting belongs
to the pool and the pool has one of it, so every stack pointed at that pool gets
self-service the moment one deployment turns it on. A deployment that must never
self-register cannot rely on its own config to prevent it, and should not share a
pool with one that does.
*/
type t =
  /** Only an administrator creates principals — what every pool so far was
      created with, and what a deployment with no registration flow wants. */
  | AdminOnly
  /** A stranger can register themselves. */
  | SelfService

/** What every pool has been created with so far, so an existing stack redeploys
  unchanged. Closed is also the right default on its own terms: a deployment that
  has not asked for self-registration should not acquire it by upgrading. */
let default = AdminOnly

let all: array<t> = [AdminOnly, SelfService]

/** The config spelling. */
let toString = (mode: t): string =>
  switch mode {
  | AdminOnly => "adminOnly"
  | SelfService => "selfService"
  }

let fromString = (value: string): option<t> => all->Array.find(m => toString(m) == value)

/** Cognito's `allowAdminCreateUserOnly`, which asks the negative of what this
  type asks. Converting in one place is the point: a bool named for the negative
  is easy to read backwards at a call site. */
let allowAdminCreateUserOnly = (mode: t): bool =>
  switch mode {
  | AdminOnly => true
  | SelfService => false
  }

/**
The deploy-time choice, or why the deploy cannot proceed.

An unrecognised spelling refuses rather than falling back to the default, and the
reason is *not* [Auth_LoginIdentifier]'s — this setting is correctable at any
time. It is that the mistake would be silent. The default is closed, so a typo
fails safe, but it fails safe *invisibly*: the deploy is green, the config says
what the operator meant, and the symptom is every registration being refused,
which surfaces far from the misspelling that caused it.
*/
let parse = (value: option<string>): result<t, string> =>
  switch value {
  | None => Ok(default)
  | Some(raw) =>
    switch fromString(raw) {
    | Some(mode) => Ok(mode)
    | None =>
      Error(
        `signUpMode "${raw}" is not one of ${all
          ->Array.map(toString)
          ->Array.join(
            ", ",
          )}. It decides whether a stranger can create an account. An unrecognised spelling refuses rather than defaulting, because defaulting would deploy green and refuse every registration, with nothing pointing back at the spelling.`,
      )
    }
  }
