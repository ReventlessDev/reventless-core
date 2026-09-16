# Plan: the platform stack creates the Lambda layer

**Date:** 2026-09-16
**Status:** PROPOSED — nothing built yet.
**Repos:** `reventless-core` only.
**Based on:** §5.1 of [from-an-empty-account-to-a-running-shop.md](../analysis/from-an-empty-account-to-a-running-shop.md),
which compares the ways to get a layer into a new account.
**Companion plan:** [shop-from-an-empty-aws-account.md](./shop-from-an-empty-aws-account.md).

## Goal

When the platform stack deploys, it creates the Lambda layer itself, in the same
AWS account and region. Nobody publishes a layer by hand, nothing is stored in an
SSM parameter, and the layer always matches the framework code that is installed.

## Why

A **Lambda layer** is a shared package of code that AWS adds to every function. The
framework's own code reaches the functions this way. The code package of each
function holds only the app's own code and leaves the framework to the layer.

Today the deploy looks up the layer's address in an SSM parameter
(`/reventless/layer-arn/<stack>`) by calling the AWS CLI. This has three problems:

- **A new account has no such parameter.** Only the maintainers' CI writes it, in the
  maintainers' account.
- **The lookup can go wrong quietly.** It uses the AWS CLI's default region, which may
  not be the stack's region, and it treats "no permission" the same as "not there".
- **The layer can be the wrong version.** The layer must match the exact framework
  code the functions use. A layer built from an older release makes functions fail
  at runtime. For someone working between two releases, no matching layer exists at
  all.

If the stack creates the layer from the packages it is deploying with, all three go
away: the account and region are right because the stack is the one deploying, and
the version is right because the content comes from the installed packages.

## Not part of this plan

- **Stopping the deploy when no layer is found.** That is step 1 of the companion
  plan, and it should land first. This plan changes where the layer comes from.
- **A public layer shared from a maintainers' account.** The analysis explains why
  not, for now.
- **Making the layer smaller.** See
  [Backlog/optimize-lambda-layer-size.md](./Backlog/optimize-lambda-layer-size.md).

## What stays

- **`REVENTLESS_LAYER_ARN` stays as an override.** A company with many AWS accounts
  may publish one layer centrally and share it with its whole organization; they set
  this variable, and the stack does not create a layer.
- **Every release keeps publishing `reventless-layer.zip`.** People who manage layers
  themselves still need it.

---

## Step 0 — Measure, then choose where the layer content comes from

Two sources are possible. This step decides between them.

**A. Build from the installed packages.** At deploy time, collect the framework
packages from `node_modules` and hand them to Pulumi as the layer content.

- *For:* always the exact code being deployed, including between releases or with a
  patched package; needs no network.
- *Against:* every deploy spends time collecting files, and every `pulumi preview`
  has to check whether they changed.

**B. A layer package on npm.** Every release also publishes a package (for example
`@reventlessdev/reventless-aws-layer`) holding the zip, with exactly the same
version as `reventless-aws`. The stack takes the zip from `node_modules`.

- *For:* nothing is assembled at deploy time; the lockfile checks the download; the
  version matches through normal dependencies.
- *Against:* one more package to release; about 16 MB extra to install; still no
  matching layer for someone working between releases.

**Measure for A:**

- how long it takes to collect the files, on a cold and a warm run;
- how much time it adds to `pulumi preview` when nothing changed;
- the size, compared with the release zip (about 16 MB).

**Rule of thumb:** choose A if it adds less than about 30 seconds to a deploy and
almost nothing to a preview when nothing changed. Otherwise choose B. Record the
numbers and the choice in this plan.

## Step 1 — A Pulumi binding for layers

Add `LayerVersion` to the AWS bindings in `rescript/pulumi-aws/src/Lambda/`. It
needs: the content (an archive), compatible runtimes, a name, and the option to
keep old layer versions when a new one replaces them (`skipDestroy`). Functions that
still use an older version keep working, and a failed deploy can roll back to it.

## Step 2 — One list of framework packages, used everywhere

The function code packages leave out exactly the packages the layer holds.
[Util_Bundle.res](../../reventless/aws/src/util/Util_Bundle.res) already computes
that list (`frameworkPackages`: `reventless-aws` and everything it depends on).
The layer builder in `reventless/layer-builder/` has its own rules for what to keep
out and what to clean up (in its `Main.res`).

- Move those rules into `reventless-aws`, next to `frameworkPackages`.
- Make the layer content (source A or B) and the function code packages use the same
  list and the same rules.

