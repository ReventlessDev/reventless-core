/** @aws-sdk/client-scheduler
  see: https://docs.aws.amazon.com/scheduler/latest/APIReference/
*/
type client

type options = {
  region?: string,
  maxAttempts?: int,
  requestHandler?: NodeHttpHandler.t,
}

module Raw = {
  @module("@aws-sdk/client-scheduler") @new
  external client: (~options: options=?, unit) => client = "SchedulerClient"
}

let clientInstance = ref(None)

/** create a SchedulerClient with default values:
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

type flexibleTimeWindow = {
  /** `OFF` or `FLEXIBLE` */
  @as("Mode") mode: string,
  @as("MaximumWindowInMinutes") maximumWindowInMinutes?: int,
}

type sqsParameters = {@as("MessageGroupId") messageGroupId?: string}

type target = {
  @as("Arn") arn: string,
  @as("RoleArn") roleArn: string,
  /** May hold `<aws.scheduler.scheduled-time>` and the other context attributes. */
  @as("Input") input?: string,
  @as("SqsParameters") sqsParameters?: sqsParameters,
}

/** The request shared by `CreateScheduleCommand` and `UpdateScheduleCommand`. */
type scheduleInput = {
  @as("Name") name: string,
  @as("GroupName") groupName?: string,
  /** `at(...)`, `rate(...)` or `cron(...)` */
  @as("ScheduleExpression") scheduleExpression: string,
  /** An IANA zone; read for `at` and `cron` only. */
  @as("ScheduleExpressionTimezone") scheduleExpressionTimezone?: string,
  @as("StartDate") startDate?: Date.t,
  @as("FlexibleTimeWindow") flexibleTimeWindow: flexibleTimeWindow,
  /** `NONE` or `DELETE` */
  @as("ActionAfterCompletion") actionAfterCompletion?: string,
  @as("State") state?: string,
  @as("Target") target: target,
}

module CreateScheduleCommand = {
  type t
  type output = {@as("ScheduleArn") scheduleArn: string}

  @new @module("@aws-sdk/client-scheduler")
  external make: scheduleInput => t = "CreateScheduleCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = command => Raw.send(client(), command)
}

module UpdateScheduleCommand = {
  type t
  type output = {@as("ScheduleArn") scheduleArn: string}

  @new @module("@aws-sdk/client-scheduler")
  external make: scheduleInput => t = "UpdateScheduleCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = command => Raw.send(client(), command)
}

module DeleteScheduleCommand = {
  type t
  type input = {
    @as("Name") name: string,
    @as("GroupName") groupName?: string,
  }
  type output = {.}

  @new @module("@aws-sdk/client-scheduler")
  external make: input => t = "DeleteScheduleCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = command => Raw.send(client(), command)
}

module ListSchedulesCommand = {
  type t
  type input = {
    @as("GroupName") groupName?: string,
    @as("NamePrefix") namePrefix?: string,
    @as("NextToken") nextToken?: string,
    @as("MaxResults") maxResults?: int,
  }
  type summary = {
    @as("Name") name: string,
    @as("GroupName") groupName?: string,
    @as("State") state?: string,
  }
  type output = {
    @as("Schedules") schedules: array<summary>,
    @as("NextToken") nextToken?: string,
  }

  @new @module("@aws-sdk/client-scheduler")
  external make: input => t = "ListSchedulesCommand"

  module Raw = {
    @send
    external send: (client, t) => promise<output> = "send"
  }

  let send: t => promise<output> = command => Raw.send(client(), command)

  /** Every schedule matching `input`, following `NextToken` across pages. */
  let all = async (input: input) => {
    let found = []
    let next = ref(Some(input))
    while next.contents->Option.isSome {
      let page = await make(next.contents->Option.getOrThrow)->send
      page.schedules->Array.forEach(s => found->Array.push(s))
      next := page.nextToken->Option.map(nextToken => {...input, nextToken})
    }
    found
  }
}

/** The names of the errors the commands throw that a caller may want to tell apart. */
module ErrorName = {
  /** A schedule of that name already exists in the group. */
  let conflict = "ConflictException"
  /** No schedule of that name; a once-only schedule deleted after it fired is one. */
  let resourceNotFound = "ResourceNotFoundException"

  let is = (exn: JsExn.t, name) => exn->JsExn.name == Some(name)
}
