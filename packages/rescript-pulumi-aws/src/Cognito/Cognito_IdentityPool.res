/** @pulumi/aws/cognito/IdentityPool
  see: https://www.pulumi.com/registry/packages/aws/api-docs/cognito/identitypool
  */
type t = {
  arn: Pulumi.Output.t<string>,
  name: Pulumi.Output.t<string>,
  id: Pulumi.Output.t<string>,
  endpoint: Pulumi.Output.t<string>,
}

type cognitoIdentityProvider = {
  clientId: Pulumi.Input.t<string>,
  providerName: Pulumi.Input.t<string>,
  serverSideTokenCheck: Pulumi.Input.t<bool>,
}

type args = {
  allowUnauthenticatedIdentities?: Pulumi.Input.t<bool>,
  cognitoIdentityProviders?: Pulumi.Input.t<array<Pulumi.Input.t<cognitoIdentityProvider>>>,
  identityPoolName: Pulumi.Input.t<string>,
}

@module("@pulumi/aws") @scope("cognito") @new
external make: (~name: string, ~args: args, ~opts: Pulumi.CustomResourceOptions.t=?) => t =
  "IdentityPool"

// FIXME: This is very application Specific and should be split up into generic- and application parts
let make = (
  ~userPoolId: Pulumi.Output.t<string>,
  ~userPoolClientId: Pulumi.Input.t<string>,
  ~name: string /* name of identity pool (pulumi context) */,
  ~bucketArns: array<Pulumi.Output.t<PulumiAws.Aws.arn>>,
  ~allowUnauthenticatedIdentities: bool,
) => {
  /*
     NOTE:
     -) function only supports a single CognitoIdentityProvider
     -) serverSideTokenCheck (for that single CognitoIdentityProvider) is always 'false'
     TODO: for multi CognitoIdentityProvider support:
     -) Output.allx must support multi UserPool.t AND for each UserPool.t also UserPoolClient.t
     -) apply must be adapted to support multi UserPool.t (another structure maybe)
     -) generation of CognitoIdentityProvider for each UserPool.t
     -) identityPoolName generation must be changed/adapted
     WARNING:
     -) importerBucket is not implemented yet!
 */
  let identityPool = make(
    ~name,
    ~args={
      allowUnauthenticatedIdentities: allowUnauthenticatedIdentities->Pulumi.Input.make,
      cognitoIdentityProviders: [
        {
          clientId: userPoolClientId,
          providerName: userPoolId
          ->Pulumi.Output.apply(userPoolId =>
            "cognito-idp" ++
            ("." ++
            (Pulumi.Config.make(Some("aws"))->Pulumi.Config.require("region") ++
              ("." ++
              ("amazonaws.com" ++ ("/" ++ userPoolId)))))
          )
          ->Pulumi.Output.asInput,
          serverSideTokenCheck: false->Pulumi.Input.make,
        }->Pulumi.Input.make,
      ]->Pulumi.Input.make,
      identityPoolName: userPoolId
      ->Pulumi.Output.apply(userPoolId => "IdentityPool for " ++ userPoolId)
      ->Pulumi.Output.asInput,
    },
  )

  let role = IAM.Role.make(
    ~name="IdentityPoolAuthRole",
    ~args={
      IAM.Role.assumeRolePolicy: identityPool.id
      ->Pulumi.Output.apply(identityPoolId =>
        `{
          "Version": "2012-10-17",
          "Statement": [
            {
              "Effect": "Allow",
              "Principal": {
                "Federated": "cognito-identity.amazonaws.com"
              },
              "Action": "sts:AssumeRoleWithWebIdentity",
              "Condition": {
                "ForAnyValue:StringEquals": {
                  "cognito-identity.amazonaws.com:aud": [
                    "${identityPoolId}"
                  ]
                },
                "ForAnyValue:StringLike": {
                  "cognito-identity.amazonaws.com:amr": "authenticated"
                }
              }
            }
          ]
        }`
      )
      ->Pulumi.Output.asInput,
    },
  )

  let _roleAttachment = Cognito_IdentityPoolRoleAttachment.make(
    ~name="IdentityPool",
    ~args={
      Cognito_IdentityPoolRoleAttachment.identityPoolId: identityPool.id->Pulumi.Output.asInput,
      roles: {
        Cognito_IdentityPoolRoleAttachment.authenticated: role.arn->Pulumi.Output.asInput,
      }->Pulumi.Input.make,
    },
  )
  ()

  let toResource = arn => arn->Pulumi.Output.apply(arn => arn ++ "/*")

  let _rolePolicy = if bucketArns->Array.length > 0 {
    {
      IAM.RolePolicy.make(
        ~name="IdentityPool",
        ~args={
          IAM.RolePolicy.policy: bucketArns
          ->Array.map(toResource)
          ->Pulumi.Output.all
          ->Pulumi.Output.apply(resourceArns =>
            PolicyDocument.make(
              ~id=name ++ "Policy",
              ~statements=[
                {
                  sid: "AllowGetObject",
                  effect: PolicyDocument.Allow,
                  actions: PolicyDocument.Actions(["s3:GetObject"]),
                  resources: PolicyDocument.Resources(resourceArns),
                },
              ],
            )->PolicyDocument.toJsonString
          )
          ->Pulumi.Output.asInput,
          role: role.id->Pulumi.Output.asInput,
        },
      )
    }->Some
  } else {
    None
  }

  identityPool
}
