// NOTE: following functions combine pulumi & aws-sdk -> should stay separated in reventless

open AwsSdk

@ocaml.doc(" add a user to a given group of a given userPool
  ")
let addUserToGroup = (
  ~region: string,
  ~userName: string,
  ~groupName: string,
  ~userPoolId: string,
) => {
  open CognitoIdentityServiceProvider
  addUserToGroup(
    make({endpoint: Util_Cognito_Runtime.userPoolEndpoint(region, userPoolId), region}),
    AdminAddUserToGroupCommand.make({
      username: userName,
      groupName,
      userPoolId,
    }),
  )
}

@ocaml.doc(" remove a user from a given group of a given userPool
  ")
let removeUserFromGroup = (
  ~region: string,
  ~userName: string,
  ~groupName: string,
  ~userPoolId: string,
) => {
  open CognitoIdentityServiceProvider
  removeUserFromGroup(
    make({endpoint: Util_Cognito_Runtime.userPoolEndpoint(region, userPoolId), region}),
    AdminRemoveUserFromGroupCommand.make({
      username: userName,
      groupName,
      userPoolId,
    }),
  )
}
