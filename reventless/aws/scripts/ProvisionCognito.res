/***
The Cognito operations a provisioning run performs, once.

Two bins now do the same four things — ensure a group, ensure an account, set a
permanent password, apply a membership — and `provision-admin` did them first.
Extracted here rather than copied for the reason [Auth_LoginIdentifier] and
[Auth_SignUpMode] were: a second copy drifts, and the half that drifts is
whichever one nobody re-reads.

🚨 **These report rather than print.** `provision-admin` has a line format its
tests and its docs both describe, and an extraction that took the printing with it
would have changed that script's output while claiming to change nothing. Each
caller phrases its own run; what is shared is what the API does.

The password generator that used to sit beside these moved further, to
[Util_Password] in `spec` — the manifest's platform-neutral half needs it, and
that half must not reach into this package.
*/

open AwsSdk

module Cognito = CognitoIdentityServiceProvider

/** Whether the call made the thing or found it. Both are success; the difference
  is only worth a word in the output, and a caller that treats "already there" as
  a failure makes the second run of a provisioning script an error. */
type outcome =
  | Created
  | AlreadyPresent

/**
The sign-in attributes a pool was created with.

Fixed at pool creation and unchangeable — see [Auth_LoginIdentifier] — so this is
the one pool fact a provisioning run must read before it writes. An empty list
means the pool signs in on a plain username, which takes an email-shaped one
happily; a list naming `email` means a plain username can never authenticate.

Described rather than assumed because the symptom of getting it wrong is a
correctly-created account that simply cannot log in, arriving at a login screen
far from the run that caused it.
*/
let usernameAttributes = async (~providerId: string): result<array<string>, string> => {
  let described = await Cognito.DescribeUserPoolCommand.make({
    userPoolId: providerId,
  })->Cognito.DescribeUserPoolCommand.send
  switch described.userPool {
  | None => Error(`DescribeUserPool returned nothing for "${providerId}"`)
  | Some(pool) => Ok(pool.usernameAttributes->Option.getOr([]))
  }
}

/** The group, where a stack has not already declared it.

  In auto mode the platform stack declares the administrator group as an ordinary
  child of the pool it owns, so this is a no-op. On a supplied pool no stack does,
  because two stacks sharing a provider would both declare it and the second would
  fail on a name that already exists. Every other group a manifest names is in the
  same position: nothing else creates it. */
let ensureGroup = async (~providerId: string, ~group: string, ~description: string): outcome =>
  try {
    let _ = await Cognito.CreateGroupCommand.make({
      groupName: group,
      userPoolId: providerId,
      description,
    })->Cognito.CreateGroupCommand.send
    Created
  } catch {
  | exn if exn->Util_AwsError.hasCode(~code="GroupExistsException") => AlreadyPresent
  }

/**
The account, where it is not already there.

`MessageAction: "SUPPRESS"` stops Cognito emailing an invitation. The invitation
carries the temporary password the run is about to replace, so sending it would
tell the new account holder to sign in with a credential that no longer works —
and on an admin-create-only pool these accounts may carry no deliverable address
at all.

Attributes are the caller's: an administrator created from an email address wants
`email` and `email_verified` stamped, and a demo account called `shopper` has
neither and needs none.
*/
let ensureUser = async (
  ~providerId: string,
  ~username: string,
  ~attributes: array<Cognito.AdminCreateUserCommand.attributeType>,
): outcome =>
  try {
    let _ = await Cognito.AdminCreateUserCommand.make({
      userPoolId: providerId,
      username,
      userAttributes: attributes,
      messageAction: "SUPPRESS",
    })->Cognito.AdminCreateUserCommand.send
    Created
  } catch {
  | exn if exn->Util_AwsError.hasCode(~code="UsernameExistsException") => AlreadyPresent
  }

/**
A password the account can actually be used with.

🚨 **The step it is easiest to leave out, and leaving it out reproduces the defect
these scripts exist to remove.** An administrator-created account holds a
*temporary* password and lands in `FORCE_CHANGE_PASSWORD`: the first sign-in meets
a `NEW_PASSWORD_REQUIRED` challenge, which the host UI is not known to handle and
which the seed client rejects outright — it gets a `ChallengeName` where it
expects a token. So this sets a permanent password, and the account is `CONFIRMED`
when it returns.
*/
let setPassword = async (~providerId: string, ~username: string, ~password: string): unit =>
  await Cognito.AdminSetUserPasswordCommand.make({
    userPoolId: providerId,
    username,
    password,
    permanent: true,
  })->Cognito.AdminSetUserPasswordCommand.send

/** Idempotent at the API: adding a user already in the group is not an error, so
  this needs no existence check of its own. */
let addToGroup = async (~providerId: string, ~username: string, ~group: string): unit =>
  await Cognito.AdminAddUserToGroupCommand.make({
    username,
    groupName: group,
    userPoolId: providerId,
  })->Cognito.AdminAddUserToGroupCommand.send

/**
The id the pool minted for an account.

No request supplies it and `AdminCreateUser` does not return it, so it is read
back — the same way for an account this run just made and one that was already
there, which is what lets a re-run correct a manifest written by hand.

`None` when the pool answers without a `sub`, which should not happen; the caller
reports it rather than writing a blank id into a file that is read as authority.
*/
let subOf = async (~providerId: string, ~username: string): option<string> => {
  let user = await Cognito.AdminGetUserCommand.make({
    userPoolId: providerId,
    username,
  })->Cognito.AdminGetUserCommand.send
  user.userAttributes
  ->Option.getOr([])
  ->Array.find(attribute => attribute.name == "sub")
  ->Option.map(attribute => attribute.value)
}
