// The limit on the narrow API for visitors, as resources. Two layers:
//
// - **The exact limit** is the function's: each door and each view for visitors
//   asks it, per source address, counted in the table made here.
// - **A coarse ceiling** is a firewall's: a rate rule on the narrow API only, set
//   well above the exact limit, so a flood from one source is turned away before
//   it runs a function. Its windows cannot express the configured one, which is
//   why it is the ceiling and not the limit.

// The configured limit as the platform exports it (`""`: the default), said by
// the plugin deploy before the plugin is built.
let configuredRef: ref<Pulumi.Output.t<string>> = ref(Pulumi.Output.make(""))
let configure = (limit: Pulumi.Output.t<string>) => configuredRef := limit

// ── The table the function counts in ────────────────────────────────────────

let tableRef: ref<option<Stash_DynamoDb_Table.table>> = ref(None)

/** The plugin stack's count table, made on first need. The stash table's shape:
    one item per key, removed after its time, and no backup of it. */
let table = (~opts: Pulumi.ComponentResource.options): Stash_DynamoDb_Table.table =>
  switch tableRef.contents {
  | Some(table) => table
  | None =>
    let table = Stash_DynamoDb_Table.make(~name="VisitorLimit", ~opts)
    tableRef := Some(table)
    table
  }

/** What the function may do on the count table: the one call the limiter makes. */
let actions = ["dynamodb:UpdateItem"]

let policy = (~id: string, arn: string): string => {
  open PulumiAws.PolicyDocument
  PulumiAws.PolicyDocument.make(
    ~id,
    ~statements=[
      {
        sid: "AllowCountingVisitorRequests",
        effect: Allow,
        actions: Actions(actions),
        resources: Resource(arn),
      },
    ],
  )->PulumiAws.PolicyDocument.toJsonString
}

// ── The step before a view's read ───────────────────────────────────────────

type dataSource = {name: Pulumi.Output.t<string>}
let dataSourceRef: ref<option<dataSource>> = ref(None)

/** The narrow API's data source for the plugin's command function, which counts:
    made once, with a role that may invoke that function. None while the plugin
    has no such function. */
let dataSource = (
  ~visitors: AppSync_VisitorApi.made,
  ~opts: Pulumi.CustomResourceOptions.t,
): option<dataSource> =>
  switch (dataSourceRef.contents, DcbCommandFunctions.functions->Array.get(0)) {
  | (Some(made), _) => Some(made)
  | (None, None) => None
  | (None, Some(fn)) =>
    let role = PulumiAws.IAM.Role.makeWithDefaultPolicy(
      ~name="VisitorLimitDS",
      ~servicePrincipal=AWS.AppSync.principal->Pulumi.Output.make,
      ~tags=AWS.Tags.make(
        ~name="VisitorLimitDS",
        ~kind=ReventlessCore.ComponentType.Plugin,
        ~role=Identity,
        ~scope=Plugin,
      ),
      ~opts,
    )
    let _invoke = PulumiAws.IAM.RolePolicy.make(
      ~name="VisitorLimitDS",
      ~args={
        policy: fn.functionArn
        ->Pulumi.Output.apply(arn => {
          open PulumiAws.PolicyDocument
          PulumiAws.PolicyDocument.make(
            ~id="VisitorLimitDSPolicy",
            ~statements=[
              {
                sid: "AllowAskingTheLimit",
                effect: Allow,
                actions: Action("lambda:InvokeFunction"),
                resources: Resource(arn),
              },
            ],
          )->PulumiAws.PolicyDocument.toJsonString
        })
        ->Pulumi.Output.asInput,
        role: role.id->Pulumi.Output.asInput,
      },
      ~opts,
    )
    let made = {
      name: PulumiAws.AppSync.DataSource.make(
        ~name="VisitorLimit",
        ~args={
          type_: AWS_LAMBDA,
          apiId: visitors.api->Pulumi.Output.flatMap(api => api.id)->Pulumi.Output.asInput,
          lambdaConfig: {
            PulumiAws.AppSync.DataSource.functionArn: fn.functionArn->Pulumi.Output.asInput,
          }->Pulumi.Input.make,
          serviceRoleArn: role.arn->Pulumi.Output.asInput,
        },
        ~opts=Some(opts),
      ).name,
    }
    dataSourceRef := Some(made)
    Some(made)
  }

// The view whose resolvers are being made on the narrow API, set by the code
// that routes them there for the time it makes them: each of its Query
// resolvers then begins with the limit's step.
let guardedRef: ref<option<(AppSync_VisitorApi.made, string)>> = ref(None)

