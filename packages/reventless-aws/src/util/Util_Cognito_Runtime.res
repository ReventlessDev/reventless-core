// NOTE: following functions combine pulumi & aws-sdk -> should stay separated in reventless

@ocaml.doc(" sign up a user to a given userPool
   NOTE: should be called in runtime
   ")
open AwsSdk

let userPoolEndpoint = (region, userPoolId) => `cognito-idp.${region}.amazonaws.com/${userPoolId}`

let signUp = (
  ~region: string,
  ~userPoolId: string,
  ~userPoolClientId: string,
  ~userName: string,
  ~password: string,
): Js.Promise.t<CognitoIdentityServiceProvider.SignUpResponse.t> =>
  CognitoIdentityServiceProvider.signUp(
    CognitoIdentityServiceProvider.make(
      CognitoIdentityServiceProvider.Opts.make(
        ~endpoint=userPoolEndpoint(region, userPoolId),
        ~region,
      ),
    ),
    ~params=CognitoIdentityServiceProvider.SignUpRequest.make(
      ~_ClientId=userPoolClientId,
      ~_Username=userName,
      ~_Password=password,
    ),
  )->Request.promise

@ocaml.doc(" sign up a user to a given userPool, if the user is not already present
   NOTE: should be called in runtime
   ")
let signUpIfMissing = async (
  ~region: string,
  ~userPoolId: string,
  ~userPoolClientId: string,
  ~userName: string,
  ~password: string,
) =>
  switch await signUp(~region, ~userPoolId, ~userPoolClientId, ~userName, ~password) {
  | result => Js.log3("Created User", userName, result["_UserSub"])
  | exception _ => Js.log2("Didn't create user:", userName)
  }
