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

let log = ReventlessCore.Logger.fromEnv()

/**
The [ProviderScoped] table if `provision-identity` has created it, else an empty
name and ARN.

🚨 **Absent is a supported state, not a failed lookup** — unlike the active-role
store, which a supplied pool has always had. A pool provisioned before this store
existed has no table, and its deployments must keep deploying: the trigger then
adds no claim and every account keeps its `sub`, which is exactly what each one
did before. Running `provision-identity` again creates the table, and the next
deploy picks it up. A Pulumi `getTable` fails the whole program on a missing
table, so this asks DynamoDB directly.
*/
let lookupTableIfPresent = (~tableName: string): storeTable => {
  let arn = Pulumi.Output.make(tableName)->Pulumi.Output.flatMap(name =>
    (
      async () =>
        try {
          let out = await AwsSdk.DynamoDb_DynamoDb.DescribeTableCommand.make({
            tableName: name,
          })->AwsSdk.DynamoDb_DynamoDb.DescribeTableCommand.send
          out.table->Option.flatMap(t => t.tableArn)->Option.getOr("")
        } catch {
        | exn if Util_AwsError.isNotFound(exn) =>
          log.warn(
            ~comp="IdentityStore",
            `no identity store "${name}" on this provider — accounts keep their pool id. Run provision-identity to create it.`,
          )
          ""
        }
    )()->Pulumi.Output.fromPromise
  )
  {
    name: arn->Pulumi.Output.apply(found => found == "" ? "" : tableName),
    arn,
  }
}

/** The store a resolved provider calls for — created, or looked up if present. */
let resolveTable = (
  ~choice: Auth_ActiveRoleStore.storeChoice,
  ~opts: Pulumi.ComponentResource.options,
): storeTable =>
  switch choice {
  | StackScoped => makeTable(~opts)
  | ProviderScoped(tableName) => lookupTableIfPresent(~tableName)
  }
