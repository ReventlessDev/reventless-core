//
// NOTE: following functions combine pulumi & aws-sdk -> should stay separated in reventless
//
open AwsSdk;

/** add a user to a given group of a given userPool
  */
let addUserToGroup =
    (
      ~region: string,
      ~userName: string,
      ~groupName: string,
      ~userPoolId: string,
    ) =>
  CognitoIdentityServiceProvider.(
    addUserToGroup(
      make(
        Opts.make(
          ~endpoint=Util_Cognito_Runtime.userPoolEndpoint(region, userPoolId),
          ~region,
        ),
      ),
      ~params=
        AddUserToGroupRequest.make(
          ~_Username=userName,
          ~_GroupName=groupName,
          ~_UserPoolId=userPoolId,
        ),
    )
  )
  ->Request.promise;

/** remove a user from a given group of a given userPool
  */
let removeUserFromGroup =
    (
      ~region: string,
      ~userName: string,
      ~groupName: string,
      ~userPoolId: string,
    ) =>
  CognitoIdentityServiceProvider.(
    removeUserFromGroup(
      make(
        Opts.make(
          ~endpoint=Util_Cognito_Runtime.userPoolEndpoint(region, userPoolId),
          ~region,
        ),
      ),
      ~params=
        RemoveUserFromGroupRequest.make(
          ~_Username=userName,
          ~_GroupName=groupName,
          ~_UserPoolId=userPoolId,
        ),
    )
  )
  ->Request.promise;
