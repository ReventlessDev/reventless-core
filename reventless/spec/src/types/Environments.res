/***
The environments an app deploys to, as a file: `environments.yaml`, beside its
`deploy-manifest.yaml`.

```yaml
environments:
  - { name: review,     purpose: review,     pullRequestsInto: dev }
  - { name: dev,        purpose: dev,        branch: dev }
  - { name: test,       purpose: test,       branch: test }
  - { name: production, purpose: production, branch: main, tags: "v*", stack: prod }
  - { name: demo,       purpose: demo,       tags: "v*" }
```

A *shared* environment has one stack and is fed by a branch, by tags, or by both.
A *review* environment is fed by the pull requests into one branch and has one
stack per open pull request, named `<name>-pr-<number>`.

Here rather than in the AWS package because more than the deploy reads it: a
tool that shows which commit runs where needs the same answer to *which branch
feeds which environment* as the workflow that deploys, and a second reading of
the file is how the two would come to disagree.

The file is optional. Without it a deploy uses the branch name as the stack, as
it always has; nothing here is consulted.
*/

/**
What an environment is for. `Other` keeps a team's own word rather than refusing
the file, because a purpose nothing here branches on costs nothing to carry.
*/
type purpose =
  | Dev
  | Test
  | Production
  | Demo
  | Review
  | Other(string)

let purposeSchema: S.t<purpose> = S.union([
  S.literal("dev")->S.shape(_ => Dev),
  S.literal("test")->S.shape(_ => Test),
  S.literal("production")->S.shape(_ => Production),
  S.literal("demo")->S.shape(_ => Demo),
  S.literal("review")->S.shape(_ => Review),
  S.string->S.shape(other => Other(other)),
])

let purposeName = (purpose: purpose): string =>
  switch purpose {
  | Dev => "dev"
  | Test => "test"
  | Production => "production"
  | Demo => "demo"
  | Review => "review"
  | Other(name) => name
  }

/** One entry as the file spells it. [parseString] turns it into an [environment]. */
@schema
type entry = {
  name: string,
  purpose: @s.matches(purposeSchema) purpose,
  branch?: string,
  tags?: string,
  stack?: string,
  pullRequestsInto?: string,
  drafts?: bool,
}

@schema
type file = {environments: array<entry>}

/** What feeds an environment, and so how many stacks it has. */
type feed =
  | Shared({branch: option<string>, tags: option<string>, stack: string})
  | ReviewOf({into: string, drafts: bool})

type environment = {name: string, purpose: purpose, feed: feed}

type t = array<environment>

// ── Reading ──────────────────────────────────────────────────────────────────

@module("yaml") external parseYaml: string => JSON.t = "parse"
@module("yaml") external stringifyYaml: JSON.t => string = "stringify"

let environmentOf = (entry: entry): result<environment, string> =>
  switch (entry.pullRequestsInto, entry.branch, entry.tags) {
  | (Some(_), Some(_), _) | (Some(_), _, Some(_)) =>
    Error(`${entry.name}: pullRequestsInto cannot be combined with branch or tags`)
  | (Some(_), None, None) if entry.stack->Option.isSome =>
    Error(`${entry.name}: a review environment names its stacks itself; remove stack`)
  | (Some(into), None, None) =>
    Ok({
      name: entry.name,
      purpose: entry.purpose,
      feed: ReviewOf({into, drafts: entry.drafts->Option.getOr(false)}),
    })
  | (None, None, None) =>
    Error(`${entry.name}: says neither branch, tags nor pullRequestsInto, so nothing feeds it`)
  | (None, _, _) if entry.drafts->Option.isSome =>
    Error(`${entry.name}: drafts is only meaningful with pullRequestsInto`)
  | (None, branch, tags) =>
    Ok({
      name: entry.name,
      purpose: entry.purpose,
      feed: Shared({branch, tags, stack: entry.stack->Option.getOr(entry.name)}),
    })
  }

/** Parses an environments document. Strict, like the accounts manifest: a
  malformed entry refuses the whole file, because a skipped environment is a
  branch that silently stops deploying. */
