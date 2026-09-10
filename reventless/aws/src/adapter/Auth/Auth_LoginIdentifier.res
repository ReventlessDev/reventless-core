// The attribute a person signs in with. One definition, two consumers: the auto
// pool the platform stack declares, and the provisioning script that makes a
// pool no stack owns. Free of Pulumi and of the AWS SDK so both can import it.

/**
Which attribute identifies a person at sign-in.

🚨 **Fixed at pool creation, and no later deploy can change it.** `CreateUserPool`
accepts `UsernameAttributes`; `UpdateUserPool` has no such member, so nothing can
change it in place and every provider replaces the pool instead. A replaced pool
is an empty one — Cognito exports no password material, so every account
re-registers. A deployment that will ever want phone sign-in has to say so on its
first deploy.
*/
type t =
  | Email
  | Phone
  | EmailOrPhone

/** What every pool has been created with so far, so an existing stack redeploys
  unchanged. */
let default = Email

let all: array<t> = [Email, Phone, EmailOrPhone]

/** The config spelling, and the stack output. */
let toString = (identifier: t): string =>
  switch identifier {
  | Email => "email"
  | Phone => "phone"
  | EmailOrPhone => "emailOrPhone"
  }

let fromString = (value: string): option<t> => all->Array.find(i => toString(i) == value)

/** Cognito's `usernameAttributes`. */
let usernameAttributes = (identifier: t): array<string> =>
  switch identifier {
  | Email => ["email"]
  | Phone => ["phone_number"]
  | EmailOrPhone => ["email", "phone_number"]
  }

/**
The deploy-time choice, or why the deploy cannot proceed.

An unrecognised spelling refuses rather than falling back to the default: a typo
that defaulted would create a pool signing in on the wrong attribute, which is
the one property no later deploy can correct.
*/
let parse = (value: option<string>): result<t, string> =>
  switch value {
  | None => Ok(default)
  | Some(raw) =>
    switch fromString(raw) {
    | Some(identifier) => Ok(identifier)
    | None =>
      Error(
        `loginIdentifier "${raw}" is not one of ${all
          ->Array.map(toString)
          ->Array.join(
            ", ",
          )}. It fixes the sign-in attribute at pool creation and no later deploy can change it, so an unrecognised spelling refuses rather than defaulting.`,
      )
    }
  }
