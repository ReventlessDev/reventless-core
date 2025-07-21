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
  @as("Custom") custom: option<Js.Json.t>,
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

type eventHandler<'event, 'result> = ('event, context) => Js.Promise.t<'result>
type eventHandlerNoResult<'event> = eventHandler<'event, unit>

@send
external getRemainingTimeInMillis: context => int = "getRemainingTimeInMillis"

@val
external reventlessLayerArn: option<string> = "process.env.REVENTLESS_LAYER_ARN"
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
      Default node runtime: 18
     */
    type runtime = | @as("nodejs18.x") NodeJs18

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
      defaults: memorySize=128, timeout=180, runtime=NodeJs18
      */
    let make = (
      ~callback,
      ~role=?,
      ~policies=?,
      ~deadLetterConfig=?,
      ~tracingConfig=?,
      ~memorySize=128->Pulumi.Input.make,
      ~timeout=180->Pulumi.Input.make,
      ~runtime=NodeJs18,
      ~layers=reventlessLayerArn
      ->Option.map(arn => [arn->Pulumi.Input.make])
      ->Option.getOr([])
      ->Pulumi.Input.make,
      ~vpcConfig=?,
      ~tags=?,
      ~environment={
        variables: [("Environment", Pulumi.Pulumi.getStackName())]->Js.Dict.fromArray,
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
