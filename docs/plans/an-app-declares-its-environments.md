# Plan: an app declares its environments, and every deployment says which commit it runs

**Status:** 🚧 E1–E4 built 2026-09-29, and the guide of E5; the release is open, and E3 has not run
against a real pull request yet (see *As built*).<br/>
**Touches:** `reventless/spec` (a new `Environments` type beside `AccountsManifest`),
`reventless/aws` (a resolver CLI beside `deploy-app`),
`.github/workflows/deploy-reventless-aws.yml` (the reusable deploy workflow),
`reventless/core/src/plugin/component/Plugin_Helpers.res` (`exportDeploymentMetadata` and the
deploy hook's provenance), and the deploy guide.<br/>
**Companion:** reventless-tools `docs/plans/the-project-tool-in-the-editor.md`, L2 and L4. That
plan shows, per environment, which commit it runs and how far each part of the app has come
there. It needs what this plan adds: a declared list of an app's environments, review
environments per pull request, and the commit of every deployment.

## Goal

An app says, in one file beside its `deploy-manifest.yaml`, which environments it has, what each
is for, and what feeds it: a branch, tags, or pull requests. The reusable deploy workflow reads
that file to decide where a push, a tag or a pull request deploys, and removes a pull request's
environment when the pull request closes. Every deployment records the commit it was built
from, the environment and its purpose, wherever it ran.

## Why

- **An environment is derived from a branch name.** The reusable workflow's *Determine branch
  name* step (`deploy-reventless-aws.yml:146`) makes the Pulumi stack the branch's name. A team
  cannot say *`dev` feeds the dev stack, `test` the test stack, `main` and its tags the prod
  stack*; it can only name its branches after its stacks.
- **A tag cannot deploy.** The step reads `refs/heads/` only. A team that releases by tagging
  `main` cannot deploy the tag, and a pinned environment (a demo stack that runs a release, not
  the moving main line) cannot be fed at all.
- **A pull request cannot be tried before it is merged.** On `pull_request` the workflow runs
  `pulumi refresh` and `pulumi preview` against the base branch's stack (`:433`, `:623`) and
  posts the preview as a comment. That is a dry run: nothing is deployed, so nobody can click
  through the change before it lands on a shared environment.
- **A deployment knows its commit only in CI.** `exportDeploymentMetadata` records
  `GITHUB_SHA` or `unknown`; the deploy hook uses `GITHUB_SHA` or `CI_COMMIT_SHA` as the
  `deploymentId` and, outside CI, a timestamp. A deployment from a laptop cannot be matched to
  any commit, and a reader cannot tell *unknown* from an id.
- **Nothing says what an environment is for.** A reader of the deployment record cannot tell a
  production stack from a demo stack except by its name.

## The shape

```yaml
# environments.yaml, beside deploy-manifest.yaml
environments:
  - { name: review,     purpose: review,     pullRequestsInto: dev }   # one per open pull request
  - { name: dev,        purpose: dev,        branch: dev }
  - { name: test,       purpose: test,       branch: test }
  - { name: production, purpose: production, branch: main, tags: "v*", stack: prod }
  - { name: demo,       purpose: demo,       tags: "v*" }
```

- **Two kinds of environment.** A *shared* environment is fed by `branch` (a name or a glob),
  `tags` (a glob), or both, and has one stack. A *review* environment is fed by
  `pullRequestsInto` (the base branch a pull request targets) and has one stack per open pull
  request, named from the environment and the number (`review-pr-7`).
- `purpose` is a closed set, `Dev | Test | Production | Demo | Review`, with `Other(string)`
  for a team's own.
- `stack` defaults to `name` for a shared environment.
- The first environment in file order that matches wins.
- *Review*, not *preview*: *preview* already names the dry run the workflow posts on a pull
  request, which stays as it is.
- **The file is optional.** Without it, everything stays as it is: the stack is the branch name,
  and a pull request gets the dry run against its base branch's stack.

## E1 — The type, in spec

`reventless/spec/src/types/Environments.res`: the record, the `purpose` variant, the shared and
review kinds as a variant, a sury schema, `parse`, `print`, the generated JSON Schema, and
`resolve : (t, ref) => option<resolved>` for a push (`refs/heads/…`, `refs/tags/…`) and
`resolvePullRequest : (t, ~base, ~number) => option<resolved>` for a pull request. A resolved
environment has its name, stack and purpose. Published with spec.

### Tests

- Round trip: `parse`, `print`, `parse`; a malformed file is refused naming the field; an
  environment with both `branch` and `pullRequestsInto` is refused.
- `resolve`: a branch name, a branch glob, a tag glob, first match wins, no match.
- `resolvePullRequest`: a base with a review environment, a base without one, the derived stack
  name.

## E2 — The workflow resolves a push or a tag

- A new optional input, `environments-path`, defaulting to `environments.yaml` beside the
  manifest.
- *Determine branch name* becomes *Determine environment*: with no file, today's step
  unchanged; with one, a small CLI beside `deploy-app`
  (`reventless-aws resolve-environment --file … --ref …`) prints the stack, the environment and
  its purpose. No match: the deploy is skipped with a notice, not failed.
- Tag refs are resolved like branches; a caller that wants tag deploys adds `push: tags:` to its
  own trigger.
- The resolved environment and purpose are passed to the deploy as `REVENTLESS_ENVIRONMENT` and
  `REVENTLESS_ENVIRONMENT_PURPOSE`.

### Tests

- The resolver CLI against E1's fixtures.
- **No file, no change:** a dry run of the resolution step on `alpha`, `beta` and `main` for
  `examples/online-shop-hybrid` gives the stacks it gives today.

## E3 — Review environments per pull request

- **On `pull_request` opened, reopened, synchronised or marked ready for review**, when the base
  branch has a review environment: deploy the pull request's head to its own stack
  (`review-pr-<n>`), with `pulumi up`. A draft pull request is deployed only when the
  environment says so (`drafts: true`); by default a review environment starts at *ready for
  review*.
- **On `pull_request` closed**, merged or not: `pulumi destroy` and `pulumi stack rm` for that
  stack. A caller adds `closed` to its own `pull_request` types.
- **When the base branch has no review environment**, the pull request keeps today's dry run
  against the base branch's stack.
- **Pull requests from forks get no review environment**: they run without the repository's
  secrets, so the step says so and falls back to the dry run.
- The review stack's configuration is the base environment's, copied at creation
  (`Pulumi.<base-stack>.yaml`), so a review environment looks like the environment it will
  land in.

### Tests

- The resolver for pull requests (E1).
- A workflow run on a test repository: opening a pull request creates `review-pr-<n>`, a push to
  it updates the stack, closing it removes the stack.

## E4 — Every deployment records its commit, environment and purpose

In `exportDeploymentMetadata` and in the deploy hook's provenance:

- **`commit`**: `GITHUB_SHA` (for a pull request, its head), else `CI_COMMIT_SHA`, else
  `git rev-parse HEAD` in the app's directory; `None` only when there is no git at all. Never a
  timestamp.
- **`dirty`**: true when the commit came from `git` and the working tree had changes, so a
  laptop deployment of uncommitted work is not mistaken for the commit.
- **`environment`**, **`purpose`**, **`tag`** (when the ref was one) and **`pullRequest`** (the
  number, for a review environment), from E2's and E3's variables; absent when the workflow did
  not resolve one.
- `deploymentId` keeps its current meaning, so existing readers of the record do not change.

### Tests

- The provenance function with CI variables, with a pull request, with only a git checkout,
  with a dirty tree, and with neither.
- A local deploy of `examples/online-shop-hybrid` records the checkout's commit and `dirty`.

## E5 — Release and docs

Spec, aws and core released together. The deploy guide gains a section with the example above,
the no-file default, and one paragraph on promotion: a team that wants every change to reach a
shared environment through a pull request (feature branches into `dev`, `dev` into `test`,
`test` into `main`) sets that with its code host's branch protection; the workflow deploys what
is merged either way.

## Risks

- **A push deploys somewhere new.** Only when a file exists; without it E2's no-change test holds
  the old behaviour.
- **Review environments cost money.** One stack per open pull request. They start at *ready for
  review* by default and are removed on close; a pull request left open keeps its stack, and
  the guide says so.
- **A failed tear-down leaves a stack behind.** The close step reports it and exits non-zero; a
  scheduled clean-up of review stacks whose pull request is closed is an open question.
- **Stack names change for a team that adopts the file.** An existing stack is kept only if the
  environment's `stack` names it; the guide says to set `stack` when adopting.

## Open questions

1. **A scheduled clean-up** of review stacks whose pull request is already closed, for the case
   where the close step failed.
2. **Should a deployment carry a document produced during its build?** A tool that summarises
   the app's state at a commit could hand it to the deploy, which would store it with the
   deployment unread, so a reader never rebuilds a deployed commit to learn its state. Core would
   treat it as an opaque, size-bounded attachment. Undecided; the companion plan asks the same.
3. **Purpose beyond the five.** Whether `Other(string)` is enough, or `Staging` earns its own
   constructor.

## Not in scope

- Which tool reads the deployment record, and how it shows environments.
- Enforcing promotion by pull request: that is the code host's branch protection.
- Changing the example apps' own deploy branches; they keep deploying as today unless a file is
  added deliberately.

## As built (2026-09-29)

- **E1** `Reventless.Environments` in spec: the type, `parseString`, `parseFile`, `print`,
  `refOf`, `resolve`, `resolvePullRequest`, and the pattern matcher; 24 tests. **Not built:**
  the generated JSON Schema. Spec's sury has no JSON Schema export under the name tried, and the
  tools, which already generate schemas, can derive it from this type.
- **E2** `resolve-environment` in aws, printing `key=value` lines; 11 tests. **Changed from the
  plan:** the workflow resolves in each deploy job after `pnpm install`, not in `detect-changes`,
  which installs nothing. Resolving there would have needed a second, bash reading of the file.
  `detect-changes` only finds the file and marks a pull request as a review candidate, which
  makes the whole app deploy (or, with no review environment, the dry run of all of it).
  Without the file each job sets the stack to the branch without calling anything.
  The workflow input is `environments`, not `environments-path`, beside the existing
  `manifest` input, which is also a path.
- **E3** review stacks in the platform, plugin and bake jobs, and a `destroy-review` job on
  close. **Changed from the plan:** a review stack gets its configuration with
  `pulumi config cp` from the base environment's stack rather than by copying
  `Pulumi.<base>.yaml`, whose `secure:` values are encrypted for the base stack only. Checked
  locally: the YAML parses, all 34 `run:` scripts pass `bash -n`, and the resolve step, run
  with the real CLI, gives the intended mode and stack for nine cases (no file on a push and a
  pull request, a branch, a tag, an unnamed branch, a pull request, a draft, a pull request into
  a branch with no review environment, a fork). **Not yet run:** a real pull request opening,
  updating and closing a review environment on AWS.
- **E4** `Reventless.DeploymentProvenance` in spec (9 tests), used by `exportDeploymentMetadata`,
  the plugin-deployed hook, and the local platform's hook. `environment` is the resolved
  environment when there is one and the stack name otherwise.
- **E5** `docs/guides/deploy-environments.md`. The release is open.

