// The identity provider a dev platform provisions — the local counterpart to
// the Cognito provider the AWS platform does not have yet, and reached the same
// way `Capability_Messaging_Log` is: a root calls `make`, passes the handle as
// `~identityProvider` in `~hostUiBundle`, and the platform puts it on the
// capability record every slice's `translate` receives.
//
// Its store is `.reventless/users.yaml`, the file the in-memory auth adapter
// already loads at startup, so an account made here survives a restart with no
// second store to keep in step. Every write goes to the file and to the live
// `LocalAuth.Login` store together, so the running process and the next one
// agree.
//
// 🚨 **The file is shared and unlocked.** The seed runner reads it and
// `provision-accounts` writes it; two processes editing at once can lose one
// edit. Recorded rather than solved: the loss is a dev account, and a lock
// would be more machinery than the file is worth.
//
// The principal's handle is the username, and the username is the address the
// person is reached at — what a pool signing in on an email address does.

open Reventless

let usernameOf = (contact: Messaging.recipient): result<string, IdentityProvider.failure> =>
  switch contact {
  | ToEmail(email) => Ok(Email.toString(email))
  | ToSms(phone) => Ok(Phone.toString(phone))
  | ToPush(_) => Error(Refused("a push address cannot be signed in with"))
  }

let passwordOf = (credential: IdentityProvider.credential): string =>
  switch credential {
  | Password(password) => password
  | NoCredential => ""
  }

// A file the provider cannot read or write is a gap in the deployment, so the
// answer is retryable; a manifest refusing an edit is a verdict on the request.
let storeFailure = (message: string): IdentityProvider.failure => Unavailable(message)

let make = (~path: option<string>=?, ()): IdentityProvider.t => {
  let file = () => path->Option.getOr(AccountsManifest.defaultPath())
  let identityOf = (~username, ~groups): Identity.t => {
    userId: username,
    username,
    groups,
    provider: InMemory,
  }

  let createPrincipal = async (
    ~contact: Messaging.recipient,
    ~credential: IdentityProvider.credential,
    ~groups: array<string>,
  ): result<IdentityProvider.principal, IdentityProvider.failure> =>
    switch usernameOf(contact) {
    | Error(_) as e => e
    | Ok(username) if LocalAuth.Login.credentialsOf(~username)->Option.isSome => Error(Conflict)
    | Ok(username) =>
      let password = passwordOf(credential)
      // Minted here, never the username: the id reaches the event log as
      // `meta.user` and every `@owner` field, and a log keyed by login names
      // cannot survive a rename or a move to another provider.
      let userId = ReventlessCore.Auth_UserId.mint()
      switch AccountsManifest.editFile(
        ~path=file(),
        ~edits=[Append({username, password, groups, userId})],
      ) {
      | Error(message) if message->String.endsWith("already declared in the manifest") =>
        Error(Conflict)
      | Error(message) => Error(storeFailure(message))
      | Ok() =>
        LocalAuth.Login.setCredentials(
          ~username,
          ~password,
          ~identity={...identityOf(~username, ~groups), userId},
        )
        Ok({IdentityProvider.providerId: username})
      }
    }

  let setGroups = async (~username, ~groups): result<unit, IdentityProvider.failure> =>
    switch LocalAuth.Login.credentialsOf(~username) {
    | None => Error(Refused(`no principal ${username}`))
    | Some({identity}) if identity.groups == groups => Ok()
    | Some({password, identity}) =>
      switch AccountsManifest.editFile(~path=file(), ~edits=[SetGroups({username, groups})]) {
      | Error(message) => Error(storeFailure(message))
      | Ok() =>
        LocalAuth.Login.setCredentials(~username, ~password, ~identity={...identity, groups})
        Ok()
      }
    }

  let addToGroup = (~principal: IdentityProvider.principal, ~group: string) => {
    let username = principal.providerId
    let current = LocalAuth.Login.credentialsOf(~username)->Option.mapOr([], c => c.identity.groups)
    setGroups(
      ~username,
      ~groups=current->Array.includes(group) ? current : Array.concat(current, [group]),
    )
  }

  let removeFromGroup = (~principal: IdentityProvider.principal, ~group: string) => {
    let username = principal.providerId
    let current = LocalAuth.Login.credentialsOf(~username)->Option.mapOr([], c => c.identity.groups)
    setGroups(~username, ~groups=current->Array.filter(g => g != group))
  }

  // Deleting what is not there is the retry of a delete that happened.
  let deletePrincipal = async (~principal: IdentityProvider.principal): result<
    unit,
    IdentityProvider.failure,
  > => {
    let username = principal.providerId
    switch LocalAuth.Login.credentialsOf(~username) {
    | None => Ok()
    | Some(_) =>
      switch AccountsManifest.editFile(~path=file(), ~edits=[Remove(username)]) {
      | Error(message) => Error(storeFailure(message))
      | Ok() =>
        LocalAuth.Login.removeCredentials(~username)
        Ok()
      }
    }
  }

  IdentityProvider.make(
    ~createPrincipal,
    ~addToGroup,
    ~removeFromGroup,
    ~deletePrincipal,
    ~operations=[CreatePrincipal, AddToGroup, RemoveFromGroup, DeletePrincipal],
  )
}
