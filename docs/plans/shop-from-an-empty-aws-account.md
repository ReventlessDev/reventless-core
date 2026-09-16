# Plan: the online shop from an empty AWS account

**Date:** 2026-09-16
**Status:** IN PROGRESS — step 1 done.
**Repos:** `reventless-core` only.
**Based on:** [the analysis of the same name](../analysis/from-an-empty-account-to-a-running-shop.md).
**Companion plan:** [platform-stack-creates-the-lambda-layer.md](./platform-stack-creates-the-lambda-layer.md).

## Goal

Someone new to Reventless creates an empty AWS account and, a few commands later,
has the online shop running there: they can open it in a browser, sign in as each of
the four demo users, and see demo data.

After the one-time setup of their machine, it should take these commands:

```bash
git clone https://github.com/ReventlessDev/reventless-core && cd reventless-core
pnpm run setup
pnpm run shop:up      # deploys everything and prints the web address and the sign-ins
pnpm run shop:seed    # optional: fills the shop with demo data
pnpm run shop:down    # later: removes everything again
```

The command names are placeholders until step 4 settles them.

## Not part of this plan

- **Letting the platform stack create the Lambda layer itself.** That is the
  companion plan. Until it lands, this plan publishes the layer from the release
  download.
- **Prebuilt compiler plugin (PPX) binaries for Intel Macs and Linux arm64.** That
  belongs to [prebuilt-binaries-out-of-repo.md](./prebuilt-binaries-out-of-repo.md).
- **The race where a plugin answers with its old definition during a deploy.** That
  belongs to [a-stale-handshake-answer-asks-again.md](./a-stale-handshake-answer-asks-again.md).
- **Deploying without cloning the whole repository.** Worth doing later; not needed
  for the goal.
- **Windows outside WSL2.**

## Words used in this plan

- **Stack** — one deployed copy of one Pulumi project. The shop has three projects
  (platform, catalog, ordering), so one deployment is three stacks.
- **Lambda layer** — a shared package of code that AWS adds to every function. The
  framework's own code reaches the functions this way. A layer lives in one AWS
  account and one region.
- **SSM parameter** — a named value stored in AWS. Today the deploy looks up the
  layer's address (its ARN) in the parameter `/reventless/layer-arn/<stack>`.
- **Component manifest** — a file that tells the web app which pages to show. The
  platform writes it after every plugin has registered. Writing it is called
  *baking*.
- **User pool** — the AWS Cognito directory of users who can sign in.

## Order of work

Steps 1 and 2 are independent and can start at once. Step 3 comes before step 4.
Steps 5 and 6 are needed by step 4. Step 7 can happen any time. Step 8 follows
step 4. Steps 9 and 10 need an empty AWS account, which is not available yet.

---

## Step 1 — A deploy without a Lambda layer stops with a clear message

**Why.** Today, if the layer lookup finds nothing, the deploy carries on without a
layer and reports success. Every function then fails the first time it runs with
`Cannot find package`. Nobody can tell from that message what went wrong.

**What to change.**

- In [Lambda.res](../../rescript/pulumi-aws/src/Lambda/Lambda.res), the lookup
  (`reventlessLayerArn`) currently turns every failure into "no layer". Replace it
  with a lookup that tells apart "found", "not found" and "could not look" (no AWS
  CLI, no permission), and that remembers which region it looked in.
- Stop the deploy with an error when a function is created and no layer was found.
  The message says which parameter and region were checked, and how to publish a
  layer (link to the tutorial).
- About 14 places pass the layer to a function (the files that use
  `Lambda.reventlessLayerArn` under `reventless/aws/src`). Route them all through
  the new check. `PgMigration_Builder.res` uses `"no-layer"` as a stand-in and
  needs the same treatment.
- First find out which unit tests create functions under Pulumi's test mocks. Give
  those tests an explicit test value, so the new error does not break them.

**Done when.** `pulumi preview` on a stack with no layer stops with the message
above; setting `REVENTLESS_LAYER_ARN` still works; all tests pass.

