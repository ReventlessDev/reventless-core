/** @pulumi/aws/lambda/functionurl
  see: https://www.pulumi.com/registry/packages/aws/api-docs/lambda/functionurl/
*/
type authorizationType =
  | @as("AWS_IAM") AwsIam
  | @as("NONE") None

type invokeMode =
  | @as("BUFFERED") Buffered
  | @as("RESPONSE_STREAM") ResponseStream

type cors = {
  allowCredentials?: Pulumi.Input.t<bool>,
  allowHeaders?: Pulumi.Input.t<array<Pulumi.Input.t<string>>>,
  allowMethods?: Pulumi.Input.t<array<Pulumi.Input.t<string>>>,
  allowOrigins?: Pulumi.Input.t<array<Pulumi.Input.t<string>>>,
  exposeHeaders?: Pulumi.Input.t<array<Pulumi.Input.t<string>>>,
  maxAge?: Pulumi.Input.t<int>,
}

type args = {
  authorizationType: authorizationType,
  functionName: Pulumi.Input.t<string>,
  cors?: Pulumi.Input.t<cors>,
  invokeMode?: invokeMode,
  qualifier?: Pulumi.Input.t<string>,
}

type t = {
  functionArn: Pulumi.Output.t<string>,
  functionUrl: Pulumi.Output.t<string>,
  urlId: Pulumi.Output.t<string>,
}

@module("@pulumi/aws") @scope("lambda") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "FunctionUrl"

@module("@pulumi/aws") @scope(("lambda", "FunctionUrl"))
external get: (~name: string, ~id: Pulumi.Input.t<string>, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "get"
