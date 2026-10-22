// The rows mapping a Cognito `sub` to the domain's own user id, and where they
// live. Read by the pre-token-generation trigger on every mint, written only
// when an account is created (`provision-accounts`, and the Cognito identity
// provider when it exists).
//
// 🚨 **The rows follow the identity provider, not the stack**, exactly as the
// active-role store's do and for the same reason: a pool holds one pre-token
// trigger, so two stacks sharing a pool with a table each would have the winning
// trigger reading rows the other stack wrote nowhere near. A stack that owns its
// pool owns this table; a stack handed an `identityProviderId` looks it up at
// [Auth_IdentityStore_Schema.derivedStoreName] and never creates it.

type storeTable = Auth_ActiveRoleStore.storeTable

/** Which store a deployment's trigger reads. Total and pure, like the active-role
    store's: whether the provider is ours decides it, and nothing else. */
let chooseStore = (~identityProviderId: option<string>): Auth_ActiveRoleStore.storeChoice =>
  switch identityProviderId {
  | None => StackScoped
  | Some(id) => ProviderScoped(Auth_IdentityStore_Schema.derivedStoreName(~identityProviderId=id))
  }

/** One row per subject — the key schema is [Auth_IdentityStore_Schema]'s — plus
    `userId`, the domain id minted for it. */
let makeTable = (
  ~name: string="IdentityStore",
  ~opts: Pulumi.ComponentResource.options,
): storeTable => {
  let opts = opts->ReventlessCore.Util.Pulumi.ComponentResourceOptions.toCustomResourceOptions
  let table = Util_DynamoDb.makeTable(
    ~attributes=[{name: Auth_IdentityStore_Schema.partitionKey, type_: "S"}],
    ~tags=AWS.Tags.make(
      ~name=name ++ "Table",
      ~kind=ReventlessCore.ComponentType.Platform,
      ~role=Auth,
      ~scope=Platform,
    ),
    ~opts,
    name,
  )
  {name: table.name, arn: table.arn}
}

/** The store a resolved provider calls for — created or looked up. */
let resolveTable = (
  ~choice: Auth_ActiveRoleStore.storeChoice,
  ~opts: Pulumi.ComponentResource.options,
): storeTable =>
  switch choice {
  | StackScoped => makeTable(~opts)
  | ProviderScoped(tableName) => Auth_ActiveRoleStore.lookupTable(~tableName)
  }