**Done.** The lookup now also asks in the stack's `aws:region`, not the AWS CLI's
default region: the `alpha` parameter lives in `eu-west-1`, and from a CLI set to
another region the old lookup found nothing. Only one suite reached a function (the
dead-letter Lambda is created at import time); the `reventless-aws` Jest project
gets a stand-in ARN from `tests/setup/layerArn.cjs`. `Lambda.reventlessLayerArn`
is now a function, so code outside this repo that read it as a value must call it.

## Step 2 — The demo users work on the default user pool

**Why.** The user pool a deploy creates signs people in with an email address. The
shipped accounts file names its users `admin`, `shopper`, `merch` and `fulfil`, so
`provision-accounts` rightly refuses all of them. It also writes passwords into the
file *before* it refuses, so the seed then offers accounts that do not exist.

**What to change.**

1. In [ProvisionAccounts.res](../../reventless/aws/scripts/ProvisionAccounts.res),
   check the user pool **before** writing anything into `.reventless/users.yaml`.
2. In the AWS template
   [users.example.yaml](../../examples/online-shop-hybrid/platform-aws/users.example.yaml),
   use email addresses under `example.com`, for example `shopper@example.com`.
   `example.com` is reserved, so nobody receives mail there, and provisioning
   already tells Cognito not to send invitations.
3. The seed finds its demo users by their names (`shopper`, `admin`, `merch` in
   [DemoData.res](../../examples/online-shop-hybrid/seed-data/src/DemoData.res)).
   With email addresses that no longer works. Add an optional field to each entry
   of the accounts file that says which demo person the account plays, for example
   `demoOwner: shopper`. The shared format lives in
   [AccountsManifest.res](../../reventless/spec/src/types/AccountsManifest.res).
   The seed looks for that field first and falls back to the username, so the local
   platform keeps working unchanged.
4. Add the same field to the local template, so both files read the same way.
5. Fix [test-on-aws.md](../../packages/doc/docs-tutorials/test-on-aws.md): one
   command creates all four users.

**Done when.** A test shows that a refused pool leaves the accounts file untouched;
a test shows the seed finds all demo owners in the new AWS template; the local seed
still works.

## Step 3 — One bake command, used by CI and by people

**Why.** Only the CI workflow bakes the component manifest, in about 100 lines of
shell script inside
[deploy-reventless-aws.yml](../../.github/workflows/deploy-reventless-aws.yml).
Anyone who deploys by hand never gets the file, so every user except an
administrator sees an empty web app.

**What to change.**

- Add a `bake-manifest` command to `reventless-aws`, written in ReScript next to the
  existing `provision-*` commands in `reventless/aws/scripts/`. It does what the CI
  script does:
  1. read `bakedManifestFunction`, `bakedManifestBucket` and `bakedManifestKey` from
     the platform stack;
  2. read `pluginStructureRef` from each plugin stack listed in
     `deploy-manifest.yaml`;
  3. call the bake function, and try again every 15 seconds (up to 20 times) while a
     plugin is still `behind`;
  4. report `missing` and `diverged` plainly and stop, because waiting does not fix
     those.
- Change the CI job to call this command.

**Decide in this step.** The CI job today needs no `pnpm install`, which keeps it
fast. Calling the command needs `reventless-aws` installed. Either install only
that package in the job, or accept the extra time. Consumer repositories use the
same workflow, so whatever is chosen must also work for them.

**Done when.** An `alpha` deploy in CI bakes through the new command, with the same
report as before.

## Step 4 — One command to deploy the shop, and one to remove it

**Why.** Today a person runs about 20 commands and edits several files, in the right
order, and must know things no page tells them.

**What to build.** A command in `reventless-aws` (working name `deploy-platform`)
with `up` and `down`. It reads `deploy-manifest.yaml`, so any Reventless app can use
it, not only the shop. It drives Pulumi through Pulumi's Automation API, so Pulumi
never stops to ask a question. Root `package.json` gets `shop:up`, `shop:down` and
`shop:seed` scripts that call it for the hybrid example.

**What `up` does, in order.** Every step can run again safely.

