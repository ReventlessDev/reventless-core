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
  let client: CognitoIdentityServiceProvider.client = Raw.client(
    ~options={endpoint: Util_Cognito_Runtime.userPoolEndpoint(region, userPoolId), region},
  )
  let addUserToGroupCommand: AdminAddUserToGroupCommand.t = {
    username: userName,
    groupName,
    userPoolId,
  }->AdminAddUserToGroupCommand.make
  client->AdminAddUserToGroupCommand.Raw.send(addUserToGroupCommand)
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
  let client: CognitoIdentityServiceProvider.client = Raw.client(
    ~options={endpoint: Util_Cognito_Runtime.userPoolEndpoint(region, userPoolId), region},
  )
  let removeUserFromGroupCommand = AdminRemoveUserFromGroupCommand.make({
    username: userName,
    groupName,
    userPoolId,
  })
  client->AdminRemoveUserFromGroupCommand.Raw.send(removeUserFromGroupCommand)
}
