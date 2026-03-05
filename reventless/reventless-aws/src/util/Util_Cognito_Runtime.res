// NOTE: following functions combine pulumi & aws-sdk -> should stay separated in reventless

/** sign up a user to a given userPool
   NOTE: should be called in runtime
*/
open AwsSdk

let userPoolEndpoint = (region, userPoolId) => `cognito-idp.${region}.amazonaws.com/${userPoolId}`

let signUp = (
  ~region: string,
  ~userPoolId: string,
  ~userPoolClientId: string,
  ~userName: string,
  ~password: string,
): promise<CognitoIdentityServiceProvider.SignUpCommand.output> => {
  open CognitoIdentityServiceProvider
  let client = CognitoIdentityServiceProvider.Raw.client(
    ~options={
      endpoint: userPoolEndpoint(region, userPoolId),
      region,
    },
  )
  {
    clientId: userPoolClientId,
    username: userName,
    password,
  }
  ->SignUpCommand.make
  ->SignUpCommand.Raw.send(client, _)
}

/** sign up a user to a given userPool, if the user is not already present
   NOTE: should be called in runtime
*/
let signUpIfMissing = (
  ~region: string,
  ~userPoolId: string,
  ~userPoolClientId: string,
  ~userName: string,
  ~password: string,
) =>
  Effect.tryPromise(
    ~catch=_err => `Didn't create user: ${userName}`,
    () => signUp(~region, ~userPoolId, ~userPoolClientId, ~userName, ~password),
  )
  ->Effect.flatMap(result =>
    Effect.logInfo(`Created User ${userName} ${result.userSub->Option.getOr("")}`)
  )
  ->Effect.catchAll(msg => Effect.logInfo(msg))
  ->Effect.runPromise
