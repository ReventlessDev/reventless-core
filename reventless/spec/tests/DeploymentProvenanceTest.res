open JestGlobals

// Which commit a deployment claims to be. The case that matters most is the one
// with no CI: before this, a laptop deploy recorded a timestamp where a commit
// belonged.

let git = (~head=?, ~dirty=false) => {
  DeploymentProvenance.head: () => head,
  dirty: () => dirty,
}

let provenance = (vars, ~git) => DeploymentProvenance.fromEnv(Dict.fromArray(vars), ~git)

describe("DeploymentProvenance.fromEnv", () => {
  testSync("CI's commit, never git's, and never dirty", () =>
    expect(provenance([("GITHUB_SHA", "a1f3")], ~git=git(~head="beef", ~dirty=true)))->toEqual({
      DeploymentProvenance.commit: Some("a1f3"),
      dirty: false,
      environment: None,
      purpose: None,
      tag: None,
      pullRequest: None,
    })
  )

  testSync("a pull request's head wins over the merge commit GitHub made", () =>
    expect(
      provenance([("REVENTLESS_COMMIT", "head7"), ("GITHUB_SHA", "merge7")], ~git=git()).commit,
    )->toEqual(Some("head7"))
  )

  testSync("GitLab's variable when there is no GitHub one", () =>
    expect(provenance([("CI_COMMIT_SHA", "c4d2")], ~git=git()).commit)->toEqual(Some("c4d2"))
  )

  testSync("the checkout's commit outside CI, and whether the tree was dirty", () =>
    expect(
      provenance([], ~git=git(~head="e8a0", ~dirty=true))->(
        p => (p.DeploymentProvenance.commit, p.dirty)
      ),
    )->toEqual((Some("e8a0"), true))
  )

  testSync("no commit at all when there is neither CI nor git", () =>
    expect(provenance([], ~git=git())->(p => (p.DeploymentProvenance.commit, p.dirty)))->toEqual((
      None,
      false,
    ))
  )

  testSync("an empty CI variable counts as absent", () =>
    expect(provenance([("GITHUB_SHA", " ")], ~git=git(~head="e8a0")).commit)->toEqual(Some("e8a0"))
  )

  testSync("the environment, its purpose and the pull request the workflow resolved", () =>
    expect(
      provenance(
        [
          ("REVENTLESS_ENVIRONMENT", "review"),
          ("REVENTLESS_ENVIRONMENT_PURPOSE", "review"),
          ("REVENTLESS_PULL_REQUEST", "7"),
        ],
        ~git=git(),
      )->(p => (p.DeploymentProvenance.environment, p.purpose, p.pullRequest)),
    )->toEqual((Some("review"), Some("review"), Some(7)))
  )

  testSync("a tag only when the ref was one", () =>
    expect((
      provenance([("GITHUB_REF_TYPE", "tag"), ("GITHUB_REF_NAME", "v1")], ~git=git()).tag,
      provenance([("GITHUB_REF_TYPE", "branch"), ("GITHUB_REF_NAME", "main")], ~git=git()).tag,
    ))->toEqual((Some("v1"), None))
  )
})

describe("DeploymentProvenance.gitAt", () =>
  testSync("a directory that is not a checkout answers no commit, not an error", () => {
    let outside = DeploymentProvenance.gitAt(~cwd=NodeOs.tmpdir())
    expect((outside.head(), outside.dirty()))->toEqual((None, false))
  })
)
