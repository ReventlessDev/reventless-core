open JestGlobals

module Lambda = PulumiAws.Lambda

// A deploy with no layer used to succeed and leave every function failing with
// "Cannot find package". These pin what the lookup tells apart and what the
// stopped deploy says.
let parameter = "/reventless/layer-arn/dev"

let cliResult = (~status=?, ~stdout="", ~stderr="", ~error=?) => {
  NodeChildProcess.status: status->Nullable.fromOption,
  stdout: Nullable.make(stdout),
  stderr: Nullable.make(stderr),
  error: error->Nullable.fromOption,
}

describe("Lambda.classifySsmLookup", () => {
  let classify = (~region=Some("eu-west-1"), result) =>
    Lambda.classifySsmLookup(~parameter, ~region, result)

  testSync("a stored value is the layer", () =>
    expect(
      classify(cliResult(~status=0, ~stdout="arn:aws:lambda:eu-west-1:1:layer:reventless:7\n")),
    )->toEqual(Lambda.Found("arn:aws:lambda:eu-west-1:1:layer:reventless:7"))
  )

  testSync("ParameterNotFound means there is no layer", () =>
    expect(
      classify(
        cliResult(
          ~status=254,
          ~stderr="\nAn error occurred (ParameterNotFound) when calling the GetParameter operation: \n",
        ),
      ),
    )->toEqual(Lambda.NotFound({parameter, region: Some("eu-west-1")}))
  )

  testSync("a refused call is not mistaken for a missing layer", () =>
    expect(
      classify(
        cliResult(
          ~status=254,
          ~stderr="\nAn error occurred (AccessDeniedException) when calling the GetParameter operation: no\n",
        ),
      ),
    )->toEqual(
      Lambda.CouldNotLook({
        parameter,
        region: Some("eu-west-1"),
        reason: "An error occurred (AccessDeniedException) when calling the GetParameter operation: no",
      }),
    )
  )

  testSync("a CLI that cannot be started is not mistaken for a missing layer", () => {
    let error = JsError.make("spawnSync aws ENOENT")->JsError.toJsExn
    let reason = switch classify(
      ~region=None,
      {...cliResult(~error), stdout: Nullable.null, stderr: Nullable.null},
    ) {
    | CouldNotLook({reason}) => Some(reason)
    | _ => None
    }
    expect(reason)->toEqual(Some("the AWS CLI could not be run (spawnSync aws ENOENT)"))
  })
})

describe("Lambda.missingLayerMessage", () => {
  testSync("names the parameter and the region it looked in", () => {
    let message =
      Lambda.NotFound({parameter, region: Some("eu-west-1")})
      ->Lambda.missingLayerMessage
      ->Option.getOr("")
    expect(message)->toContain(parameter)
    expect(message)->toContain("region eu-west-1")
    expect(message)->toContain("REVENTLESS_LAYER_ARN")
  })

  testSync("says when the CLI's default region was asked", () =>
    expect(
      Lambda.NotFound({parameter, region: None})->Lambda.missingLayerMessage->Option.getOr(""),
    )->toContain("the AWS CLI's default region")
  )

  testSync("carries the reason a lookup could not be made", () =>
    expect(
      Lambda.CouldNotLook({parameter, region: None, reason: "no credentials"})
      ->Lambda.missingLayerMessage
      ->Option.getOr(""),
    )->toContain("no credentials")
  )

  testSync("is silent when the layer was found", () =>
    expect(Lambda.Found("arn")->Lambda.missingLayerMessage)->toEqual(None)
  )
})

describe("Lambda.reventlessLayerArn", () => {
  testSync("REVENTLESS_LAYER_ARN wins without asking AWS", () =>
    expect(Lambda.reventlessLayerArn())->toBe(
      "arn:aws:lambda:eu-central-1:000000000000:layer:reventless-test:1",
    )
  )
})
