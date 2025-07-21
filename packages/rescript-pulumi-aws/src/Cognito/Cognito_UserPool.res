/** @pulumi/aws/cognit/UserPool
  see: https://www.pulumi.com/registry/packages/aws/api-docs/cognito/userpool
*/
open Pulumi

type t = {
  arn: Output.t<string>,
  name: Output.t<string>,
  id: Output.t<string>,
  endpoint: Output.t<string>,
}

@module("@pulumi/aws") @scope(("cognito", "UserPool"))
external get: (~name: string, ~id: Input.t<string>, ~opts: CustomResourceOptions.t=?) => t = "get"

type userAttributes = dict<string>

type lambdaConfig = {
  createAuthChallenge?: Input.t<string>,
  customMessage?: Input.t<string>,
  defineAuthChallenge?: Input.t<string>,
  postAuthentication?: Input.t<string>,
  postConfirmation?: Input.t<string>,
  preAuthentication?: Input.t<string>,
  preSignUp?: Input.t<string>,
  preTokenGeneration?: Input.t<string>,
  userMigration?: Input.t<string>,
  verifyAuthChallengeResponse?: Input.t<string>,
}

type args = {
  name?: Input.t<string>,
  lambdaConfig?: Input.t<lambdaConfig>,
  tags?: Input.t<Aws.tags>,
}

@module("@pulumi/aws") @scope("cognito") @new
external make: (~name: string, ~args: args=?, ~opts: CustomResourceOptions.t=?) => t = "UserPool"
@module("@pulumi/aws") @scope("cognito") @new
external makeWithOptions: (
  ~name: string,
  ~args: option<args>,
  ~opts: option<CustomResourceOptions.t>,
) => t = "UserPool"

type triggerSource = PreSignUp_SignUp | PreSignUp_AdminCreateUser // TODO: add other trigger sources
type request = {userAttributes: userAttributes} // TODO: add other request params
type response = {autoConfirmUser?: bool} // TODO: add other response params
type event = {triggerSource: triggerSource, request: request, response: response}

let makeAutoCommiting: (~name: string, ~args: args=?, ~opts: CustomResourceOptions.t=?) => t = (
  ~name,
  ~args=?,
  ~opts=?,
) => {
  let autoCommitUser: Lambda.eventHandler<event, event> = async (event: event, _) => {
    {...event, response: {autoConfirmUser: true}}
  }

  let autoCommitLambda = Lambda.CallbackFunction.make(
    ~name="autoCommitUser" ++ name,
    ~args=Lambda.CallbackFunction.Args.make(
      ~callback=autoCommitUser,
      ~policies=Lambda.defaultLoggingPolicyDocument->PolicyDocument.toJsonString,
    ),
    ~opts?,
  )

  let autoCommitArn = autoCommitLambda.arn

  let _attachAutoCommitPermission = autoCommitLambda.name->Output.apply(autoCommitLambdaName => {
    Lambda.Permission.make(
      ~name="autoCommitPermission",
      ~args={
        action: "lambda:InvokeFunction",
        function: autoCommitLambdaName->Input.make,
        principal: "cognito-idp.amazonaws.com",
      },
    )
  })

  let lambdaConfig = {preSignUp: autoCommitArn->Output.asInput}
  let args = switch args {
  | None => {lambdaConfig: lambdaConfig->Input.make}->Some
  | Some(args) =>
    {
      name: ?args.name,
      lambdaConfig: lambdaConfig->Input.make,
      tags: ?args.tags,
    }->Some
  }
  makeWithOptions(~name, ~args, ~opts)
}