let parseString = (yamlText: string): result<t, string> =>
  switch try Ok(S.parseOrThrow(parseYaml(yamlText), ~to=fileSchema)) catch {
  | JsExn(err) => Error(JsExn.message(err)->Option.getOr("YAML parse error"))
  | _ => Error("YAML parse error")
  } {
  | Error(_) as e => e
  | Ok({environments}) =>
    let names = environments->Array.map(e => e.name)
    switch names->Array.find(n => names->Array.filter(m => m == n)->Array.length > 1) {
    | Some(duplicate) => Error(`${duplicate}: named twice`)
    | None =>
      environments->Array.reduce(Ok([]), (acc, entry) =>
        switch (acc, environmentOf(entry)) {
        | (Error(_) as e, _) => e
        | (Ok(_), Error(message)) => Error(message)
        | (Ok(done), Ok(environment)) => Ok(done->Array.concat([environment]))
        }
      )
    }
  }

let parseFile = (path: string): result<t, string> =>
  try {
    parseString(NodeFs.readFileSync(path))
  } catch {
  | JsExn(err) => Error(JsExn.message(err)->Option.getOr(`Cannot read ${path}`))
  | _ => Error(`Cannot read ${path}`)
  }

let entryOf = (environment: environment): entry =>
  switch environment.feed {
  | Shared({branch, tags, stack}) => {
      name: environment.name,
      purpose: environment.purpose,
      ?branch,
      ?tags,
      stack: ?(stack == environment.name ? None : Some(stack)),
    }
  | ReviewOf({into, drafts}) => {
      name: environment.name,
      purpose: environment.purpose,
      pullRequestsInto: into,
      drafts: ?(drafts ? Some(true) : None),
    }
  }

/** The document for a set of environments. Comments are not kept: this writes a
  new file, it does not edit one. */
let print = (environments: t): string =>
  {environments: environments->Array.map(entryOf)}->Util_Sury.toJson(fileSchema)->stringifyYaml

/** Where a deploy looks for it: beside the deploy manifest. */
let fileName = "environments.yaml"

let pathBeside = (~manifest: string): string =>
  NodePath.join([NodePath.dirname(manifest), fileName])

// ── Resolving ────────────────────────────────────────────────────────────────

/**
A branch or tag pattern as GitHub's workflow filters spell them: `*` matches
within one path segment, `**` across segments. Nothing else is special.
*/
let matches = (~pattern: string, name: string): bool => {
  let escaped =
    pattern
    ->String.split("**")
    ->Array.map(part =>
      part
      ->String.replaceRegExp(/[.+?^${}()|[\]\\]/g, "\\$&")
      ->String.replaceAll("*", "[^/]*")
    )
    ->Array.join(".*")
  RegExp.fromString(`^${escaped}$`)->RegExp.test(name)
}

/** What a push or a tag deploys to. */
type ref_ =
  | Branch(string)
  | Tag(string)

/** `refs/heads/test` and `refs/tags/v1`; anything else is not deployable. */
let refOf = (ref: string): option<ref_> =>
  if ref->String.startsWith("refs/heads/") {
    Some(Branch(ref->String.slice(~start=11)))
  } else if ref->String.startsWith("refs/tags/") {
    Some(Tag(ref->String.slice(~start=10)))
  } else {
    None
  }

type resolved = {name: string, stack: string, purpose: purpose}

/** The first shared environment, in file order, that the branch or tag feeds. */
let resolve = (environments: t, ref: ref_): option<resolved> =>
  environments->Array.findMap(({name, purpose, feed}) =>
    switch (feed, ref) {
    | (Shared({branch: Some(pattern), stack}), Branch(branch)) if matches(~pattern, branch) =>
      Some({name, stack, purpose})
    | (Shared({tags: Some(pattern), stack}), Tag(tag)) if matches(~pattern, tag) =>
      Some({name, stack, purpose})
    | (Shared(_), _) | (ReviewOf(_), _) => None
    }
  )

/** The review stack of one pull request, if the branch it targets has a review
  environment. `draft` pull requests get one only where the environment asks. */
let resolvePullRequest = (environments: t, ~base: string, ~number: int, ~draft: bool): option<
  resolved,
> =>
  environments->Array.findMap(({name, purpose, feed}) =>
    switch feed {
    | ReviewOf({into, drafts}) if matches(~pattern=into, base) && (drafts || !draft) =>
      Some({name, stack: `${name}-pr-${number->Int.toString}`, purpose})
    | ReviewOf(_) | Shared(_) => None
    }
  )
