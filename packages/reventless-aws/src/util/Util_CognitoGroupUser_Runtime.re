//
// NOTE: following functions combine pulumi & aws-sdk -> should stay separated in reventless
//

/** add a user to a given group of a given userPool
  */
let addUserToGroup =
    (
      ~region: string,
      ~userName: string,
      ~groupName: string,
      ~userPool: PulumiAws.Cognito.UserPool.t,
    ) =>
  AwsSdk.CognitoIdentityServiceProvider.addUserToGroup(
    AwsSdk.CognitoIdentityServiceProvider.make(
      AwsSdk.CognitoIdentityServiceProvider.Opts.make(
        ~endpoint=userPool##endpoint->Pulumi.Output.get,
        ~region,
      ),
    ),
    ~params=
      AwsSdk.CognitoIdentityServiceProvider.AddUserToGroupRequest.make(
        ~_Username=userName,
        ~_GroupName=groupName,
        ~_UserPoolId=userPool##id->Pulumi.Output.get,
      ),
  )
  ->AwsSdk.Request.promise;

/** remove a user from a given group of a given userPool
  */
let removeUserFromGroup =
    (
      ~region: string,
      ~userName: string,
      ~groupName: string,
      ~userPool: PulumiAws.Cognito.UserPool.t,
    ) =>
  AwsSdk.CognitoIdentityServiceProvider.(
    removeUserFromGroup(
      make(
        Opts.make(~endpoint=userPool##endpoint->Pulumi.Output.get, ~region),
      ),
      ~params=
        RemoveUserFromGroupRequest.make(
          ~_Username=userName,
          ~_GroupName=groupName,
          ~_UserPoolId=userPool##id->Pulumi.Output.get,
        ),
    )
  )
  ->AwsSdk.Request.promise;