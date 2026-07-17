type client

type options = {
  region?: string,
  maxAttempts?: int,
  requestHandler?: NodeHttpHandler.t,
}

module Raw = {
  @module("@aws-sdk/client-cloudwatch-events") @new
  external client: (~options: options=?, unit) => client = "CloudWatchEventsClient"
}

let clientInstance = ref(None)

/** create a CloudWatchEventsClient with default values:
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
      (),
    )
    clientInstance := Some(client)
    client
  | Some(client) => client
  }

/* ****** Rule ****** */
module PutRuleCommand = {
  type t

  type input = {
    @as("Name") name: string,
    @as("ScheduleExpression") scheduleExpression?: string,
    @as("RoleArn") roleArn?: string,
    @as("State") state?: string,
  }

  type output = {@as("RuleArn") ruleArn: string}

  @new @module("@aws-sdk/client-cloudwatch-events")
  external make: input => t = "PutRuleCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = command => Raw.send(client(), command)
}

module DeleteRuleCommand = {
  type t

  type input = {
    @as("Name") name: string,
    @as("Force") force?: bool, // FIXME: is this as optional field correct?
  }

  type output = {.} // FIXME: replace dict with actual record

  @new @module("@aws-sdk/client-cloudwatch-events")
  external make: input => t = "DeleteRuleCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = command => Raw.send(client(), command)
}

/* ****** Targets ****** */

module PutTargetsCommand = {
  type t

  type sqsParameters = {@as("MessageGroupId") messageGroupId: string}

  type target = {
    @as("Arn") arn: string,
    @as("Id") id: string,
    @as("Input") input?: string,
    @as("SqsParameters") sqsParameters?: sqsParameters,
  }

  type input = {
    @as("Rule") rule: string,
    @as("Targets") targets: array<target>,
  }

  type output = {.}

  @new @module("@aws-sdk/client-cloudwatch-events")
  external make: input => t = "PutTargetsCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = command => Raw.send(client(), command)
}

module RemoveTargetsCommand = {
  type t

  type input = {
    @as("Rule") rule: string,
    @as("Ids") ids: array<string>,
    @as("Force") force?: bool,
  }

  type output = {.}

  @new @module("@aws-sdk/client-cloudwatch-events")
  external make: input => t = "RemoveTargetsCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }
  let send: t => promise<output> = command => Raw.send(client(), command)
}

/* ****** Events ****** */
module PutEventsCommand = {
  type t

  type entry = {
    @as("Source") source: string,
    @as("Detail") detail?: string,
    @as("Resources") resources?: array<string>,
  }

  type input = {@as("Entries") entries: array<entry>}

  type output = {.}

  @new @module("@aws-sdk/client-cloudwatch-events")
  external make: input => t = "PutEventsCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = command => Raw.send(client(), command)
}
