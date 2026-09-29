open JestGlobals

// The file decides where a push deploys, so what is tested is what a reader would
// otherwise get wrong: which environment wins when two match, what a pattern
// reaches, and which files are refused rather than half-read.

let file = `# Where Amperia's commits go.
environments:
  - { name: review,     purpose: review,     pullRequestsInto: dev }
  - { name: dev,        purpose: dev,        branch: dev }
  - { name: test,       purpose: test,       branch: test }
  - { name: production, purpose: production, branch: main, tags: "v*", stack: prod }
  - { name: demo,       purpose: demo,       tags: "v*" }
  - { name: hotfix,     purpose: hotfixes,   branch: "hotfix/**" }
`

let parsed = switch Environments.parseString(file) {
| Ok(environments) => environments
| Error(message) => JsError.throwWithMessage(message)
}

let named = name => parsed->Array.find(e => e.name == name)->Option.getOrThrow

describe("Environments.parseString", () => {
  testSync("reads a shared environment, its stack defaulting to its name", () =>
    expect(named("dev"))->toEqual({
      Environments.name: "dev",
      purpose: Dev,
      feed: Shared({branch: Some("dev"), tags: None, stack: "dev"}),
    })
  )

  testSync("keeps a stack the file names", () =>
    expect(named("production").feed)->toEqual(
      Environments.Shared({branch: Some("main"), tags: Some("v*"), stack: "prod"}),
    )
  )

  testSync("reads a review environment, drafts off by default", () =>
    expect(named("review").feed)->toEqual(Environments.ReviewOf({into: "dev", drafts: false}))
  )

  testSync("keeps a purpose it has no word for", () =>
    expect(named("hotfix").purpose)->toEqual(Environments.Other("hotfixes"))
  )

  let refused = text => Environments.parseString(text)->Result.isError

  testSync("refuses an entry nothing feeds", () =>
    expect(refused("environments:\n  - { name: dev, purpose: dev }\n"))->toBe(true)
  )

  testSync("refuses pull requests and a branch on one environment", () =>
    expect(
      refused(
        "environments:\n  - { name: dev, purpose: dev, branch: dev, pullRequestsInto: dev }\n",
      ),
    )->toBe(true)
  )

  testSync("refuses a stack on a review environment", () =>
    expect(
      refused("environments:\n  - { name: r, purpose: review, pullRequestsInto: dev, stack: x }\n"),
    )->toBe(true)
  )

  testSync("refuses drafts on a shared environment", () =>
    expect(
      refused("environments:\n  - { name: dev, purpose: dev, branch: dev, drafts: true }\n"),
    )->toBe(true)
  )

  testSync("refuses a name used twice", () =>
    expect(
      refused(
        "environments:\n  - { name: dev, purpose: dev, branch: dev }\n  - { name: dev, purpose: test, branch: test }\n",
      ),
    )->toBe(true)
  )

  testSync("refuses a malformed entry rather than skipping it", () =>
    expect(refused("environments:\n  - { name: dev }\n"))->toBe(true)
  )
})

describe("Environments.print", () =>
  testSync("prints what parses back to the same environments", () =>
    expect(parsed->Environments.print->Environments.parseString)->toEqual(Ok(parsed))
  )
)

describe("Environments.matches", () => {
  testSync("a plain name matches only itself", () =>
    expect((
      Environments.matches(~pattern="dev", "dev"),
      Environments.matches(~pattern="dev", "devx"),
    ))->toEqual((true, false))
  )

  testSync("* stays within one path segment", () =>
    expect((
      Environments.matches(~pattern="feature/*", "feature/metering"),
      Environments.matches(~pattern="feature/*", "feature/metering/fix"),
    ))->toEqual((true, false))
  )

  testSync("** crosses segments", () =>
    expect(Environments.matches(~pattern="hotfix/**", "hotfix/a/b"))->toBe(true)
  )

  testSync("a dot is a dot, not any character", () =>
    expect(Environments.matches(~pattern="v1.*", "v1x2"))->toBe(false)
  )
})

describe("Environments.refOf", () => {
  testSync("reads a branch and a tag", () =>
    expect((
      Environments.refOf("refs/heads/feature/x"),
      Environments.refOf("refs/tags/v1"),
    ))->toEqual((Some(Environments.Branch("feature/x")), Some(Environments.Tag("v1"))))
  )

  testSync("anything else is not deployable", () =>
    expect(Environments.refOf("refs/pull/7/merge"))->toBe(None)
  )
})

describe("Environments.resolve", () => {
  let resolved = ref => parsed->Environments.resolve(ref)->Option.map(r => (r.name, r.stack))

  testSync("a branch reaches the environment it feeds", () =>
    expect(resolved(Branch("test")))->toEqual(Some(("test", "test")))
  )

  testSync("a tag reaches the first environment whose tags match", () =>
    expect(resolved(Tag("v1.0.0")))->toEqual(Some(("production", "prod")))
  )

  testSync("a branch nothing names deploys nowhere", () =>
    expect(resolved(Branch("feature/metering")))->toBe(None)
  )

  testSync("a review environment is never reached by a push", () =>
    expect(
      Environments.resolve(
        [{name: "review", purpose: Review, feed: ReviewOf({into: "dev", drafts: false})}],
        Branch("dev"),
      ),
    )->toBe(None)
  )
})

describe("Environments.resolvePullRequest", () => {
  testSync("a pull request into dev gets its own stack", () =>
    expect(
      parsed
      ->Environments.resolvePullRequest(~base="dev", ~number=7, ~draft=false)
      ->Option.map(r => (r.name, r.stack, r.purpose)),
    )->toEqual(Some(("review", "review-pr-7", Environments.Review)))
  )

  testSync("a draft gets none unless the environment asks for drafts", () =>
    expect(parsed->Environments.resolvePullRequest(~base="dev", ~number=7, ~draft=true))->toBe(None)
  )

  testSync("a pull request into a branch with no review environment gets none", () =>
    expect(parsed->Environments.resolvePullRequest(~base="main", ~number=7, ~draft=false))->toBe(
      None,
    )
  )
})
