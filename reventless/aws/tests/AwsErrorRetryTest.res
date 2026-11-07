open JestGlobals

// Each AWS error module as its call sites use it: a rejected SDK promise caught by
// `Effect.tryPromise(~catch=classify)`, then `Effect.retry(retrySchedule)`. No test
// loaded these modules before, so a schedule that failed to build at import only
// showed on AWS, and a throttle classified as permanent never showed at all.

@module("./AwsErrorFixtures.mjs")
external rejectAwsError: (string, string) => promise<string> = "rejectAwsError"

@module("./AwsErrorFixtures.mjs")
external rejectWith: string => promise<string> = "rejectWith"

// Fails `fails` times with an SDK-shaped error, then succeeds. The test clock is
// moved a day on, past any backoff, and the attempts are counted.
let run = (
  type e,
  ~classify: unknown => e,
  ~schedule: Schedule.t<Duration.t, e, unit>,
  ~name,
  ~message,
  ~fails,
) => {
  let attempts = ref(0)
  let call = () => {
    attempts := attempts.contents + 1
    attempts.contents <= fails ? rejectAwsError(name, message) : Promise.resolve("ok")
  }
  Effect.tryPromise(~catch=classify, call)
  ->Effect.retry(schedule)
  ->Effect.map(v => Ok(v))
  ->Effect.catchAll(e => Effect.succeed(Error(e)))
  ->Effect.fork
  ->Effect.flatMap(fiber =>
    TestClock.adjust(Duration.hours(24))->Effect.zipRight(Fiber.join(fiber))
  )
  ->Effect.provide(TestContext.testContext)
  ->Effect.runPromise
  ->Promise.thenResolve(result => (result, attempts.contents))
}

let always = 1000

let retries = (
  type e,
  ~label,
  ~classify: unknown => e,
  ~message: e => string,
  ~schedule: Schedule.t<Duration.t, e, unit>,
  ~throttle,
  ~limit,
) =>
  describe(label, () => {
    test("retries a throttled call until it succeeds", async () => {
      let (result, attempts) = await run(
        ~classify,
        ~schedule,
        ~name=throttle,
        ~message="Rate exceeded",
        ~fails=2,
      )
      expect(result->Result.isOk)->toBe(true)
      expect(attempts)->toBe(3)
    })

    test(`gives up after ${limit->Int.toString} retries, keeping the message`, async () => {
      let (result, attempts) = await run(
        ~classify,
        ~schedule,
        ~name=throttle,
        ~message="Rate exceeded",
        ~fails=always,
      )
      expect(attempts)->toBe(limit + 1)
      switch result {
      | Error(e) => expect(message(e))->toBe("Rate exceeded")
      | Ok(_) => expect("succeeded")->toBe("failed")
      }
    })

    test("does not retry a permanent failure", async () => {
      let (result, attempts) = await run(
        ~classify,
        ~schedule,
        ~name="AccessDeniedException",
        ~message="not authorized",
        ~fails=always,
      )
      expect(attempts)->toBe(1)
      expect(result->Result.isError)->toBe(true)
    })
  })

retries(
  ~label="DynamoDb_Error",
  ~classify=DynamoDb_Error.classify,
  ~message=DynamoDb_Error.message,
  ~schedule=DynamoDb_Error.retrySchedule,
  ~throttle="ThrottlingException",
  ~limit=5,
)
retries(
  ~label="SQS_Error",
  ~classify=SQS_Error.classify,
  ~message=SQS_Error.message,
  ~schedule=SQS_Error.retrySchedule,
  ~throttle="ThrottlingException",
  ~limit=5,
)
retries(
  ~label="SQS_Error send",
  ~classify=SQS_Error.classify,
  ~message=SQS_Error.message,
  ~schedule=SQS_Error.sendRetrySchedule,
  ~throttle="RequestLimitExceeded",
  ~limit=10,
)
retries(
  ~label="SNS_Error",
  ~classify=SNS_Error.classify,
  ~message=SNS_Error.message,
  ~schedule=SNS_Error.retrySchedule,
  ~throttle="ThrottlingException",
  ~limit=5,
)
retries(
  ~label="Kinesis_Error",
  ~classify=Kinesis_Error.classify,
  ~message=Kinesis_Error.message,
  ~schedule=Kinesis_Error.retrySchedule,
  ~throttle="ProvisionedThroughputExceededException",
  ~limit=5,
)
retries(
  ~label="Cognito_Error",
  ~classify=Cognito_Error.classify,
  ~message=Cognito_Error.message,
  ~schedule=Cognito_Error.retrySchedule,
  ~throttle="TooManyRequestsException",
  ~limit=5,
)
retries(
  ~label="AppSync_Error",
  ~classify=AppSync_Error.classify,
  ~message=AppSync_Error.message,
  ~schedule=AppSync_Error.retrySchedule,
  ~throttle="ConcurrentModificationException",
  ~limit=6,
)

describe("DynamoDb_Error conditions", () => {
  test("a failed condition is stale state, not retried", async () => {
    let (result, attempts) = await run(
      ~classify=DynamoDb_Error.classify,
      ~schedule=DynamoDb_Error.retrySchedule,
      ~name="ConditionalCheckFailedException",
      ~message="The conditional request failed",
      ~fails=always,
    )
    expect(attempts)->toBe(1)
    switch result {
    | Error(DynamoDb_Error.StaleState(_)) => ()
    | _ => expect("not stale")->toBe("stale")
    }
  })
})

describe("a rejection that is not an error object", () => {
  test("is classified as permanent rather than throwing", async () => {
    let attempts = ref(0)
    let result = await Effect.tryPromise(
      ~catch=SQS_Error.classify,
      () => {
        attempts := attempts.contents + 1
        rejectWith("ThrottlingException")
      },
    )
    ->Effect.retry(SQS_Error.retrySchedule)
    ->Effect.map(_ => "")
    ->Effect.catchAll(e => Effect.succeed(SQS_Error.message(e)))
    ->Effect.runPromise
    expect(attempts.contents)->toBe(1)
    expect(result)->toBe("SQS error")
  })
})
