// The identity provider a deployed platform provisions: principals in its
// Cognito pool, and each new one's domain id in the identity store the pool's
// pre-token trigger reads. The AWS counterpart of the local platform's
// `Capability_IdentityProvider_AccountStore`, and reached the same way — on the
// capability record a slice's `translate` receives.
//
// Pulumi-free so it ships in the slice Lambda. The pool calls go through an
// injected `ops` record so the sequencing below — what is undone when a later
// step fails, which failures are verdicts — is testable without a pool.
//
// The principal's handle is the username, and the username is the address the
// person is reached at, as on the local platform.

open Reventless

/** The calls a provider makes, one per pool or store operation. Each throws the
    SDK's error on failure; [failureOf] classifies it. */
type ops = {
  /** Creates the account and answers its `sub`. */
  createUser: (~username: string, ~attributes: array<(string, string)>) => promise<option<string>>,
  subOf: (~username: string) => promise<option<string>>,
  setPassword: (~username: string, ~password: string) => promise<unit>,
  addToGroup: (~username: string, ~group: string) => promise<unit>,
  removeFromGroup: (~username: string, ~group: string) => promise<unit>,
  deleteUser: (~username: string) => promise<unit>,
  putUserId: (~sub: string, ~userId: string) => promise<unit>,
  deleteUserId: (~sub: string) => promise<unit>,
}

@get @return(nullable) external errorName: JsExn.t => option<string> = "name"

let codeOf = (exn: exn): option<string> => exn->JsExn.fromException->Option.flatMap(errorName)

let messageOf = (exn: exn): string =>
  exn
  ->JsExn.fromException
  ->Option.flatMap(JsExn.message)
  ->Option.getOr("the identity provider failed")

/**
A pool failure as the capability's answer.

`Refused` only where the pool has judged the request itself — a password its
policy rejects, an attribute it will not take, a group that does not exist.
Everything else is `Unavailable`, retried: throttling, a network blip, a role
missing its grant. A caller reaching `createPrincipal` has already recorded that
the address was proven, and treating an outage as a verdict would strand them.
*/
let failureOf = (exn: exn): IdentityProvider.failure =>
  switch codeOf(exn) {
  | Some("UsernameExistsException" | "AliasExistsException") => Conflict
  | Some(
      "InvalidPasswordException"
      | "InvalidParameterException"
      | "UserNotFoundException"
      | "ResourceNotFoundException",
    ) =>
    Refused(messageOf(exn))
  | _ => Unavailable(messageOf(exn))
  }

let usernameOf = (contact: Messaging.recipient): result<string, IdentityProvider.failure> =>
  switch contact {
  | ToEmail(email) => Ok(Email.toString(email))
  | ToSms(phone) => Ok(Phone.toString(phone))
  | ToPush(_) => Error(Refused("a push address cannot be signed in with"))
  }

/** Verified, because a principal is only created after the address was proven —
    the ordering the registration chapter is built on. */
let attributesOf = (contact: Messaging.recipient): array<(string, string)> =>
  switch contact {
  | ToEmail(email) => [("email", Email.toString(email)), ("email_verified", "true")]
  | ToSms(phone) => [("phone_number", Phone.toString(phone)), ("phone_number_verified", "true")]
  | ToPush(_) => []
  }

