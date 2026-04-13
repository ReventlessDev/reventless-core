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

@val @scope(("process", "env")) external _layerArnEnv: option<string> = "REVENTLESS_LAYER_ARN"
@val @scope("process") external _cwd: unit => string = "cwd"
@module("path") external _pathJoin: (string, string) => string = "join"
@module("path") external _pathDirname: string => string = "dirname"
@module("fs") external _fsExistsSync: string => bool = "existsSync"
@module("fs") external _fsReadFileSync: (string, string) => string = "readFileSync"

/**
 * Returns the Reventless Lambda layer ARN.
 * Priority: REVENTLESS_LAYER_ARN env var → .github/layer-arn[-{stack}].txt walked up from cwd.
 * File name: layer-arn.txt for main, layer-arn-{stack}.txt for all other stacks.
 */
let reventlessLayerArn: option<string> = {
  switch _layerArnEnv {
  | Some(_) as arn => arn
  | None =>
    let stack = Pulumi.Pulumi.getStackName()
    let fileName = stack == "main" ? "layer-arn.txt" : `layer-arn-${stack}.txt`
    let rec find = dir => {
      let candidate = _pathJoin(dir, `.github/${fileName}`)
      if _fsExistsSync(candidate) {
        let content = _fsReadFileSync(candidate, "utf-8")->String.trim
        content->String.length > 0 ? Some(content) : None
      } else {
        let parent = _pathDirname(dir)
        parent == dir ? None : find(parent)
      }
    }
    find(_cwd())
  }
}

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
      ~layers=reventlessLayerArn
      ->Option.map(arn => [arn->Pulumi.Input.make])
      ->Option.getOr([])
      ->Pulumi.Input.make,
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
  }

  type t = {
    arn: Pulumi.Output.t<string>,
    id: Pulumi.Output.t<string>,
    name: Pulumi.Output.t<string>,
    invokeArn: Pulumi.Output.t<string>,
  }

  @module("@pulumi/aws") @scope("lambda") @new
  external make: (
    ~name: string,
    ~args: args,
    ~opts: Pulumi.CustomResourceOptions.t=?,
  ) => t = "Function"

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