That way the layer and the code packages can never disagree about which package
lives where. That disagreement is what causes `Cannot find package` at runtime. The
layer builder then uses the moved rules too, so the release zip stays identical.

## Step 3 — The platform stack creates the layer

In [Platform.res](../../reventless/aws/src/Platform.res):

- If `REVENTLESS_LAYER_ARN` is not set, create a `LayerVersion` from the content of
  step 0.
- Export its address as a stack output, `reventlessLayerArn`.
- Before creating it, check that the zipped content fits AWS's direct-upload limit
  (50 MB). If it does not, stop with a clear message rather than a confusing AWS
  error.

## Step 4 — Functions take the layer from the right place

Today `Lambda.reventlessLayerArn` in
[Lambda.res](../../rescript/pulumi-aws/src/Lambda/Lambda.res) is a plain value read
once when the program starts. A layer created by a stack is only known while the
deploy runs, so the value has to become a Pulumi output.

- **In the platform stack:** use the address of the layer created in step 3.
- **In plugin stacks:** read `reventlessLayerArn` from the platform stack. Plugin
  stacks already hold a reference to the platform stack.
- **If a plugin stack points at a platform deployed before this change,** the output
  is missing. Stop with a message saying to deploy the platform first.
- Update the about 14 places that pass the layer to a function (the files under
  `reventless/aws/src` that use `Lambda.reventlessLayerArn`).
  `PgMigration_Builder.res` also uses the address to decide when to re-run a
  migration, so it must use the output too.

## Step 5 — Remove the SSM lookup

- Delete the AWS CLI call and the SSM lookup from `Lambda.res`.
- Keep `REVENTLESS_LAYER_ARN` as the override.

## Step 6 — CI and releases

- **Deploy workflow**
  ([deploy-reventless-aws.yml](../../.github/workflows/deploy-reventless-aws.yml)):
  stop reading the SSM parameter.
- **Layer workflow**
  ([build-lambda-layer.yml](../../.github/workflows/build-lambda-layer.yml)): keep
  building and attaching `reventless-layer.zip` to each release, and add a
  `reventless-layer.zip.sha256` file beside it so a download can be checked. Stop
  writing the SSM parameter.
- **If step 0 chose B:** add the layer package to the release.
- **Existing stacks** (`alpha`, `beta`, `main`): the first deploy after the change
  creates the layer and moves the functions to it. The old SSM parameters are no
  longer used; delete them once every stack has moved.

## Step 7 — Docs and the companion plan

- The tutorial loses its "publish the Lambda layer" step.
- [aws/get-started.md](../../packages/doc/docs-infrastructure/aws/get-started.md) and
  [aws-lambda-layer.md](../../packages/doc/docs-infrastructure/aws-lambda-layer.md)
  explain the new default and the `REVENTLESS_LAYER_ARN` override for a centrally
  shared layer.
- The companion plan's `up` command drops its layer step.

## Step 8 — Check it works

- **Maintainers' account, new stack:** deploy with no SSM parameter and no
  `REVENTLESS_LAYER_ARN`. Every kind of function starts and handles a request.
- **Between releases:** deploy from a checkout between two releases (source A only).
  It works.
- **Old platform:** deploy a plugin stack against a platform from before the change.
  It stops with the message from step 4.
- **Existing stack:** upgrade `alpha`. The functions move to the new layer without
  failing requests.
- **Override:** set `REVENTLESS_LAYER_ARN`. No layer is created, and the given one is
  used.

---

## Risks

- **Preview gets slower** if the stack has to look through many files on every
  preview. Step 0 measures this before anything is decided.
- **Many layer versions pile up**, because old versions are kept. A new version
  appears only when the framework packages change, so this grows slowly; clean up old
  versions from time to time.
- **Different package layouts.** App repositories install packages differently (pnpm,
  hoisted). Step 2 uses the same package search the code packages already use, which
  was fixed for exactly this in
  [layer-membership-is-not-resolvability.md](../analysis/layer-membership-is-not-resolvability.md).

## Checklist

```
Step 0 [ ] measure source A; choose A or B; record numbers
Step 1 [ ] LayerVersion binding (with skipDestroy)
Step 2 [ ] layer rules moved into reventless-aws; one package list for layer and code
Step 3 [ ] platform stack creates the layer and exports reventlessLayerArn; size check
Step 4 [ ] functions use the output; plugin stacks read it from the platform
Step 5 [ ] SSM lookup and AWS CLI call removed; override kept
Step 6 [ ] CI stops using SSM; checksum beside the release zip; (B) layer package released
Step 7 [ ] docs updated; companion plan's layer step removed
Step 8 [ ] all checks above pass
```
