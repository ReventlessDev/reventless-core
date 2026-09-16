/*** @aws-sdk/client-ssm — Parameter Store only.
  see: https://docs.aws.amazon.com/systems-manager/latest/APIReference/Welcome.html
*/
type client

module Raw = {
  type options = {region?: string}
  @module("@aws-sdk/client-ssm") @new
  external client: (~options: options=?, unit) => client = "SSMClient"
}

let client = (~region: option<string>=?, ()): client => Raw.client(~options={region: ?region}, ())

/** The error `name` of a read or delete for a parameter that does not exist. */
let parameterNotFound = "ParameterNotFound"

module GetParameterCommand = {
  /*** see: https://docs.aws.amazon.com/systems-manager/latest/APIReference/API_GetParameter.html */

  type t

  type input = {@as("Name") name: string}

  type parameter = {@as("Value") value?: string}

  type output = {
    @as("$metadata") metadata: Metadata.t,
    @as("Parameter") parameter?: parameter,
  }

  @new @module("@aws-sdk/client-ssm")
  external make: input => t = "GetParameterCommand"

  @send external send: (client, t) => promise<output> = "send"
}

module PutParameterCommand = {
  /*** see: https://docs.aws.amazon.com/systems-manager/latest/APIReference/API_PutParameter.html */

  type t

  type input = {
    @as("Name") name: string,
    @as("Value") value: string,
    @as("Type") type_: string,
    @as("Overwrite") overwrite?: bool,
  }

  type output = {@as("$metadata") metadata: Metadata.t}

  @new @module("@aws-sdk/client-ssm")
  external make: input => t = "PutParameterCommand"

  @send external send: (client, t) => promise<output> = "send"
}

module DeleteParameterCommand = {
  /*** see: https://docs.aws.amazon.com/systems-manager/latest/APIReference/API_DeleteParameter.html */

  type t

  type input = {@as("Name") name: string}

  type output = {@as("$metadata") metadata: Metadata.t}

  @new @module("@aws-sdk/client-ssm")
  external make: input => t = "DeleteParameterCommand"

  @send external send: (client, t) => promise<output> = "send"
}
