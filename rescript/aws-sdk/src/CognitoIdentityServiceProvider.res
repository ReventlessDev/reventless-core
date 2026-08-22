/***  @aws-sdk/client-cognito-identity-provider
    see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/Package/-aws-sdk-client-cognito-identity-provider/
*/
type client

type options = {
  maxAttempts?: int,
  requestHandler?: NodeHttpHandler.t,
  endpoint?: string,
  region?: string,
}

module Raw = {
  @module("@aws-sdk/client-cognito-identity-provider") @new
  external client: (~options: options) => client = "CognitoIdentityProviderClient"
}

let clientInstance = ref(None)

/** create a CognitoIdentityProviderClient with default values:
  - maxAttempts: 3,
  - connectionTimeout: 1000ms
  - requestTimeout: 5000ms

  use `Raw.client` if you want to set alternative configuration
*/
let client = () =>
  switch clientInstance.contents {
  | None =>
    let client = Raw.client(
      ~options={
        maxAttempts: 3,
        requestHandler: NodeHttpHandler.make({
          connectionTimeout: 1000,
          requestTimeout: 5000,
        }),
      },
    )
    clientInstance := Some(client)
    client
  | Some(client) => client
  }

module SignUpCommand = {
  type t

  type input = {
    @as("ClientId") clientId: string,
    @as("Username") username: string,
    @as("Password") password: string,
  }

  type output = {
    @as("UserConfirmed") userConfirmed?: bool,
    @as("UserSub") userSub?: string,
  }

  @new @module("@aws-sdk/client-cognito-identity-provider")
  external make: input => t = "SignUpCommand"

  module Raw = {
    /**
      see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/client/cognito-identity-provider/command/SignUpCommand/,
      https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/client/cognito-identity-provider/
    */
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = command => Raw.send(client(), command)
}

module AdminAddUserToGroupCommand = {
  type t

  type input = {
    @as("Username") username: string,
    @as("GroupName") groupName: string,
    @as("UserPoolId") userPoolId: string,
  }

  @new @module("@aws-sdk/client-cognito-identity-provider")
  external make: input => t = "AdminAddUserToGroupCommand"

  module Raw = {
    /**
      see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/Package/-aws-sdk-client-cognito-identity-provider/Class/AdminAddUserToGroupCommand/
    */
    @send
    external send: (client, t) => promise<unit> = "send"
  }

  let send: t => promise<unit> = command => Raw.send(client(), command)
}

module AdminRemoveUserFromGroupCommand = {
  type t

  type input = {
    @as("Username") username: string,
    @as("GroupName") groupName: string,
    @as("UserPoolId") userPoolId: string,
  }

  @new @module("@aws-sdk/client-cognito-identity-provider")
  external make: input => t = "AdminRemoveUserFromGroupCommand"

  module Raw = {
    /**
      see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/client/cognito-identity-provider/command/AdminRemoveUserFromGroupCommand/
    */
    @send
    external send: (client, t) => promise<unit> = "send"
  }

  let send: t => promise<unit> = command => Raw.send(client(), command)
}

module AdminListGroupsForUserCommand = {
  type t

  /** `Username` takes the username, any alias attribute, or — for a local user —
    their `sub`, which is the one identifier a verified token always carries.
    A value the pool cannot resolve raises `UserNotFoundException` rather than
    returning an empty group list, so a caller is never mistaken for one holding
    no groups. */
  type input = {
    @as("Username") username: string,
    @as("UserPoolId") userPoolId: string,
    @as("Limit") limit?: int,
    @as("NextToken") nextToken?: string,
  }

  type group = {@as("GroupName") groupName?: string}

  type output = {
    @as("Groups") groups?: array<group>,
    @as("NextToken") nextToken?: string,
  }

  @new @module("@aws-sdk/client-cognito-identity-provider")
  external make: input => t = "AdminListGroupsForUserCommand"

  module Raw = {
    /**
      see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/client/cognito-identity-provider/command/AdminListGroupsForUserCommand/
    */
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = command => Raw.send(client(), command)
}

module CreateUserPoolCommand = {
  type t

  type passwordPolicy = {
    @as("MinimumLength") minimumLength?: int,
    @as("RequireLowercase") requireLowercase?: bool,
    @as("RequireUppercase") requireUppercase?: bool,
    @as("RequireNumbers") requireNumbers?: bool,
    @as("RequireSymbols") requireSymbols?: bool,
  }

  type policies = {@as("PasswordPolicy") passwordPolicy?: passwordPolicy}

  type adminCreateUserConfig = {
    @as("AllowAdminCreateUserOnly") allowAdminCreateUserOnly?: bool,
  }

  /** Only the members a Reventless pool is provisioned with. The API accepts far
    more; an operator wanting the rest edits the pool afterwards rather than
    having every setting grow a parameter here. */
  type input = {
    @as("PoolName") poolName: string,
    @as("UsernameAttributes") usernameAttributes?: array<string>,
    @as("MfaConfiguration") mfaConfiguration?: string,
    @as("Policies") policies?: policies,
    @as("AdminCreateUserConfig") adminCreateUserConfig?: adminCreateUserConfig,
    @as("UserPoolTags") userPoolTags?: Dict.t<string>,
  }

  type userPoolType = {
    @as("Id") id?: string,
    @as("Name") name?: string,
    @as("Arn") arn?: string,
  }

  type output = {@as("UserPool") userPool?: userPoolType}

  @new @module("@aws-sdk/client-cognito-identity-provider")
  external make: input => t = "CreateUserPoolCommand"

  module Raw = {
    /**
      see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/client/cognito-identity-provider/command/CreateUserPoolCommand/
    */
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = command => Raw.send(client(), command)
}

module ListUserPoolsCommand = {
  type t

  /** `MaxResults` caps at 60, so a caller looking for a pool by name has to page.
    Cognito offers no lookup by name and does not enforce name uniqueness. */
  type input = {
    @as("MaxResults") maxResults: int,
    @as("NextToken") nextToken?: string,
  }

  type userPoolDescription = {
    @as("Id") id?: string,
    @as("Name") name?: string,
  }

  type output = {
    @as("UserPools") userPools?: array<userPoolDescription>,
    @as("NextToken") nextToken?: string,
  }

  @new @module("@aws-sdk/client-cognito-identity-provider")
  external make: input => t = "ListUserPoolsCommand"

  module Raw = {
    /**
      see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/client/cognito-identity-provider/command/ListUserPoolsCommand/
    */
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = command => Raw.send(client(), command)
}

module DescribeUserPoolCommand = {
  type t

  type input = {@as("UserPoolId") userPoolId: string}

  type userPoolType = {
    @as("Id") id?: string,
    @as("Name") name?: string,
    @as("Arn") arn?: string,
  }

  type output = {@as("UserPool") userPool?: userPoolType}

  @new @module("@aws-sdk/client-cognito-identity-provider")
  external make: input => t = "DescribeUserPoolCommand"

  module Raw = {
    /**
      see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/client/cognito-identity-provider/command/DescribeUserPoolCommand/
    */
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = command => Raw.send(client(), command)
}