1. **Checks before anything is created:** Node version; AWS credentials work; a
   region is set; Pulumi is logged in. Each failure says how to fix it.
2. **Stacks:** for each project, in the order `deploy-manifest.yaml` gives, select
   the stack or create it. A new try-out stack gets:
   - the region from the environment;
   - `platform:stack` pointing at the platform stack, under the Pulumi organization
     the user is logged into (see step 5);
   - the try-out flag from step 6.

   The project names come from each folder's `Pulumi.yaml`, not from
   `deploy-manifest.yaml`, whose `platform.name` does not match the real project
   name.
3. **Layer:** find the release download that matches the installed
   `reventless-aws` version, publish it in this account and region with the AWS SDK,
   and store its address in the SSM parameter. Skip this if a layer for the same
   version is already stored. If no download exists for the version (a checkout
   between two releases), stop and say so; the companion plan removes this case.
4. **Deploy** each stack, in order.
5. **Bake** the manifest (step 3).
6. **Create the demo users** (the logic of `provision-accounts`, with step 2's
   template).
7. **Print** the web address and the four sign-ins.

**What `down` does.** Remove the stacks in reverse order, then the layer versions and
SSM parameter that `up` created. It removes only try-out stacks (step 6), never a
stack without the flag.

**Decide in this step.**

- The command name.
- The try-out stack name. Recommendation: `dev`. It is not a CI branch name, and the
  seed reset tool already accepts it.
- Pulumi writes a `Pulumi.dev.yaml` file into each project folder. Add it to
  `.gitignore`, so try-out settings never end up in a commit.

**Done when.** In the maintainers' own AWS account, with the `dev` SSM parameter
deleted first, `pnpm run shop:up` ends by printing the address and four sign-ins;
each user sees their pages; `pnpm run shop:down` leaves no stacks, buckets, layer
versions or parameters behind.

## Step 5 — Plugin stacks find the platform without editing files

**Why.** Both plugins' stack files name the maintainers' Pulumi organization. A new
user must edit three lines. If they delete the line instead, the plugin quietly
deploys as a platform of its own, with no error.

**What to change.**

- Add `getOrganization` to the Pulumi bindings in
  [Pulumi.res](../../rescript/pulumi-pulumi/src/Pulumi.res), so step 4 can fill in
  the organization.
- Where a plugin is deployed (`deployPlugin` in
  [Platform.res](../../reventless/aws/src/Platform.res)), stop with a clear error
  when `platform:stack` is missing. **Check first** that no stack which is its own
  platform goes through that path; platform stacks never set `platform:stack`.
- Fix both plugins' `Pulumi.main.yaml` in the hybrid example. They name projects
  that do not exist (`online-shop-hybrid-platform` and `online-shop-hybrid-catalog`
  instead of `…-platform-aws` and `…-catalog-aws`).
- Remove `interstack:dependencies`. Nothing reads it. Remove it from the example
  stack files, from `docs/templates/deploy-aws/Pulumi.env.yaml`, and from the pages
  that explain it (`deploy-to-aws.md`, `aws/get-started.md`, `deployment-guide.md`).

**Done when.** A plugin stack without `platform:stack` fails with the new message; the
example files contain no dead settings.

## Step 6 — Try-out stacks can be removed in one go

**Why.** To stop accidents, every stack not named `pr-…` gets protected storage
buckets that cannot be deleted while they hold files. That is right for `alpha` and
for real deployments, but it means a try-out needs several manual commands to
remove.

**What to change.**

- Add a stack setting `reventless:disposable: "true"`. When it is set, storage is
  unprotected and deleted together with its content. The decision lives in
  `protectionFor` in
  [Util_StoreLayout.res](../../reventless/aws/src/util/Util_StoreLayout.res); the
  offload objects that are kept on delete today must follow the same setting.
- Do **not** reuse `reventless:wipeable`. `alpha` sets that flag so the reset tool may
  empty it on purpose, and a comment in `Util_StoreLayout.res` says clearly that it
  must not remove protection. Reusing it would unprotect `alpha`.
