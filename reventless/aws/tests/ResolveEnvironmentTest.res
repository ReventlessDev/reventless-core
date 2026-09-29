open JestGlobals

// What the deploy workflow appends to $GITHUB_OUTPUT. The resolving itself, and
// the file's rules, are tested with the format in `spec`'s `EnvironmentsTest`;
// what is tested here is the command line and the lines it prints, because the
// workflow reads those as they are.

module Resolve = ResolveEnvironment

let environments = switch Reventless.Environments.parseString(`environments:
  - { name: review,     purpose: review,     pullRequestsInto: dev }
  - { name: dev,        purpose: dev,        branch: dev }
  - { name: production, purpose: production, branch: main, tags: "v*", stack: prod }
`) {
| Ok(environments) => environments
| Error(message) => JsError.throwWithMessage(message)
}

describe("ResolveEnvironment.parseArgs", () => {
  testSync("a ref asks about a push", () =>
    expect(Resolve.parseArgs(["--ref", "refs/heads/dev"])->Result.map(a => a.request))->toEqual(
      Ok(Resolve.Push("refs/heads/dev")),
    )
  )

  testSync("a pull request needs the branch it targets", () =>
    expect(Resolve.parseArgs(["--pull-request", "7"])->Result.isError)->toBe(true)
  )

  testSync("a pull request with its base and draft state", () =>
    expect(
      Resolve.parseArgs(["--pull-request", "7", "--base", "dev", "--draft"])->Result.map(
        a => a.request,
      ),
    )->toEqual(Ok(Resolve.PullRequest({number: 7, base: "dev", draft: true})))
  )

  testSync("a pull request number that is not a number is refused", () =>
    expect(Resolve.parseArgs(["--pull-request", "seven", "--base", "dev"])->Result.isError)->toBe(
      true,
    )
  )

  testSync("both questions at once are refused", () =>
    expect(
      Resolve.parseArgs([
        "--ref",
        "refs/heads/dev",
        "--pull-request",
        "7",
        "--base",
        "dev",
      ])->Result.isError,
    )->toBe(true)
  )

  testSync("no question is refused", () =>
    expect(Resolve.parseArgs([])->Result.isError)->toBe(true)
  )
})

describe("ResolveEnvironment.answer", () => {
  testSync("a push to a branch prints its environment, stack and purpose", () =>
    expect(Resolve.answer(environments, Push("refs/heads/main")))->toEqual([
      "matched=true",
      "environment=production",
      "stack=prod",
      "purpose=production",
    ])
  )

  testSync("a tag deploys where its pattern says", () =>
    expect(Resolve.answer(environments, Push("refs/tags/v1.2.0"))->Array.get(2))->toEqual(
      Some("stack=prod"),
    )
  )

  testSync("a pull request into dev gets its review stack", () =>
    expect(
      Resolve.answer(environments, PullRequest({number: 7, base: "dev", draft: false})),
    )->toEqual(["matched=true", "environment=review", "stack=review-pr-7", "purpose=review"])
  )

  testSync("nothing matched is an answer, not an error", () =>
    expect(Resolve.answer(environments, Push("refs/heads/feature/x")))->toEqual(["matched=false"])
  )

  testSync("a ref that is neither a branch nor a tag matches nothing", () =>
    expect(Resolve.answer(environments, Push("refs/pull/7/merge")))->toEqual(["matched=false"])
  )
})
