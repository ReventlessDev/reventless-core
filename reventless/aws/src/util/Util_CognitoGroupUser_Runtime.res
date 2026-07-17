// NOTE: following functions combine pulumi & aws-sdk -> should stay separated in reventless

open AwsSdk

/** add a user to a given group of a given userPool */
let addUserToGroup = (
  ~region: string,
  ~userName: string,
  ~groupName: string,
  ~userPoolId: string,
) =>
  Effect.tryPromise(
    ~catch=Cognito_Error.classify,
    () => {
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
    },
  )
  ->Effect.map(_ => ())
  ->Effect.retry(Cognito_Error.retrySchedule)
  ->Effect.catchAll(err => {
    let msg = Cognito_Error.message(err)
    ReventlessCore.EffectLogger.logError(~comp=__MODULE__, `addUserToGroup: ${msg}`)
    ->Effect.flatMap(_ => Effect.fail(msg))
  })
  ->Effect.runPromise

/** remove a user from a given group of a given userPool */
let removeUserFromGroup = (
  ~region: string,
  ~userName: string,
  ~groupName: string,
  ~userPoolId: string,
) =>
  Effect.tryPromise(
    ~catch=Cognito_Error.classify,
    () => {
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
    },
  )
  ->Effect.map(_ => ())
  ->Effect.retry(Cognito_Error.retrySchedule)
  ->Effect.catchAll(err => {
    let msg = Cognito_Error.message(err)
    ReventlessCore.EffectLogger.logError(~comp=__MODULE__, `removeUserFromGroup: ${msg}`)
    ->Effect.flatMap(_ => Effect.fail(msg))
  })
  ->Effect.runPromise