let attempt = async (run: unit => promise<'a>): result<'a, IdentityProvider.failure> =>
  try Ok(await run()) catch {
  | exn => Error(failureOf(exn))
  }

let withOps = (ops: ops, ~hasStore: bool): IdentityProvider.t => {
  // Everything after the account exists, in order. A failure here undoes the
  // account before answering, so a retry starts from nothing: left in place, the
  // retry would meet `UsernameExistsException` and report a `Conflict` for a
  // person whose first attempt merely timed out.
  let complete = async (~username, ~sub, ~credential: IdentityProvider.credential, ~groups) => {
    let steps = async () => {
      switch credential {
      | Password(password) => await ops.setPassword(~username, ~password)
      | NoCredential => ()
      }
      for i in 0 to groups->Array.length - 1 {
        await ops.addToGroup(~username, ~group=groups->Array.getUnsafe(i))
      }

      // Minted here and only here: an account the pool made before the store
      // existed keeps its `sub`, and nothing re-keys it.
      if hasStore {
        await ops.putUserId(~sub, ~userId=ReventlessCore.Auth_UserId.mint())
      }
    }
    switch await attempt(steps) {
    | Ok() => Ok({IdentityProvider.providerId: username})
    | Error(_) as failed =>
      let _ = await attempt(() => ops.deleteUser(~username))
      failed
    }
  }

  let createPrincipal = async (~contact, ~credential, ~groups) =>
    switch usernameOf(contact) {
    | Error(_) as e => e
    | Ok(username) =>
      switch await attempt(() => ops.createUser(~username, ~attributes=attributesOf(contact))) {
      | Error(_) as e => e
      | Ok(created) =>
        let sub = switch created {
        | Some(_) => created
        | None => (await attempt(() => ops.subOf(~username)))->Result.getOr(None)
        }
        switch sub {
        | None =>
          let _ = await attempt(() => ops.deleteUser(~username))
          Error(IdentityProvider.Unavailable(`the pool created ${username} but named no sub`))
        | Some(sub) => await complete(~username, ~sub, ~credential, ~groups)
        }
      }
    }

  let addToGroup = (~principal: IdentityProvider.principal, ~group) =>
    attempt(() => ops.addToGroup(~username=principal.providerId, ~group))

  let removeFromGroup = (~principal: IdentityProvider.principal, ~group) =>
    attempt(() => ops.removeFromGroup(~username=principal.providerId, ~group))

  // Deleting what is gone is the retry of a delete that happened, so a missing
  // account answers `Ok`. The mapping row goes last, best effort: a row whose
  // principal is gone is never read on the request path, since no token is
  // minted for it.
  let deletePrincipal = async (~principal: IdentityProvider.principal) => {
    let username = principal.providerId
    switch await attempt(() => ops.subOf(~username)) {
    | Error(Refused(_)) => Ok()
    | Error(_) as e => e
    | Ok(sub) =>
      switch await attempt(() => ops.deleteUser(~username)) {
      | Error(Unavailable(_)) as e => e
      | Error(_) | Ok() =>
        switch (sub, hasStore) {
        | (Some(sub), true) =>
          let _ = await attempt(() => ops.deleteUserId(~sub))
        | _ => ()
        }
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

// ── The SDK ──────────────────────────────────────────────────────────────────

module Cognito = AwsSdk.CognitoIdentityServiceProvider

let subFrom = (attributes: option<array<Cognito.AdminCreateUserCommand.attributeType>>) =>
  attributes->Option.getOr([])->Array.find(a => a.name == "sub")->Option.map(a => a.value)

let sdkOps = (~poolId: string, ~identityStore: string): ops => {
  createUser: async (~username, ~attributes) => {
    let out = await Cognito.AdminCreateUserCommand.make({
      userPoolId: poolId,
      username,
      userAttributes: attributes->Array.map(((name, value)) => {
        Cognito.AdminCreateUserCommand.name,
        value,
      }),
      // No invitation: the person has proven the address already, and the
      // invitation would carry a temporary password nobody should use.
      messageAction: "SUPPRESS",
    })->Cognito.AdminCreateUserCommand.send
    out.user->Option.flatMap(u => subFrom(u.attributes))
  },
  subOf: async (~username) => {
    let out = await Cognito.AdminGetUserCommand.make({
      userPoolId: poolId,
      username,
    })->Cognito.AdminGetUserCommand.send
    out.userAttributes->Option.getOr([])->Array.find(a => a.name == "sub")->Option.map(a => a.value)
  },
  setPassword: (~username, ~password) =>
    Cognito.AdminSetUserPasswordCommand.make({
      userPoolId: poolId,
      username,
      password,
      permanent: true,
    })->Cognito.AdminSetUserPasswordCommand.send,
  addToGroup: (~username, ~group) =>
    Cognito.AdminAddUserToGroupCommand.make({
      userPoolId: poolId,
      username,
      groupName: group,
    })->Cognito.AdminAddUserToGroupCommand.send,
  removeFromGroup: (~username, ~group) =>
    Cognito.AdminRemoveUserFromGroupCommand.make({
      userPoolId: poolId,
      username,
      groupName: group,
    })->Cognito.AdminRemoveUserFromGroupCommand.send,
  deleteUser: (~username) =>
    Cognito.AdminDeleteUserCommand.make({
      userPoolId: poolId,
      username,
    })->Cognito.AdminDeleteUserCommand.send,
  putUserId: async (~sub, ~userId) => {
    let _ = await AwsSdk.DynamoDb_DocumentClient.PutCommand.make({
      tableName: identityStore,
      item: JSON.Encode.object(
        Dict.fromArray([
          (Auth_IdentityStore_Schema.partitionKey, JSON.Encode.string(sub)),
          (Auth_IdentityStore_Schema.userIdAttribute, JSON.Encode.string(userId)),
        ]),
      ),
    })->AwsSdk.DynamoDb_DocumentClient.PutCommand.send
  },
  deleteUserId: async (~sub) => {
    let _ = await AwsSdk.DynamoDb_DocumentClient.DeleteCommand.make({
      tableName: identityStore,
      key: Dict.fromArray([(Auth_IdentityStore_Schema.partitionKey, JSON.Encode.string(sub))]),
    })->AwsSdk.DynamoDb_DocumentClient.DeleteCommand.send
  },
}

/**
The provider a slice Lambda is handed, from the two values the deploy put in its
environment. No pool is the deployment gap it always was, answered `Unavailable`
with no operations. No store means the pool predates it: principals are still
made, and each keeps its `sub` as its id, as every account before the store did.
*/
let provider = (~poolId: string, ~identityStore: string): IdentityProvider.t =>
  poolId == ""
    ? IdentityProvider.unavailable(~reason="no identity provider is configured for this platform")
    : withOps(sdkOps(~poolId, ~identityStore), ~hasStore=identityStore != "")
