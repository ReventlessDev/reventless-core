module Policy = {
  type arnEquals = {@as("aws:SourceArn") awsSourceArn: string}

  type condition = {@as("ArnEquals") arnEquals: arnEquals}

  type statement = {
    @as("Sid") sid: string,
    @as("Effect") effect: string,
    @as("Principal") principal: string,
    @as("Action") action: string,
    @as("Resource") resource: string,
    @as("Condition") condition?: condition, // FIXME: verify optional field is correct
  }

  type t = {
    @as("Version") version: string,
    @as("Id") id: string,
    @as("Statement") statement: array<statement>,
  }
}
