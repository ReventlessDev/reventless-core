# Deploy environments: which branch, tag or pull request deploys where

An app can say, in `environments.yaml` beside its `deploy-manifest.yaml`, which
environments it has, what each is for, and what feeds it. The reusable deploy workflow
(`.github/workflows/deploy-reventless-aws.yml`) reads the file to pick the Pulumi stack a
run deploys to, and every deployment records the commit it was built from.

**Without the file nothing changes:** a push deploys to the stack named after its branch,
and a pull request gets a dry run (`pulumi preview`) against its base branch's stack.

## The file

```yaml
environments:
  - { name: review,     purpose: review,     pullRequestsInto: dev }   # one per open pull request
  - { name: dev,        purpose: dev,        branch: dev }
  - { name: test,       purpose: test,       branch: test }
  - { name: production, purpose: production, branch: main, tags: "v*", stack: prod }
  - { name: demo,       purpose: demo,       tags: "v*" }
```

| Field | Meaning |
|---|---|
| `name` | the environment's name, unique in the file |
| `purpose` | `dev`, `test`, `production`, `demo`, `review`, or a word of your own |
| `branch` | a branch name or pattern that feeds it |
| `tags` | a tag pattern that feeds it |
| `stack` | the Pulumi stack; defaults to `name` |
| `pullRequestsInto` | makes it a **review environment**: one stack per open pull request into this branch |
| `drafts` | review environments only: deploy draft pull requests too (default: from *ready for review*) |

Patterns follow GitHub's branch filters: `*` matches within one path segment, `**` across
segments. The first environment in file order that matches wins. A malformed file refuses
the deploy rather than being half read; a push that matches nothing deploys nowhere and says
so in a notice.

The type is `Reventless.Environments` in `@reventlessdev/reventless-spec`, so tools read the
file exactly as the deploy does.

> **⚠️ The name is taken.** The workflow reads *any* `environments.yaml` beside the deploy
> manifest as this file, and a file it cannot read fails every deploy of the app, with the
> file's path in the error. If the app already keeps a file of that name for another tool,
> rename that file, or set the workflow's `environments` input to where this one lives.

## What a run deploys

| Event | Environment | What happens |
|---|---|---|
| push to a branch, or a tag | the first shared environment whose `branch` or `tags` match | `pulumi up` on its stack |
| push nothing matches | none | nothing deploys |
| pull request into a branch with a review environment | the review environment | `pulumi up` on `<name>-pr-<number>`, with the pull request's head, the whole app |
| any other pull request | none | the dry run against the base branch's stack, as before |
| pull request from a fork | none | the dry run: forks run without the repository's secrets |
| pull request closed, merged or not | its review environment | every review stack is destroyed and removed, plugins first |

A review stack takes its configuration from the stack of the branch it targets, through
`pulumi config cp`, so its secrets are re-encrypted for it. Its stack config file exists only
in the runner. A copied setting that names another stack of the app (`platform:stack`, or
any value naming `<org>/<project>/<base-stack>` for a project in the deploy manifest) is
pointed at the review stack, so a review plugin deploys against the review platform, not the
shared one. A setting naming a stack the app does not deploy keeps pointing at it.

**On a self-managed backend** (the workflow's `pulumi-backend-url` input), a stack the
workflow creates would otherwise be encrypted with a passphrase the workflow does not have.
Set `pulumi-secrets-provider` and every review stack, and every environment deployed for the
first time, is created with that provider. For a review stack, `{stack}` in the provider is
the base environment's stack, so the review stack uses the same key as the stack it copies
from. See the deployment guide's *A self-managed state backend*.

**The caller's triggers.** For tags to deploy, add them to the calling workflow's `push`
trigger. For review environments, the calling workflow needs:

```yaml
on:
  pull_request:
    types: [opened, reopened, synchronize, ready_for_review, closed]
```

**Promotion.** A team that wants every change to reach a shared environment through a pull
request (feature branches into `dev`, `dev` into `test`, `test` into `main`) sets that with
the code host's branch protection. The workflow deploys what is merged either way.

**Adopting the file.** A stack is kept only if an environment names it. If `main` deployed to
a stack called `main` until now, write `stack: main` on the environment `main` feeds.

**Cost.** Every open pull request into a branch with a review environment is a full stack. A
pull request left open keeps its stack; a failed removal fails the closing run, so a stack
left behind is visible.

## What every deployment records

The deploy records, in the stack's `deploymentMetadata` output and in the payload of the
plugin-deployed hook:

| Field | From |
|---|---|
| `commit` | the pull request's head for a review environment; else `GITHUB_SHA`, else `CI_COMMIT_SHA`, else `git rev-parse HEAD` where the deploy runs |
| `dirty` | true when the commit came from git and the working tree had changes |
| `environment` | the resolved environment; without the file, the stack name as before |
| `purpose`, `tag`, `pullRequest` | the resolved environment's purpose, the tag a tag deploy came from, a review environment's pull request |

A deploy from a laptop therefore records its checkout's commit, not a timestamp.
`deploymentId` keeps its meaning. The provenance is `Reventless.DeploymentProvenance`.

## Asking by hand

```
pnpm exec resolve-environment --ref refs/heads/test
pnpm exec resolve-environment --pull-request 7 --base dev
```

prints `matched`, `environment`, `stack` and `purpose` as `key=value` lines, the same answer
the workflow acts on.
