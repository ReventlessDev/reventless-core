/** @pulumi/aws/lambda
  see: https://www.pulumi.com/registry/packages/aws/api-docs/lambda
*/
type cognitoIdentity = {cognitoIdentityId: string, cognitoIdentityPoolId: string}

type clientContextClient = {
  installationId: string,
  appTitle: string,
  appVersionName: string,
  appVersionCode: string,
  appPackageName: string,
}

type clientContextEnv = {
  platformVersion: string,
  platform: string,
  make: string,
  model: string,
  locale: string,
}

type clientContext = {
  client: clientContextClient,
  @as("Custom") custom: option<JSON.t>,
  env: clientContextEnv,
}

type context = {
  callbackWaitsForEmptyEventLoop: bool,
  functionName: string,
  functionVersion: string,
  invokedFunctionArn: string,
  memoryLimitInMB: int,
  awsRequestId: string,
  logGroupName: string,
  logStreamName: string,
  identity?: cognitoIdentity,
  clientContext?: clientContext,
}

type userIdentity = {principalId: string}

type eventHandler<'event, 'result> = ('event, context) => promise<'result>
type eventHandlerNoResult<'event> = eventHandler<'event, unit>

@send
external getRemainingTimeInMillis: context => int = "getRemainingTimeInMillis"

/** The outcome of looking for the Reventless layer. `region` is `None` when
    neither the stack nor the environment names one, and the AWS CLI's default
    region was asked. */
type layerLookup =
  | Found(string)
  | NotFound({parameter: string, region: option<string>})
  | CouldNotLook({parameter: string, region: option<string>, reason: string})

let layerParameter = stack => `/reventless/layer-arn/${stack}`

let _nonEmpty = value =>
  switch value->Option.map(String.trim) {
  | Some("") | None => None
  | trimmed => trimmed
  }

let _lookupRegion = () =>
  switch Pulumi.Config.make(Some("aws"))->Pulumi.Config.get("region")->_nonEmpty {
  | Some(_) as region => region
  | None =>
    switch NodeProcess.env->Dict.get("AWS_REGION")->_nonEmpty {
    | Some(_) as region => region
    | None => NodeProcess.env->Dict.get("AWS_DEFAULT_REGION")->_nonEmpty
    }
  }

let _firstLine = text =>
  text
  ->String.split("\n")
  ->Array.map(String.trim)
  ->Array.find(line => line !== "")
  ->Option.getOr("the AWS CLI exited without saying why")

/** Reads the result of `aws ssm get-parameter`: only `ParameterNotFound` means
    there is no layer; a missing CLI or a refused call means nobody could tell. */
let classifySsmLookup = (
  ~parameter,
  ~region,
  result: NodeChildProcess.spawnSyncResult,
): layerLookup => {
  let stderr = result.stderr->Nullable.toOption->Option.getOr("")
  switch (result.error->Nullable.toOption, result.status->Nullable.toOption) {
  | (Some(error), _) =>
    let message = error->JsExn.message->Option.getOr("unknown error")
    CouldNotLook({parameter, region, reason: `the AWS CLI could not be run (${message})`})
  | (None, Some(0)) =>
    switch result.stdout->Nullable.toOption->_nonEmpty {
    | None | Some("None") => NotFound({parameter, region})
    | Some(arn) => Found(arn)
    }
  | (None, _) if stderr->String.includes("ParameterNotFound") => NotFound({parameter, region})
  | (None, _) => CouldNotLook({parameter, region, reason: _firstLine(stderr)})
  }
}

let _lookupInSsm = (): layerLookup => {
  let parameter = layerParameter(Pulumi.Pulumi.getStackName())
  let region = _lookupRegion()
  let regionArgs = region->Option.mapOr([], region => ["--region", region])
  NodeChildProcess.spawnSync(
    "aws",
    [
      "ssm",
      "get-parameter",
      "--name",
      parameter,
      "--query",
      "Parameter.Value",
      "--output",
      "text",
    ]->Array.concat(regionArgs),
    {encoding: "utf8"},
  )->classifySsmLookup(~parameter, ~region, _)
}

let _lookup: ref<option<layerLookup>> = ref(None)

/** Looks once per deploy: `REVENTLESS_LAYER_ARN` when set (CI exports it),
    otherwise the stack's SSM parameter through the AWS CLI, in the stack's
    `aws:region` when it sets one. */
let lookupLayer = (): layerLookup =>
  switch _lookup.contents {
  | Some(lookup) => lookup
  | None =>
    let lookup = switch NodeProcess.env->Dict.get("REVENTLESS_LAYER_ARN")->_nonEmpty {
    | Some(arn) => Found(arn)
    | None => _lookupInSsm()
    }
    _lookup := Some(lookup)
    lookup
  }

let _regionName = region =>
  region->Option.mapOr("the AWS CLI's default region", region => `region ${region}`)

let _publishHint = `Publish the layer and store its ARN in that parameter, or set REVENTLESS_LAYER_ARN: https://docs.reventless.dev/infrastructure/aws/get-started#the-lambda-layer`

/** Why a deploy cannot go on without the layer, or `None` when it was found. */
let missingLayerMessage = lookup =>
  switch lookup {
  | Found(_) => None
  | NotFound({parameter, region}) =>
    Some(
      `No Reventless Lambda layer: the SSM parameter ${parameter} does not exist in ${_regionName(
          region,
        )}. Without the layer every function fails with "Cannot find package" on its first run. ${_publishHint}`,
    )
  | CouldNotLook({parameter, region, reason}) =>
    Some(
      `Could not look up the Reventless Lambda layer in the SSM parameter ${parameter} (${_regionName(
          region,
        )}): ${reason}. ${_publishHint}`,
    )
  }

/** The layer's ARN. Throws with `missingLayerMessage` when there is none, so a
    function is never created without the framework code it imports. */
let reventlessLayerArn = (): string =>
  switch lookupLayer() {
  | Found(arn) => arn
  | lookup =>
    JsError.throwWithMessage(
      missingLayerMessage(lookup)->Option.getOr("No Reventless Lambda layer"),
    )
  }

/** The `layers` argument of every framework function. */
let reventlessLayers = (): Pulumi.Input.t<array<Pulumi.Input.t<string>>> =>
  [reventlessLayerArn()->Pulumi.Input.make]->Pulumi.Input.make

@val
external environment: option<string> = "process.env.Environment"

module CallbackFunction = {
  module Args = {
    type deadLetterConfig = {targetArn: string}

    type mode = Active | PassThrough
    type tracingConfig = {mode: mode}

    type vpcConfig = {
      securityGroupIds: array<string>,
      subnetIds: array<string>,
      vpcId?: string,
    }

    type functionEnvironment = {variables?: dict<string>}

    /**
      Default node runtime: 22
     */
    type runtime =
      | @as("nodejs20.x") NodeJs20
      | @as("nodejs22.x") NodeJs22

    type t<'event, 'result> = {
      callback: eventHandler<'event, 'result>,
      runtime?: runtime,
      role?: IAM.Role.t,
      policies?: string,
      deadLetterConfig?: Pulumi.Input.t<deadLetterConfig>,
      tracingConfig?: Pulumi.Input.t<tracingConfig>,
      memorySize?: Pulumi.Input.t<int>,
      timeout?: Pulumi.Input.t<int>,
      layers?: Pulumi.Input.t<array<Pulumi.Input.t<string>>>,
      vpcConfig?: Pulumi.Input.t<vpcConfig>,
      tags?: Pulumi.Input.t<Aws.tags>,
      environment?: functionEnvironment,
    }

    /**
      defaults: memorySize=1024, timeout=180, runtime=NodeJs22

      The 1024MB memory default is optimal for Node.js Lambdas with AWS SDK v3,
      balancing cost and performance. Lower values cause slow cold starts when
      loading multiple AWS SDK clients; higher values increase cost without
      significant benefit for most workloads.
      */
    let make = (
      ~callback,
      ~role=?,
      ~policies=?,
      ~deadLetterConfig=?,
      ~tracingConfig=?,
      ~memorySize=1024->Pulumi.Input.make,
      ~timeout=180->Pulumi.Input.make,
      ~runtime=NodeJs22,
      ~layers=reventlessLayers(),
      ~vpcConfig=?,
      ~tags=?,
      ~environment={
        variables: [("Environment", Pulumi.Pulumi.getStackName())]->Dict.fromArray,
      },
    ) => {
      callback,
      runtime,
      ?policies,
      ?deadLetterConfig,
      ?tracingConfig,
      ?role,
      memorySize,
      timeout,
      layers,
      ?vpcConfig,
      ?tags,
      environment,
    }
  }

  type record = {eventSource: string, eventSourceARN: string}
  type event = {@as("Records") records: array<record>}
  type eventHandler = eventHandler<event, unit>

  type t = {
    arn: Pulumi.Output.t<string>,
    id: Pulumi.Output.t<string>,
    name: Pulumi.Output.t<string>,
  }

  @module("@pulumi/aws") @scope("lambda") @new
  external make: (
    ~name: string,
    ~args: Args.t<'event, 'result>,
    ~opts: Pulumi.CustomResourceOptions.t=?,
  ) => t = "CallbackFunction"

  @module("@pulumi/aws") @scope(("lambda", "Function"))
  external get: (
    ~name: string,
    ~id: Pulumi.Input.t<string>,
    ~opts: Pulumi.CustomResourceOptions.t=?,
  ) => t = "get"
}

module Function = {
  type functionEnvironment = {variables?: dict<Pulumi.Input.t<string>>}

  type ephemeralStorage = {size: Pulumi.Input.t<int>}

  /** Places the function inside a VPC so it can reach private resources such as
    RDS/Aurora. Adds ENIs to the given subnets and attaches the security
    groups; the execution role then needs `ec2:CreateNetworkInterface`,
    `ec2:DescribeNetworkInterfaces`, `ec2:DeleteNetworkInterface`. */
  type vpcConfig = {
    subnetIds: Pulumi.Input.t<array<Pulumi.Input.t<string>>>,
    securityGroupIds: Pulumi.Input.t<array<Pulumi.Input.t<string>>>,
  }

  /** Advanced Logging Controls. Naming `logGroup` here is what lets a deploy own
    the group: the function writes to a group the program created, so Lambda
    never lazily auto-creates `/aws/lambda/<physical name>` on first invocation
    and there is no window in which the two can race.

    `logFormat` is required by the provider. `Text` is AWS's own default and
    leaves the emitted lines byte-identical; `JSON` wraps every application line
    in an envelope, and is the only mode in which `applicationLogLevel` /
    `systemLogLevel` apply. */
  type loggingConfig = {
    logFormat: Pulumi.Input.t<string>,
    logGroup?: Pulumi.Input.t<string>,
    applicationLogLevel?: Pulumi.Input.t<string>,
    systemLogLevel?: Pulumi.Input.t<string>,
  }

  type args = {
    handler?: Pulumi.Input.t<string>,
    runtime?: Pulumi.Input.t<string>,
    code?: Pulumi.Input.t<Pulumi.Archive.t>,
    role: Pulumi.Input.t<string>,
    memorySize?: Pulumi.Input.t<int>,
    timeout?: Pulumi.Input.t<int>,
    layers?: Pulumi.Input.t<array<Pulumi.Input.t<string>>>,
    tags?: Pulumi.Input.t<Aws.tags>,
    environment?: Pulumi.Input.t<functionEnvironment>,
    sourceCodeHash?: Pulumi.Input.t<string>,
    reservedConcurrentExecutions?: Pulumi.Input.t<int>,
    ephemeralStorage?: Pulumi.Input.t<ephemeralStorage>,
    vpcConfig?: Pulumi.Input.t<vpcConfig>,
    loggingConfig?: Pulumi.Input.t<loggingConfig>,
  }

  type t = {
    arn: Pulumi.Output.t<string>,
    id: Pulumi.Output.t<string>,
    name: Pulumi.Output.t<string>,
    invokeArn: Pulumi.Output.t<string>,
    /** When AWS last wrote the function. Server-computed and different after
        every code update, which is what separates it from the four identifiers
        above: those are equal before and after, so the engine can resolve them
        from existing state without waiting for the update. Depend on this one to
        wait for the new code to actually be live. */
    lastModified: Pulumi.Output.t<string>,
  }

  @module("@pulumi/aws") @scope("lambda") @new
  external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
    "Function"

  @module("@pulumi/aws") @scope(("lambda", "Function"))
  external get: (
    ~name: string,
    ~id: Pulumi.Input.t<string>,
    ~opts: Pulumi.CustomResourceOptions.t=?,
  ) => t = "get"
}

module Permission = {
  type args = {
    action: string,
    function: Pulumi.Input.t<string>,
    principal: string,
    statementId?: string,
    sourceArn?: Pulumi.Input.t<string>,
  }

  type t = {"arn": Pulumi.Output.t<string>, "id": Pulumi.Output.t<string>}
  @module("@pulumi/aws") @scope("lambda") @new
  external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
    "Permission"
}

module Invocation = {
  /** `aws.lambda.Invocation` — invokes the function **during `pulumi up`** (a
    data-plane action, not a control-plane resource) and re-invokes whenever
    `input` or `triggers` change. Used for one-shot deploy-time work such as
    running a schema migration from inside the target VPC, so the deploy runner
    itself needs no network path to the private resource. */
  type args = {
    functionName: Pulumi.Input.t<string>,
    /** JSON string passed as the Lambda event payload. */
    input: Pulumi.Input.t<string>,
    /** Optional map whose changes force a re-invocation independently of `input`. */
    triggers?: Pulumi.Input.t<dict<string>>,
    qualifier?: Pulumi.Input.t<string>,
  }

  type t = {
    id: Pulumi.Output.t<string>,
    /** The function's JSON response, as a string. */
    result: Pulumi.Output.t<string>,
  }

  @module("@pulumi/aws") @scope("lambda") @new
  external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
    "Invocation"
}

let defaultLoggingPolicyDocument = PolicyDocument.make(
  ~statements=[
    {
      sid: "DefaultLambdaLoggingPolicy",
      effect: Allow,
      actions: Actions(["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]),
      resources: Resource("arn:aws:logs:*:*:*"),
    },
  ],
)
