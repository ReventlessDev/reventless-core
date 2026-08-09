/*** @aws-sdk/client-lambda
  see: https://docs.aws.amazon.com/lambda/latest/api/Welcome.html

  Control-plane bindings only — enough to take a function out of service and put
  it back. The seed reset uses them to quiesce a stack's runtimes for the length
  of a wipe: a live runtime that holds state across invocations will write that
  state back over a truncated table, so the wipe has to remove the contention
  rather than race it.

  Two distinct powers, deliberately kept apart:

  - `PutFunctionConcurrency`/`DeleteFunctionConcurrency` stop *new* invocations.
    Reserving 0 does not consume account concurrency, and it does not terminate
    an execution environment that already exists — it only stops it being
    invoked again.
  - `UpdateFunctionConfiguration` is what actually discards existing execution
    environments: after a configuration change, later invocations run in new
    ones. That is the documented way to drop whatever a warm container was
    holding; a concurrency change is not.

  Like `ResourceGroupsTaggingApi` and unlike the memoised clients here, the
  caller passes a client so the region is explicit.
*/
type client

module Raw = {
  type options = {region?: string}
  @module("@aws-sdk/client-lambda") @new
  external client: (~options: options=?, unit) => client = "LambdaClient"
}

let client = (~region: option<string>=?, ()): client => Raw.client(~options={region: ?region}, ())

/** A function's environment variables, in the shape both the get and the update
    use. `variables` absent and `variables` empty are different: sending an empty
    map on an update CLEARS every variable. */
type environment = {@as("Variables") variables?: dict<string>}

module GetFunctionConfigurationCommand = {
  /*** see: https://docs.aws.amazon.com/lambda/latest/api/API_GetFunctionConfiguration.html */

  type t

  type input = {@as("FunctionName") functionName: string}

  type output = {
    @as("$metadata") metadata: Metadata.t,
    @as("FunctionName") functionName?: string,
    @as("Environment") environment?: environment,
    /** "Successful" | "Failed" | "InProgress" — absent on a function that has
        never been updated. A second update while this reads "InProgress" is
        rejected with ResourceConflictException, so callers poll it. */
    @as("LastUpdateStatus")
    lastUpdateStatus?: string,
    @as("LastUpdateStatusReason") lastUpdateStatusReason?: string,
    @as("State") state?: string,
  }

  @new @module("@aws-sdk/client-lambda")
  external make: input => t = "GetFunctionConfigurationCommand"

  @send external send: (client, t) => promise<output> = "send"
}

module UpdateFunctionConfigurationCommand = {
  /*** see: https://docs.aws.amazon.com/lambda/latest/api/API_UpdateFunctionConfiguration.html

    Only the fields a caller sends are changed. Sending `environment` replaces
    the whole variable map, so an update that means to add one variable must
    send the existing ones alongside it. */

  type t

  type input = {
    @as("FunctionName") functionName: string,
    @as("Environment") environment?: environment,
  }

  type output = {
    @as("$metadata") metadata: Metadata.t,
    @as("FunctionName") functionName?: string,
    @as("LastUpdateStatus") lastUpdateStatus?: string,
  }

  @new @module("@aws-sdk/client-lambda")
  external make: input => t = "UpdateFunctionConfigurationCommand"

  @send external send: (client, t) => promise<output> = "send"
}

module GetFunctionConcurrencyCommand = {
  /*** see: https://docs.aws.amazon.com/lambda/latest/api/API_GetFunctionConcurrency.html

    `reservedConcurrentExecutions` is absent when the function has no reservation
    at all — which is a different state from a reservation of 0, and the one a
    restore has to be able to put back. */

  type t

  type input = {@as("FunctionName") functionName: string}

  type output = {
    @as("$metadata") metadata: Metadata.t,
    @as("ReservedConcurrentExecutions") reservedConcurrentExecutions?: int,
  }

  @new @module("@aws-sdk/client-lambda")
  external make: input => t = "GetFunctionConcurrencyCommand"

  @send external send: (client, t) => promise<output> = "send"
}

module PutFunctionConcurrencyCommand = {
  /*** see: https://docs.aws.amazon.com/lambda/latest/api/API_PutFunctionConcurrency.html */

  type t

  type input = {
    @as("FunctionName") functionName: string,
    @as("ReservedConcurrentExecutions") reservedConcurrentExecutions: int,
  }

  type output = {
    @as("$metadata") metadata: Metadata.t,
    @as("ReservedConcurrentExecutions") reservedConcurrentExecutions?: int,
  }

  @new @module("@aws-sdk/client-lambda")
  external make: input => t = "PutFunctionConcurrencyCommand"

  @send external send: (client, t) => promise<output> = "send"
}

module DeleteFunctionConcurrencyCommand = {
  /*** see: https://docs.aws.amazon.com/lambda/latest/api/API_DeleteFunctionConcurrency.html

    Removes the reservation entirely, returning the function to the account's
    unreserved pool — the restore for a function that had no reservation before. */

  type t

  type input = {@as("FunctionName") functionName: string}

  type output = {@as("$metadata") metadata: Metadata.t}

  @new @module("@aws-sdk/client-lambda")
  external make: input => t = "DeleteFunctionConcurrencyCommand"

  @send external send: (client, t) => promise<output> = "send"
}
