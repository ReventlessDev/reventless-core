open JestGlobals

// Which pending operations the deploy workflow's recovery step drops and which
// stop it. The pulumi calls around them are checked against a real backend by
// hand; what is tested here is the decision.

module Clear = ClearPendingCreates

let export = (operations: string) =>
  JSON.parseOrThrow(
    `{"version": 3, "deployment": {"resources": [], "pending_operations": ${operations}}}`,
  )

let operation = (~urn, ~type_) =>
  `{"resource": {"urn": "${urn}", "type": "${type_}"}, "type": "creating"}`

let validation = operation(
  ~urn="urn:pulumi:alpha::app::aws:acm/certificateValidation:CertificateValidation::cert",
  ~type_="aws:acm/certificateValidation:CertificateValidation",
)
let lambda = operation(
  ~urn="urn:pulumi:alpha::app::aws:lambda/function:Function::handler",
  ~type_="aws:lambda/function:Function",
)

let refused = (state: JSON.t) =>
  state
  ->Clear.pendingOperations
  ->Array.filter(p => !Clear.isSafe(p))
  ->Array.map(p => p.resourceType)

describe("ClearPendingCreates.pendingOperations", () => {
  testSync("a stack with none, or with no deployment yet, has none", () => {
    expect(Clear.pendingOperations(export("[]")))->toEqual([])
    expect(
      Clear.pendingOperations(JSON.parseOrThrow(`{"version": 3, "deployment": {}}`)),
    )->toEqual([])
    expect(Clear.pendingOperations(JSON.parseOrThrow(`{"version": 3}`)))->toEqual([])
  })

  testSync("each operation with its resource and kind", () =>
    expect(Clear.pendingOperations(export(`[${lambda}]`)))->toEqual([
      {
        Clear.urn: "urn:pulumi:alpha::app::aws:lambda/function:Function::handler",
        resourceType: "aws:lambda/function:Function",
        operation: "creating",
      },
    ])
  )
})

describe("ClearPendingCreates.isSafe", () => {
  testSync("a certificate validation is dropped", () =>
    expect(refused(export(`[${validation}]`)))->toEqual([])
  )

  testSync("a resource that may exist in AWS stops the deploy", () =>
    expect(refused(export(`[${lambda}]`)))->toEqual(["aws:lambda/function:Function"])
  )

  testSync("in a mix, only the unsafe one is refused", () =>
    expect(refused(export(`[${validation}, ${lambda}]`)))->toEqual(["aws:lambda/function:Function"])
  )

  testSync("the type must match whole, not as a prefix", () =>
    expect(
      refused(
        export(
          `[${operation(~urn="u", ~type_="aws:acm/certificateValidation:CertificateValidationX")}]`,
        ),
      ),
    )->toEqual(["aws:acm/certificateValidation:CertificateValidationX"])
  )
})

describe("ClearPendingCreates.parseArgs", () => {
  testSync("the stack, and the project directory", () =>
    expect(Clear.parseArgs(["--stack", "alpha", "--cwd", "platform-aws"]))->toEqual(
      Ok({Clear.stack: "alpha", cwd: "platform-aws"}),
    )
  )

  testSync("the project directory defaults to the working directory", () =>
    expect(Clear.parseArgs(["--stack", "alpha"])->Result.map(a => a.cwd))->toEqual(
      Ok(NodeProcess.cwd()),
    )
  )

  test("no stack is a usage mistake", async () => {
    let observed = await Reventless.CliArgs.observe(Clear.cli, [])
    expect((observed.exitCode, observed.reachedMain))->toEqual((Some(2), false))
  })
})
