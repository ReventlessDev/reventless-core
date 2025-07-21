/*** @aws-sdk/client-secrets-manager
  see: https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/client/secrets-manager/
*/
type client

type options = {
  region?: string,
  maxAttempts?: int,
  requestHandler?: NodeHttpHandler.t,
}

module Raw = {
  @module("@aws-sdk/client-secrets-manager") @new
  external client: (~options: options, unit) => client = "SecretsManagerClient"
}

let instance = ref(None)

let client = () =>
  switch instance.contents {
  | None =>
    let client = Raw.client(
      ~options={
        maxAttempts: 3,
        requestHandler: NodeHttpHandler.make({
          connectionTimeout: 1000,
          requestTimeout: 5000,
        }),
      },
      (),
    )
    instance := Some(client)
    client
  | Some(client) => client
  }

module GetSecretValueCommand = {
  type t

  type input = {
    @as("SecretId") secretId: string,
    @as("VersionId") versionId?: string,
    @as("VersionStage") versionStage?: string,
  }

  type output = {
    @as("SecretString") secretString: option<string>,
    @as("VersionId") versionId: option<string>,
    @as("VersionStage") versionStage: option<string>,
  }

  @new @module("@aws-sdk/client-secrets-manager")
  external make: input => t = "GetSecretValueCommand"

  module Raw = {
    @send
    external send: (client, t) => Js.Promise.t<output> = "send"
  }

  let send: t => Js.Promise.t<output> = command => Raw.send(client(), command)
}
