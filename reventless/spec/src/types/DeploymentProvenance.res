/***
Where a deployment came from: the commit it was built from, whether the tree had
uncommitted changes, and the environment it was made for.

Read by the deploy while it runs, and recorded with the deployment, so a reader
can say which commit runs in which environment without asking whoever deployed.
A deployment from CI knows its commit from the CI's variables; one from a laptop
asks git. Neither gives up a timestamp in place of a commit: a timestamp is not
an answer to *which commit*, and a reader cannot tell it from one.
*/

type t = {
  commit: option<string>,
  /** True only when the commit came from git and the working tree had changes:
    what was deployed is not what the commit says. */
  dirty: bool,
  environment: option<string>,
  purpose: option<string>,
  tag: option<string>,
  pullRequest: option<int>,
}

/** What git can say about the checkout the deploy runs in. */
type git = {
  head: unit => option<string>,
  dirty: unit => bool,
}

let nonEmpty = (value: option<string>): option<string> =>
  value->Option.flatMap(v => v->String.trim == "" ? None : Some(v->String.trim))

/**
The provenance of a deployment from the process's variables, asking git only when
no CI variable names the commit.

`REVENTLESS_COMMIT` comes first because on a pull request `GITHUB_SHA` is the merge
commit GitHub made, not the head the review environment runs.
*/
let fromEnv = (env: dict<string>, ~git: git): t => {
  let get = name => env->Dict.get(name)->nonEmpty
  let fromCi =
    get("REVENTLESS_COMMIT")
    ->Option.orElse(get("GITHUB_SHA"))
    ->Option.orElse(get("CI_COMMIT_SHA"))
  let (commit, dirty) = switch fromCi {
  | Some(_) => (fromCi, false)
  | None =>
    switch git.head() {
    | Some(_) as head => (head, git.dirty())
    | None => (None, false)
    }
  }
  {
    commit,
    dirty,
    environment: get("REVENTLESS_ENVIRONMENT"),
    purpose: get("REVENTLESS_ENVIRONMENT_PURPOSE"),
    tag: get("GITHUB_REF_TYPE") == Some("tag") ? get("GITHUB_REF_NAME") : None,
    pullRequest: get("REVENTLESS_PULL_REQUEST")->Option.flatMap(n => Int.fromString(n)),
  }
}

let run = (~cwd: string, args: array<string>): option<string> =>
  try {
    Some(
      NodeChildProcess.execFileSync(
        "git",
        args,
        {cwd, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"]},
      )->String.trim,
    )
  } catch {
  | _ => None
  }

/** Git in `cwd`. A directory that is not a checkout, or a machine with no git,
  answers *no commit* and *not dirty*. */
let gitAt = (~cwd: string): git => {
  head: () => run(~cwd, ["rev-parse", "HEAD"])->nonEmpty,
  dirty: () => run(~cwd, ["status", "--porcelain"])->nonEmpty->Option.isSome,
}

/** The provenance of the deployment this process is making, in its working directory. */
let current = (): t => fromEnv(NodeProcess.env, ~git=gitAt(~cwd=NodeProcess.cwd()))
