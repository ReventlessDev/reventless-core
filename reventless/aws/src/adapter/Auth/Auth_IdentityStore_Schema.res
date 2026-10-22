// The identity store's identity: what it is called, and how its rows are keyed.
// The mapping from a Cognito `sub` to the domain's own user id — see
// [ReventlessCore.Auth_UserId] for why the two differ.
//
// One definition for the deploy that creates or looks the table up
// ([Auth_IdentityStore]), the pre-token trigger that reads it
// ([Auth_ActiveRoleTrigger_Ops]), and the provisioning scripts that write it
// (`provision-identity`, `provision-accounts`). Free of Pulumi and of the AWS
// SDK for the reason [Auth_ActiveRoleStore_Schema] gives.

/** Derived from the provider, never configured, for the reason the active-role
    store's name is: two stacks on one pool cannot name different stores. */
let derivedStoreName = (~identityProviderId: string): string =>
  `ReventlessIdentityStore-${identityProviderId}`

/** The Cognito `sub`. The trigger reads by it on every token it mints. */
let partitionKey = "id"

/** The domain id the row maps that subject to. */
let userIdAttribute = "userId"

/** Keyed on the subject alone: one identity, one domain id, on every platform
    the provider serves. The reverse direction, domain id to subject, is an
    index to add when the first caller for it exists; a global index can be
    added to a live table. */
let expectedKeySchema: array<(string, string)> = [(partitionKey, "HASH")]

/** Why an existing table under this name cannot serve, if it cannot. A table
    with the wrong key is found by the deploy and missed by every read, so the
    claim is never added and every new account silently keeps its `sub`. */
let keySchemaRefusal = (~tableName: string, ~actual: array<(string, string)>): option<string> => {
  let actualKey = Auth_ActiveRoleStore_Schema.describeKeySchema(actual)
  let wantedKey = Auth_ActiveRoleStore_Schema.describeKeySchema(expectedKeySchema)
  actualKey == wantedKey
    ? None
    : Some(
        `table "${tableName}" already exists with key schema [${actualKey}], but the identity store needs [${wantedKey}]. A row written under one key is invisible to a read under the other, so every new account would silently keep its provider id. Rename or remove the table; its rows are a mapping the provisioning run rewrites.`,
      )
}