- Step 4 sets the new flag on every stack it creates.

**Done when.** A stack with the flag is removed by `pulumi destroy` alone; `alpha`
stays protected.

## Step 7 — Helper scripts follow your Pulumi login

**Why.** The seed, the reset tool and the client check always read stacks from Pulumi
Cloud, whatever you are logged into. Someone using Pulumi's local or S3 storage
gets "no deployed Pulumi stacks". The provisioning commands already follow the
login.

**What to change.**

- In [SeedAws.res](../../examples/online-shop-hybrid/platform-aws/src/SeedAws.res)
  and its siblings, use the current Pulumi login. `SEED_PULUMI_BACKEND` still
  overrides it. Where a CI job relied on the fixed setting, set the variable there.
- Delete `verify-subscriptions.mjs`. It contains another deployment's addresses.
  `pnpm run verify:client-publish` already finds everything by itself.
- Remove the mention of `REVENTLESS_UPLOAD_ENDPOINT` from `test-on-aws.md`; nothing
  reads it.

**Done when.** With `pulumi login --local`, the seed finds the local stacks.

## Step 8 — Rewrite the tutorials around the new command

- [deploy-to-aws.md](../../packages/doc/docs-tutorials/deploy-to-aws.md): what you
  need, the commands from the goal, what you get, how to remove it. Move the
  stack-by-stack path to the infrastructure guide.
- [test-on-aws.md](../../packages/doc/docs-tutorials/test-on-aws.md): sign in with
  the printed users, seed, check.
- The example's [README.md](../../examples/online-shop-hybrid/README.md): the same
  commands.

**Done when.** The docs site builds without broken links; the tutorial names no step
that the command already does.

## Step 9 — First real run in an empty AWS account

**Blocked:** needs an empty AWS account.

Follow the new tutorial word for word, on a machine that has never built the repo.
Write down how long it takes, and every error or question. Check three things we
could not check without such an account:

- whether AWS refuses CloudFront until a new account is verified;
- whether a new account allows Lambda functions with 4096 MB memory (the default for
  task functions);
- whether Amazon Location is available in the chosen region.

Fix what the run finds, and record it in this plan.

## Step 10 — A scheduled deploy from scratch

**Blocked:** needs the empty AWS account from step 9, plus CI credentials for it.

A weekly CI job that runs `shop:up` into a new try-out stack, signs in as each of the
four demo users, reads one page each (for the shopper, one that shows only the
shopper's own orders), and then runs `shop:down`. It fails loudly if any step fails.

This is the only test that follows a new user's path. The maintainers' own deploys
cannot catch these problems: their account already has the layer parameter, CI
bakes the manifest, and nobody creates the demo users again.

---

## Open questions

- The command's name, and the try-out stack name (step 4).
- How the CI bake job gets `reventless-aws` installed (step 3).
- Whether any stack that is its own platform also goes through `deployPlugin`
  (step 5).

## Checklist

```
Step 1  [x] layer lookup tells found / not found / could not look
        [x] deploy stops when no layer, message names parameter + region
        [x] all call sites use the check; tests given a test value
Step 2  [ ] pool checked before the accounts file is written
        [ ] AWS template uses example.com addresses
        [ ] demoOwner field in AccountsManifest; seed uses it first
        [ ] test-on-aws.md fixed
Step 3  [ ] bake-manifest command
        [ ] CI job uses it
Step 4  [ ] deploy-platform up / down
        [ ] shop:up / shop:down / shop:seed scripts
        [ ] Pulumi.dev.yaml ignored
Step 5  [ ] getOrganization binding
        [ ] missing platform:stack is an error for plugins
        [ ] Pulumi.main.yaml project names fixed
        [ ] interstack:dependencies removed
Step 6  [ ] reventless:disposable setting
Step 7  [ ] helper scripts follow the Pulumi login
        [ ] verify-subscriptions.mjs removed
Step 8  [ ] tutorials rewritten
Step 9  [ ] first run in an empty account          (blocked: account)
Step 10 [ ] scheduled deploy from scratch           (blocked: account + CI credentials)
```