/** Runs `make` with every Query resolver it creates guarded as `door`. */
let guarding = (~visitors: AppSync_VisitorApi.made, ~door: string, make: unit => 'a): 'a => {
  guardedRef := Some((visitors, door))
  let made = try make() catch {
  | exn =>
    guardedRef := None
    throw(exn)
  }
  guardedRef := None
  made
}

/** The limit's step for the resolver `resolverName`, while a view is guarded. A
    view for visitors with no function to count in is refused: it would be read
    without limit. */
let step = (~resolverName: string, ~opts: Pulumi.CustomResourceOptions.t): option<
  PulumiAws.AppSync.Function.t,
> =>
  switch guardedRef.contents {
  | None => None
  | Some((visitors, door)) =>
    switch dataSource(~visitors, ~opts) {
    | None =>
      JsError.throwWithMessage(
        `${door}: a view for visitors is counted per source by the plugin's command function, and this plugin has none`,
      )
    | Some(ds) =>
      Some(
        PulumiAws.AppSync.Function.makeJs(
          ~name=resolverName ++ "Limit",
          ~api=visitors.api,
          ~dataSource=ds.name->Pulumi.Output.asInput,
          ~code=AppSync_VisitorCode.limitStep(door),
          ~opts,
        ),
      )
    }
  }

// ── The firewall's ceiling ──────────────────────────────────────────────────

/** Requests one source may make to the narrow API in five minutes before the
    firewall turns it away: ten times what the exact limit allows in its whole
    window, and never under 100, the least a rate rule counts reliably at. */
let ceiling = (limit: Reventless.AnonymousRequestLimit.t): int =>
  Math.Int.max(100, limit.requests * 10)

let rateRule = (~name: string, ~ceiling: int): JSON.t =>
  JSON.parseOrThrow(
    `{
    "name": "${name}",
    "priority": 0,
    "action": {"block": {}},
    "statement": {
      "rateBasedStatement": {
        "limit": ${ceiling->Int.toString},
        "evaluationWindowSec": 300,
        "aggregateKeyType": "IP"
      }
    },
    "visibilityConfig": {
      "cloudwatchMetricsEnabled": true,
      "metricName": "${name}",
      "sampledRequestsEnabled": false
    }
  }`,
  )

/** The rate rule on the narrow API, and on no other. `limit` is the configured
    one as the platform exports it (`""`: the default). */
let makeCeiling = (
  ~name: string,
  ~visitors: AppSync_VisitorApi.made,
  ~limit: Pulumi.Output.t<string>=configuredRef.contents,
  ~opts: Pulumi.ComponentResource.options,
) => {
  let customOpts: Pulumi.CustomResourceOptions.t = {parent: ?opts.parent}
  let acl = PulumiAws.WafV2.WebAcl.make(
    ~name=`${name}Ceiling`,
    ~args={
      scope: "REGIONAL",
      description: "Turns a flood from one source away from the door for visitors",
      defaultAction: JSON.parseOrThrow(`{"allow": {}}`),
      rules: limit
      ->Pulumi.Output.apply(raw => {
        let configured = switch raw {
        | "" => Reventless.AnonymousRequestLimit.default
        | raw =>
          switch Reventless.AnonymousRequestLimit.parse(raw) {
          | Ok(limit) => limit
          | Error(message) => JsError.throwWithMessage(message)
          }
        }
        [rateRule(~name=`${name}RatePerSource`, ~ceiling=ceiling(configured))]
      })
      ->Pulumi.Output.asInput,
      // No sampled requests: a sample holds the caller's address.
      visibilityConfig: JSON.parseOrThrow(
        `{"cloudwatchMetricsEnabled": true, "metricName": "${name}Ceiling", "sampledRequestsEnabled": false}`,
      ),
      tags: AWS.Tags.make(
        ~name=`${name}Ceiling`,
        ~kind=ReventlessCore.ComponentType.Plugin,
        ~role=Api,
        ~scope=Plugin,
      ),
    },
    ~opts=Some(customOpts),
  )
  let _ = PulumiAws.WafV2.WebAclAssociation.make(
    ~name=`${name}Ceiling`,
    ~args={
      resourceArn: visitors.api->Pulumi.Output.flatMap(api => api.arn)->Pulumi.Output.asInput,
      webAclArn: acl.arn->Pulumi.Output.asInput,
    },
    ~opts=Some(customOpts),
  )
}
