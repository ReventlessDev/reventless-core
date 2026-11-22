// The narrow API for visitors, as resources: an AppSync API whose only way in is
// an API key, made for a plugin that declares fields `AllowAnonymous`, and the key.
// What goes into its schema is `AppSync_VisitorSchema`'s.
//
// Per plugin stack, as the plugin's own API is: the plugin's fields are served
// from the plugin's functions and tables.

// ── What a plugin declares ──────────────────────────────────────────────────

// Whether this deployment hosts a narrow API. Where it does not, an anonymous
// field is refused, as it always was.
let hostedRef = ref(false)
let host = () => hostedRef := true
let hosted = () => hostedRef.contents

let fieldsRef = ref(AppSync_VisitorSchema.none)
let fragmentRef: ref<option<Reventless.Plugin.apiSchemaFragment>> = ref(None)

/** The plugin's visitor fields and their schema, said when its fragment is
    generated; read when its APIs are made. */
let register = (
  ~fields: AppSync_VisitorSchema.fields,
  ~fragment: Reventless.Plugin.apiSchemaFragment,
) => {
  fieldsRef := fields
  fragmentRef := Some(fragment)
}

let fields = () => fieldsRef.contents

/** Whether `field` is a visitor mutation, served by the narrow API. */
let servesMutation = (field: string) => fieldsRef.contents.mutations->Array.includes(field)

// ── The resources ───────────────────────────────────────────────────────────

type made = {
  api: Pulumi.Output.t<PulumiAws.AppSync.GraphQLApi.t>,
  role: Pulumi.Output.t<PulumiAws.IAM.Role.t>,
  /** Where a visitor's request goes. */
  endpoint: Pulumi.Output.t<string>,
  /** What it carries as `x-api-key`. Public: it is in the shell's configuration. */
  key: Pulumi.Output.t<string>,
  /** Resolved once the schema is active. */
  schemaPushed: Pulumi.Output.t<unit>,
}

let madeRef: ref<option<made>> = ref(None)
let made = () => madeRef.contents

/** A year from the start of `now`'s day, less a day: the longest a key may live
    is 365 days, and a time that moves only once a day leaves a deploy with nothing
    to change the other times it runs. */
let keyExpiry = (now: Date.t): string => {
  let day = Math.floor(Date.getTime(now) /. 86400000.) *. 86400000.
  Date.fromTime(day +. 364. *. 86400000.)->Date.toISOString->String.slice(~start=0, ~end=19) ++ "Z"
}

/** The API, its role and its key. `pushSchema` puts the schema on the API, by
    its id, and resolves once it is active; the key is made after it, since AppSync
    refuses a key while a schema is being altered. */
let make = (
  ~name: string,
  ~opts: Pulumi.ComponentResource.options,
  ~pushSchema: string => promise<unit>,
): made => {
  let customOpts: Pulumi.CustomResourceOptions.t = {parent: ?opts.parent}
  let role = PulumiAws.IAM.Role.make(
    ~name=`${name}-appsync-role`,
    ~args={
      assumeRolePolicy: `{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"appsync.amazonaws.com"},"Action":"sts:AssumeRole"}]}`->Pulumi.Input.make,
      tags: AWS.Tags.make(
        ~name=`${name}-appsync-role`,
        ~kind=ReventlessCore.ComponentType.Plugin,
        ~role=Identity,
        ~scope=Plugin,
      ),
    },
    ~opts=Some(customOpts),
  )
  let _logs = PulumiAws.IAM.RolePolicyAttachment.make(
    ~name=`${name}-appsync-cwlogs`,
    ~args={
      role: role.name->Pulumi.Output.asInput,
      policyArn: "arn:aws:iam::aws:policy/service-role/AWSAppSyncPushToCloudWatchLogs"->Pulumi.Input.make,
    },
    ~opts=Some(customOpts),
  )
  let api = PulumiAws.AppSync.GraphQLApi.make(
    ~name,
    ~args={
      authenticationType: PulumiAws.AppSync.GraphQLApi.API_KEY->Pulumi.Input.make,
      logConfig: (
        {
          cloudwatchLogsRoleArn: role.arn->Pulumi.Output.asInput,
          fieldLogLevel: PulumiAws.AppSync.GraphQLApi.ERROR->Pulumi.Input.make,
          // An error line would otherwise carry what the visitor sent: an address,
          // a password.
          excludeVerboseContent: true->Pulumi.Input.make,
        }: PulumiAws.AppSync.GraphQLApi.logConfig
      )->Pulumi.Input.make,
      tags: AWS.Tags.make(
        ~name,
        ~kind=ReventlessCore.ComponentType.Plugin,
        ~role=Api,
        ~scope=Plugin,
      ),
    },
    ~opts=Some(customOpts),
  )
  let schemaPushed =
    api.id->Pulumi.Output.flatMap(apiId => pushSchema(apiId)->Pulumi.Output.fromPromise)
  let key = PulumiAws.AppSync.ApiKey.make(
    ~name=`${name}-key`,
    ~args={
      apiId: Pulumi.Output.all2((api.id, schemaPushed))
      ->Pulumi.Output.apply(((apiId, ())) => apiId)
      ->Pulumi.Output.asInput,
      description: "Identifies the deployment to its door for visitors; renewed by each deploy"->Pulumi.Input.make,
      expires: keyExpiry(Date.make())->Pulumi.Input.make,
    },
    ~opts=Some(customOpts),
  )
  let made = {
    api: api->Pulumi.Output.make,
    role: role->Pulumi.Output.make,
    endpoint: api.uris->Pulumi.Output.apply(uris => uris.graphQL),
    key: key.key,
    schemaPushed,
  }
  madeRef := Some(made)
  made
}
