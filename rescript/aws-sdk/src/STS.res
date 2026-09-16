/*** @aws-sdk/client-sts — who the caller is.
  see: https://docs.aws.amazon.com/STS/latest/APIReference/welcome.html
*/
type client

type config = {region: unit => promise<string>}

module Raw = {
  type options = {region?: string}
  @module("@aws-sdk/client-sts") @new
  external client: (~options: options=?, unit) => client = "STSClient"
}

let client = (~region: option<string>=?, ()): client => Raw.client(~options={region: ?region}, ())

/** The region the SDK resolved from the environment and the shared config
    files. Rejects when neither names one. */
@get external config: client => config = "config"

module GetCallerIdentityCommand = {
  /*** see: https://docs.aws.amazon.com/STS/latest/APIReference/API_GetCallerIdentity.html */

  type t

  /** The call takes no input; the SDK still expects an object. */
  type input = dict<string>

  type output = {
    @as("$metadata") metadata: Metadata.t,
    @as("Account") account?: string,
    @as("Arn") arn?: string,
  }

  @new @module("@aws-sdk/client-sts")
  external make: input => t = "GetCallerIdentityCommand"

  @send external send: (client, t) => promise<output> = "send"
}
