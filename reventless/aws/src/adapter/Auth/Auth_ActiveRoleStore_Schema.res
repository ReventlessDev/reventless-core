// The active-role store's identity: what it is called, and how its rows are
// keyed. See [docs/plans/active-role-store-scoped-to-the-pool.md].
//
// 🚨 **One definition, four consumers, and that is the whole reason this file
// exists.** The deploy creates or looks the table up ([Auth_ActiveRoleStore]),
// the write door writes rows ([Auth_ActiveRoleStore_Ops]), the pre-token trigger
// reads them ([Auth_ActiveRoleTrigger_Ops]), and the provisioning script creates
// the table on a provider no stack owns (`scripts/provision-identity.mjs`). Any
// two of those disagreeing produces the same failure: a row written where nothing
// looks for it, so a role switch reports success and does nothing.
//
// Deliberately free of Pulumi and of the AWS SDK, so the script and both Lambda
// bundles can import it without dragging a deploy-time dependency into a runtime
// graph — the hazard that once broke command-handler cold starts.

/**
The store belonging to an identity provider this framework does not own.

Derived rather than configured. The objection to deriving was that two stacks
would both try to *create* the table and the second would fail or adopt a
resource it does not own — true while stacks create it, and no stack creates this
one. What derivation buys is worth more than the config key it removes: two
platforms on one provider **cannot** name different stores, so the defect stops
being something to detect and becomes something that cannot be expressed.

The provider id carries its own region (`eu-west-1_CQTwafSeX`), which is the
region the store must live in too — a pre-token-generation trigger has to sit in
its pool's region, so every stack that can attach one derives the same name in
the same place.
*/
let derivedStoreName = (~identityProviderId: string): string =>
  `ReventlessActiveRoleStore-${identityProviderId}`

/** The caller's Cognito `sub`. Stable across a rename, unlike the username. */
let partitionKey = "id"

/**
The app client the token was minted for.

A sort key rather than nothing, because one identity provider can serve several
platforms: each platform stack declares its own app client, so keying on the pair
gives every platform its own active role over one shared set of rows. Keyed on
the subject alone, narrowing to a role in one platform would narrow the caller's
session in every other platform on that provider — defensible as "one identity,
one session", but not what an operator wants, since a role with surfaces in one
platform and none in another leaves the second showing nothing.
*/
let sortKey = "clientId"

/** The stored choice itself. */
let roleAttribute = "activeRole"

/** The key schema as DynamoDB describes one: `(attribute, keyType)` pairs.

  Plain tuples rather than the SDK's `keySchemaElement` so this module keeps its
  "no side effect" footer — importing the AWS SDK here would put it in both Lambda
  bundles, which is the dependency leak that once broke command-handler cold
  starts. Callers map their own shapes into this. */
let expectedKeySchema: array<(string, string)> = [(partitionKey, "HASH"), (sortKey, "RANGE")]

let describeKeySchema = (elements: array<(string, string)>): string =>
  elements
  ->Array.map(((attribute, keyType)) => `${attribute}:${keyType}`)
  ->Array.toSorted(String.compare)
  ->Array.join(",")

/**
Why a table that already exists cannot serve as the store, if it cannot.

🚨 **A table under the right name with the wrong key is worse than no table.** The
deploy finds it, the handlers write into it, and every read misses — a role switch
that reports success and does nothing, which is the defect this whole store was
repaired for. So adoption checks the schema and refuses, rather than reporting
success.

The pre-`clientId` store is exactly this case: keyed on the subject alone. An
operator upgrading meets a sentence instead of a silent misbehaviour.

Order-insensitive, because `DescribeTable` does not promise one.
*/
let keySchemaRefusal = (
  ~tableName: string,
  ~actual: array<(string, string)>,
): option<string> => {
  let actualKey = describeKeySchema(actual)
  let wantedKey = describeKeySchema(expectedKeySchema)
  actualKey == wantedKey
    ? None
    : Some(
        `table "${tableName}" already exists with key schema [${actualKey}], but the active-role store needs [${wantedKey}]. A row written under one key is invisible to a read under the other, so role switching would report success and do nothing. Delete the table if its rows are disposable — they are preferences, and every caller re-chooses on their next switch.`,
      )
}
