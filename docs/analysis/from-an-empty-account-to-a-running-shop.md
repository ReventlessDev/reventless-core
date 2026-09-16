# From an empty AWS account to a running online shop

**Status:** Analysis
**Date:** 2026-09-11, rewritten in plainer words 2026-09-16
**Subject:** What someone new to Reventless has to do to deploy the example
`examples/online-shop-hybrid` into their own AWS account, following
[deploy-to-aws.md](../../packages/doc/docs-tutorials/deploy-to-aws.md) and
[test-on-aws.md](../../packages/doc/docs-tutorials/test-on-aws.md).
**Question:** What makes this hard? What is manual today, what could be automated,
and what would it take to get from a new AWS account to a working shop in a few
steps?
**Plans that follow from it:** [shop-from-an-empty-aws-account.md](../plans/shop-from-an-empty-aws-account.md)
and [platform-stack-creates-the-lambda-layer.md](../plans/platform-stack-creates-the-lambda-layer.md).

---

## Words used here

- **Stack** — one deployed copy of one Pulumi project. The shop has three projects
  (platform, catalog, ordering), so one deployment is three stacks.
- **Lambda layer** — a shared package of code that AWS adds to every function. The
  framework's own code reaches the functions this way. A layer lives in one AWS
  account and one region.
- **SSM parameter** — a named value stored in AWS. The deploy looks up the layer's
  address (its ARN) in `/reventless/layer-arn/<stack>`.
- **Component manifest** — a file that tells the web app which pages to show. It is
  written ("baked") after all plugins have registered.
- **User pool** — the AWS Cognito directory of users who can sign in.
- **PPX** — a compiler plugin the ReScript build needs.

## Summary

- **Following the tutorial today does not give you a working shop.** Three problems
  stand in the way. Each one looks fine at the step that causes it and only shows up
  later, as something that seems unrelated (§2):
  1. A new account has **no Lambda layer**. Functions without it fail with
     `Cannot find package` the first time they run, even though the deploy reported
     success.
  2. **Only CI writes the component manifest.** After a deploy by hand, every user
     except an administrator sees an empty web app.
  3. **Creating the demo users fails.** The user pool signs people in with an email
     address, but the shipped file names them `admin`, `shopper`, `merch` and
     `fulfil`.
- **Apart from those, the path takes about 20 commands, 3 to 5 file edits and five
  tools.** It also needs knowledge no page gives you: which Pulumi organization to
  write, that the AWS CLI's default region decides where the layer is looked up,
  that `alpha` is a protected stack name, and that the seed always reads Pulumi
  Cloud (§1, §3).
- **The goal is four commands after setting up your machine:** clone, `pnpm run
  setup`, one command that deploys everything and prints the web address and
  sign-ins, and optionally one that adds demo data (§4).
- **Most of the pieces already exist.** The bake is already a function, creating
  users is already a command, and the deploy order is already written down in
  `deploy-manifest.yaml`. What is new is a command that runs them in order, a way to
  find the Pulumi organization automatically, and a decision about who creates the
  layer (§5).
- **Nothing here has been tried in a new account.** The three problems come from
  reading the code and are clear. The account-level risks in §3.3 are general AWS
  behaviour and need a real empty account to confirm.

---

## 1. The path today, step by step

Starting from an empty AWS account, with the tutorial as it is now:

| # | Step | What kind |
|---|---|---|
| 0 | Install Node 22.17.1, pnpm (via corepack), the Pulumi CLI and the AWS CLI; create a Pulumi account and log in; create AWS credentials; set the AWS CLI's default region | once per machine; logging in to Pulumi and the region are not mentioned |
| 0b | Intel Mac or Linux arm64 only: install OCaml tools (opam, dune, ppxlib) | once; the needed packages are not mentioned |
| 1 | `git clone` and `pnpm run setup` | command |
| 2 | Change the Pulumi organization in `catalog-aws/Pulumi.alpha.yaml` and `ordering-aws/Pulumi.alpha.yaml` (three lines) | file edit |
| 3 | Optionally change the region in three stack files | file edit |
| 4 | Check the host-shell version (`grep`) | nothing to do for a new user |
| 5 | Layer: find the version, download the zip, publish it, store its address in SSM | 4 commands |
| 6 | `pnpm install` and `pnpm run build` (builds all three examples) | 2 commands, slow |
| 7 | `pulumi stack init alpha` and `pulumi up`, for each of the three projects, in order | 6 commands, each asks for confirmation |
| 8 | Bake the component manifest | **not documented; only CI does it** |
| 9 | `pnpm exec provision-admin --email …` | command |
| 10 | `pnpm exec provision-accounts` | **fails** on the default user pool |
| 11 | `pnpm run seed` | asks three questions |
| 12 | Edit `verify-subscriptions.mjs` (it holds another deployment's addresses), then run it | file edit and command |

## 2. The three problems that stop the shop from working

### 2.1 No Lambda layer in a new account

The deploy looks for the layer's address in `REVENTLESS_LAYER_ARN`, and otherwise
asks the AWS CLI for the SSM parameter
([Lambda.res](../../rescript/pulumi-aws/src/Lambda/Lambda.res),
`_resolveLayerArnFromSsm`). Only the maintainers' CI writes that parameter, and only
in its own account. In a new account the lookup finds nothing. **Every kind of
failure is ignored** — no AWS CLI, no permission, no parameter — and every function
is deployed without a layer.

The docs used to say functions would then include their own dependencies. They do
not. [Util_Bundle.res](../../reventless/aws/src/util/Util_Bundle.res) leaves the
framework and everything it depends on to the layer on purpose
(`isFrameworkPackage`, `addImportedPackageClosure`), and nothing checks whether a
layer is actually there. The deploy succeeds; the first request fails with
`Cannot find package`.
[layer-membership-is-not-resolvability.md](./layer-membership-is-not-resolvability.md)
explains how the code is split between the layer and the functions.

The layer file itself is easy to get: every `@reventlessdev/reventless-aws` release on
GitHub has `reventless-layer.zip` attached, and anyone can download it. What is
missing is something that puts it into the user's account.

### 2.2 Only CI writes the component manifest

The example platform asks for a baked manifest
([platform-aws/src/Main.res](../../examples/online-shop-hybrid/platform-aws/src/Main.res),
`bakedManifest: Storefront.manifest`). So the platform writes the manifest's address
into the web app's `config.json`, and provides a function that writes the file
(`bakedManifestFunction` in [Platform.res](../../reventless/aws/src/Platform.res)).

Something has to call that function once all plugins have registered. Only the
`bake-manifest` job in
[deploy-reventless-aws.yml](../../.github/workflows/deploy-reventless-aws.yml) does:
about 100 lines of shell script that read each plugin stack's `pluginStructureRef`,
call the function, and try again until every plugin has caught up.

The web app (`reventless-host-shell`) sends every user except members of `Admin` to
that file. If the file is missing, it shows an error on purpose rather than guessing.
So after a deploy by hand, **the administrator sees the shop, and the shopper,
merchandiser and fulfilment users see an error and nothing else.** The tutorial
never mentions the bake.

### 2.3 Creating the demo users fails on the default user pool

The user pool a deploy creates signs people in with an email address: the setting
`platform:loginIdentifier` defaults to `Email`
([Auth_LoginIdentifier.res](../../reventless/aws/src/adapter/Auth/Auth_LoginIdentifier.res)),
and there is no username option. `checkPoolAcceptsUsernames` in
[ProvisionAccounts.res](../../reventless/aws/scripts/ProvisionAccounts.res) then
refuses every user in
[users.example.yaml](../../examples/online-shop-hybrid/platform-aws/users.example.yaml),
because `admin`, `shopper`, `merch` and `fulfil` are not email addresses. Refusing is
correct; the file does not fit the pool it ships with.

It gets worse in two ways:

- The command **writes the generated passwords into `.reventless/users.yaml` before it
  checks the pool.** After the refusal, the file lists four users with passwords that
  exist nowhere, and `pnpm run seed` offers them.
- [test-on-aws.md](../../packages/doc/docs-tutorials/test-on-aws.md) says this step
  creates the users. The only thing that works as shipped is
  `provision-admin --email`, which makes a single administrator. The four-role demo
  cannot be reached on AWS without editing the file by hand.

Changing the names alone is not enough. The seed finds its demo users by the exact
names `shopper`, `admin` and `merch`
([DemoData.res](../../examples/online-shop-hybrid/seed-data/src/DemoData.res),
`demoShopperUsername` and the lines next to it).

## 3. Things that work, but cost steps or knowledge

### 3.1 Your machine and the tools

- **You have to clone the whole repository.** The deploy packages (`platform-aws`,
  `catalog-aws`, `ordering-aws`) are not published, and every example package
  depends on other packages in the repository. There is no template to start from.
- **Ready-made PPX binaries exist only for Linux x64 and Apple Silicon Macs**
  ([packages/reventless-ppx/package.json](../../packages/reventless-ppx/package.json),
  `optionalDependencies`). On Intel Macs and Linux arm64, setup builds the PPX from
  source with opam and dune. But [setup.mjs](../../scripts/setup.mjs) never installs
  the OCaml packages that build needs (`opam install . --deps-only`), although CI and
  the Dockerfile do, so the build fails on a fresh opam setup. Without opam, setup
  only prints a warning and the build fails later. Windows works only through WSL2.
- **Nothing checks the Node version.** No package outside `packages/doc` declares one.
- **`setup` builds the local version of the shop, not the AWS one,** and the root
  build compiles all three examples. A smaller build exists
  (`pnpm --filter ./examples/online-shop-hybrid/platform-aws run build`), but no page
  mentions it.
- **Maybe no build is needed at all.** The compiled JavaScript under `src/` is
  committed: the framework, the plugins, and the deploy entry points that Pulumi runs.
  `catalog-aws` and `ordering-aws` are never compiled by any build; Pulumi runs their
  committed `Main.res.mjs`. If those files are always up to date, a deploy needs only
  `pnpm install`, and the PPX and OCaml problems disappear for people who only want to
  deploy. **Not checked:** CI does not test that the committed files match their
  sources.

### 3.2 Pulumi

- **The maintainers' Pulumi organization is written into both plugins' stack files**
  as `reventless/…`. The setting `platform:stack` is read without a default
  ([Interstack.res](../../reventless/core/src/util/Interstack.res)). The organization
  cannot be found automatically today, because
  [Pulumi.res](../../rescript/pulumi-pulumi/src/Pulumi.res) does not include Pulumi's
  `getOrganization`.
- **Deleting `platform:stack` gives no error.** The plugin then deploys as a platform
  of its own, with its own GraphQL API (see the comment above the read in
  `Platform.res`). Someone who deletes the line they were told to edit gets a
  different setup and no warning.
- **`interstack:dependencies` does nothing.** No code reads it, yet `ordering-aws`
  sets it and the tutorial explains it. The tutorial also says Ordering depends on
  Catalog, while `deploy-manifest.yaml` says it depends on nothing.
- **You deploy three projects by hand, in the right order.** Nothing runs them for
  you. `deploy-manifest.yaml` is read only by CI and by `generate:platform`, and the
  `deploy` script in `reventless/aws` points at a `scripts/deploy.sh` that does not
  exist.
- **Both plugins' `Pulumi.main.yaml` name projects that do not exist**
  (`online-shop-hybrid-platform` and `online-shop-hybrid-catalog`; the real names end
  in `-aws`).
- **The seed, the reset tool, the reconcile tool and the client check always read
  stacks from Pulumi Cloud**
  ([SeedAws.res](../../examples/online-shop-hybrid/platform-aws/src/SeedAws.res)).
  Someone who uses Pulumi's local or S3 storage, and so needs no Pulumi account, gets
  "no deployed Pulumi stacks" unless they set `SEED_PULUMI_BACKEND`. The commands that
  create users do follow your login. The docs never say to log in to Pulumi.

### 3.3 The AWS account

- **The region `eu-west-1` is written into every stack file** and into
  `deploy-manifest.yaml`. The AWS CLI's default region, not the stack's, decides where
  the layer is looked up and where the user commands act.
- **Stack names change behaviour.** Every stack not named `pr-…` gets protected
  storage buckets that cannot be deleted while they hold files
  ([Util_StoreLayout.res](../../reventless/aws/src/util/Util_StoreLayout.res)). That
  includes `alpha`, the name the tutorial uses. Some stored objects are also kept when
  the stack is removed. Removing a try-out therefore needs
  `pulumi state unprotect`, emptying buckets by hand, and care with
  `pulumi stack rm`, which deletes a file that is in git. The seed reset tool only
  accepts `alpha`, `dev` or `pr-…` stacks that also set `reventless:wipeable`.
- **Possible limits of new AWS accounts, not checked here:**
  - AWS may refuse to create CloudFront distributions until a new account is verified.
  - Some new accounts limit Lambda memory to less than the 4096 MB that task functions
    use by default (`TaskRuntime_Builder_PerBucket`), and the catalog's import task
    uses that default.
  - Amazon Location (used to look up addresses) must be available in the chosen region.
- **The `main` stack creates an SES email identity that can never be verified**,
  because its sender is a placeholder at `example.com`. The `alpha` stack only writes
  emails to the log, which is the right choice for trying things out.

### 3.4 After the deploy

- **Two commands create users** when one would do: `provision-admin` and
  `provision-accounts` overlap, and the accounts file already lists an `admin`.
- **The sign-in form asks for a "Username"**, but the pool wants the email address.
- **The seed asks three questions**, cannot be run twice on the same data, and takes
  minutes (several hundred requests plus about 75 image uploads for the `full` set).
- **`verify-subscriptions.mjs` contains another deployment's addresses** and uses two
  packages it does not declare. `pnpm run verify:client-publish`
  (`VerifyClientPublish.res`) already finds everything from `config.json` and could
  replace it.
- `test-on-aws.md` still describes `REVENTLESS_UPLOAD_ENDPOINT`, which nothing reads
  any more.

### 3.5 Deploying from your own copy with CI

The shared CI workflow needs the secrets `PULUMI_ACCESS_TOKEN`, `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY` (fixed keys, no short-lived login), GitHub environments named
`deploy-platform` and `deploy-<plugin>`, and the SSM layer parameter. None of this is
written down where a new user would look:
[CICD_SETUP.md](../guides/CICD_SETUP.md) covers testing, releases and security, but
not deploying.

## 4. The goal

```bash
# once per machine: Node 22 via corepack, AWS credentials, log in to Pulumi
git clone https://github.com/ReventlessDev/reventless-core && cd reventless-core
pnpm run setup
pnpm run shop:up        # layer, stacks, manifest, users — prints the address and sign-ins
pnpm run shop:seed      # optional
# …and later
pnpm run shop:down      # removes everything shop:up created
```

The command names are placeholders. `shop:up` has to do these things, in order, and be
safe to run again:

1. **Check first:** Node version, AWS credentials and region, Pulumi login, and the
   new-account limits from §3.3. Each failure says how to fix it, before anything is
   created.
2. **Stacks:** select or create one stack per project in `deploy-manifest.yaml`, under
   the organization you are logged into, with the region and `platform:stack` filled
   in. No file edits.
3. **Layer:** make sure a layer for the installed `reventless-aws` version exists in
   this account and region (§5.1).
4. **Deploy** in the order `deploy-manifest.yaml` gives, without questions.
5. **Bake** the manifest, with the same "has every plugin caught up?" check CI uses
   (§5.2).
6. **Users:** create the four demo users (§5.3).
7. **Print** the web address and the sign-ins.

`shop:down` does the reverse. Try-out stacks are created as disposable, so there is
nothing to unprotect or empty by hand.

## 5. What it takes

### 5.1 Who creates the Lambda layer

#### How layers can be shared

A layer version belongs to **one AWS account and one region**, and it cannot be
changed once published. A function in another account can use it only if the owner
gives permission — to one account, to a whole AWS Organization, or to everyone — and
only in the same region, where the layer has its own address. There is no way to copy
a layer to another account. "Copying" means downloading the zip (which also needs the
owner's permission) and publishing it again.

Reventless adds one more rule: **the layer must match the exact `reventless-aws` code
the functions use.** The functions load the framework from the layer by file path, so
a layer from another version fails at runtime, not during the deploy. *Which version*
matters as much as *which account*. For scale: the layer zip is about 16 MB, and
`reventless-aws` has had 346 alpha releases so far.

#### The options

**1. A public layer in a maintainers' account.** The maintainers publish the layer in
every region for every release and let everyone use it. Users only need its address.
Several well-known tools share their layers this way.

- *For:* nothing to set up. A published version cannot change, so its address is
  safe to pin. Storage is small: the storage limit applies per region, and 346 versions
  of 16 MB are about 5.5 GB.
- *Against:*
  - Every release must reach every region a user might choose, and alpha releases come
    several times a week. That publishing job will sometimes lag behind.
  - Someone working **between two releases** has no matching layer at all, which is
    exactly the mismatch that fails at runtime.
  - Users run code from someone else's account. Companies that restrict layers (with
    IAM's `lambda:Layer` condition or organization-wide rules) refuse it outright.
  - All users depend on one account. If it is closed, broken into, or a version is
    deleted by mistake, running functions keep working, but the next deploy fails.
  - The maintainers must look after a public artifact for years.

**2. A layer shared inside one company.** A company with many AWS accounts publishes the
layer once per region in a central account and shares it with its AWS Organization.

- *For:* one layer for the whole company, inside its own walls. It already works today
  with `REVENTLESS_LAYER_ARN`.
- *Against:* the company must run the publishing itself, with option 1's region and
  version problems on a smaller scale. It does not help someone trying the shop in a
  personal account.

**3. Each account publishes the release zip.** This is what the tutorial now describes:
download `reventless-layer.zip` from the matching release, publish it, and store its
address in the SSM parameter — by hand or with a script.

- *For:* fully independent. No other account is involved, and it works in any region
  and under any company rule. It reuses the zip every release already publishes.
- *Against:* an extra step outside the deploy. A wrong region or version only shows up
  at runtime. The SSM parameter is something Pulumi does not know about. Someone
  working between releases still has no matching zip.

**4. The platform stack creates the layer.** When the platform stack deploys, it creates
the layer in its own account and region, and passes the address to the plugin stacks,
which already know the platform stack.

- *For:* nothing to do for the user. Account and region are right automatically. No SSM
  parameter and no AWS CLI call. `pulumi destroy` removes the layer. CI and users work
  the same way.
- *Against:* needs a new Pulumi binding, a change to how CI deploys, and a source for the
  layer's content during the deploy. There are three possible sources:
  - **Download the release zip during the deploy.** Simple, but it needs internet access
    during `pulumi up`, can run into GitHub's download limits, and has no zip for someone
    working between releases.
  - **Publish the layer as its own npm package**, with exactly the same version as
    `reventless-aws` (for example `@reventlessdev/reventless-aws-layer`). The version
    matches through normal dependencies, and the lockfile checks the download. It costs
    one more package to release and about 16 MB more to install.
  - **Build it from the packages already installed** on the machine that deploys. This is
    the only source that *always* matches, even between releases or with a patched
    package, and it needs no internet. The existing layer builder already knows what to
    keep and what to leave out, but it downloads from npm; it would have to read the
    installed packages instead. It costs time on every deploy.

**5. No layer at all.** Put the framework into every function's code package.

- *For:* no layer to think about, and each function matches its code exactly.
- *Against:* every function package grows by tens of megabytes, uploads and cold starts
  get slower, AWS's 250 MB limit comes closer, and it undoes a deliberate design. Not
  recommended.

#### Keep publishing the zip

The release zip is what options 1, 3 and 4 are built on, and keeping it costs nothing.
Add a checksum file next to it, so a download can be checked. Also consider the npm
package from option 4, which turns "download the right file from GitHub" into a normal
dependency.

#### Recommendation

1. **Stop the deploy when no layer is found.** Today the missing layer is ignored, and
   that is what turns a small setup mistake into a failure nobody can trace. This is
   small and does not depend on the rest.
2. **Make option 4 the default, building from the installed packages**, or from the npm
   package if building during the deploy turns out too slow. A new account then needs
   nothing, the layer cannot be the wrong version, and it disappears with the stack.
3. **Keep `REVENTLESS_LAYER_ARN`** for companies that share a layer (option 2).
4. **Until option 4 exists, use option 3**, run by the deploy command rather than by
   hand.
5. **No public shared layer for now.** Frequent alpha releases, many regions and the
   between-releases gap make option 1 the most work for the least reliability. It could
   become an extra later, once there are stable releases.

This is planned in
[platform-stack-creates-the-lambda-layer.md](../plans/platform-stack-creates-the-lambda-layer.md).

### 5.2 A manifest bake for every way of deploying

- **One shared bake command** in `reventless-aws`, written in ReScript instead of CI
  shell script. It reads the stack outputs, calls the bake function, waits while a
  plugin is still `behind`, and reports `missing` and `diverged` plainly. CI and the
  deploy command both use it, so the two cannot drift apart.
- **Or the platform bakes by itself** whenever the list of registered plugins changes,
  which would also cover a plain `pulumi up`. The difficulty: something reacting to
  that list does not know which deploy it belongs to. CI's "has every plugin caught
  up?" check exists so the manifest never describes the *previous* deploy. This is best
  thought through together with
  [a-stale-handshake-answer-asks-again.md](../plans/a-stale-handshake-answer-asks-again.md),
  which is the same "not caught up yet" problem from the other side.

Recommendation: the shared command first. Only move to a platform that bakes by itself
if the "which deploy is this?" question gets a good answer.

### 5.3 Demo users the default user pool accepts

- **Check the pool before writing the accounts file.** A small fix to the order of work
  in `ProvisionAccounts.run`, independent of everything else.
- **Use email addresses in the AWS template.** Provisioning already tells Cognito not to
  send invitations (`MessageAction: "SUPPRESS"` in
  [ProvisionCognito.res](../../reventless/aws/scripts/ProvisionCognito.res)), so
  addresses under the reserved `example.com` are safe. The seed then needs another way
  to find its demo users:
  - **Match the part before the `@`.** No change to the file format, but a hidden rule
    that breaks as soon as someone names the shopper `jane@…`.
  - **Add a field to each entry saying which demo person the account plays.** Clear and
    robust, but it adds a field to the shared accounts file format that only demos use.

  The explicit field is the better choice. If this mapping is wrong, it fails silently:
  the views are full for whoever ran the seed and empty for everyone else. So it should
  be written down, not guessed.
- **One command for all users.** `provision-accounts` already creates the administrator
  when the file lists one. The deploy command runs only that; `provision-admin` stays
  for its own use cases (a user pool you bring yourself, a single extra administrator).

### 5.4 Pulumi without editing files

- **Find the organization automatically.** Add Pulumi's `getOrganization` to the
  bindings, so the deploy command can fill in `platform:stack` as
  `<your organization>/<platform project>/<stack>`. Take the project names from each
  folder's `Pulumi.yaml`. `deploy-manifest.yaml`'s `platform.name`
  (`online-shop-hybrid-platform`) does not match the real project name
  (`…-platform-aws`).
- **Make a missing `platform:stack` an error** where a plugin is deployed, instead of
  quietly turning the plugin into a platform.
- **Remove `interstack:dependencies`**, and fix the two `Pulumi.main.yaml` project names.
- **Let every helper script follow your Pulumi login**, keeping `SEED_PULUMI_BACKEND` for
  those who need a fixed choice. Then Pulumi's local storage works everywhere, and a
  Pulumi account is no longer required.

### 5.5 Try-out stacks

- **A new stack setting that marks a try-out as disposable**, for example
  `reventless:disposable: "true"`: storage unprotected and deleted with its content. The
  deploy command sets it on every stack it creates, so `shop:down` is one command.
- **Do not reuse `reventless:wipeable` for this.** `alpha` already sets `wipeable`, which
  lets the reset tool empty it on purpose after asking. It does not mean storage may be
  deleted by accident, and a comment in `Util_StoreLayout.res` says exactly that. Reusing
  the flag would remove `alpha`'s protection. (An earlier version of this analysis
  suggested reusing it; that was wrong.)
- **Use a stack name that is not a CI branch**, such as `dev`, created with the region
  from your environment and with its settings file kept out of git. New users then stop
  editing files that are in git, and the CI stacks' files stay as they are.

### 5.6 Tools on your machine

- Publish PPX binaries for Intel Macs and Linux arm64 (the
  [prebuilt-binaries plan](../plans/prebuilt-binaries-out-of-repo.md) already describes
  an Intel Mac route). When setup builds the PPX from source, install the OCaml packages
  first. Check the Node version at the start.
- Find out whether the committed JavaScript is enough to deploy (§3.1). If it is, add a
  CI check that it matches its sources, and let people who only deploy skip the build
  and the PPX completely.
- Later: deploying without cloning the repository needs published deploy packages or a
  template. That is a bigger change and not needed to reach the goal in §4.

### 5.7 Keep it working

Each of the three problems in §2 hides behind a step that reports success, and the
maintainers' own deploys cannot catch any of them: their account already has the SSM
parameter, CI bakes the manifest, and nobody creates the demo users again. **A deploy
from scratch on a schedule** — a throwaway stack with no SSM parameter, run by the same
command a user runs, ending with a sign-in as each demo user and one page read each — is
the only test that follows a new user's path. Without it, the path will break again
without anyone noticing.

## 6. The work, in order

| # | What | Removes | Size |
|---|---|---|---|
| 1 | Stop the deploy when no layer is found | the silent layer problem | small |
| 2 | Check the pool before writing the file; email addresses in the AWS template; a field for the demo person | the user problem | small–medium |
| 3 | Shared bake command, also used by CI | the manifest problem, for anyone who runs it | medium |
| 4 | Deploy command `shop:up` / `shop:down` over `deploy-manifest.yaml`: checks, stacks, layer, deploy, bake, users | steps 2–10 in §1 | medium |
| 5 | Find the Pulumi organization; error when `platform:stack` is missing; fix `Pulumi.main.yaml`; remove `interstack:dependencies` | file edits | small |
| 6 | Disposable try-out stacks | removing a try-out by hand | small |
| 7 | Helper scripts follow the Pulumi login | the need for a Pulumi account | small |
| 8 | Platform stack creates the layer, from the installed packages (or an npm package); a checksum next to the release zip | SSM, the AWS CLI call, wrong region or version | medium |
| 9 | Deploy from scratch on a schedule | problems coming back unnoticed | medium |
| 10 | PPX binaries, OCaml packages, Node check; decide whether deploys need a build | Intel Mac and Linux arm64 problems | medium |
| 11 | Replace `verify-subscriptions.mjs` with `verify:client-publish`; fix old seed docs | leftovers | small |
| 12 | Deploy without cloning the repository | the clone | large |

Items 1–4 make the tutorial work at all and shrink it to the goal in §4. Items 5–7 remove
the remaining file edits and requirements. Items 8–12 make it reliable and easier to
start with. Items 1–7, 9 and 11 are in
[shop-from-an-empty-aws-account.md](../plans/shop-from-an-empty-aws-account.md); item 8
is in [platform-stack-creates-the-lambda-layer.md](../plans/platform-stack-creates-the-lambda-layer.md).

## What we checked, and what we did not

- **Read in the code, and clear:** the layer lookup and how it ignores failures; that the
  function code leaves the framework to the layer; that only CI bakes the manifest and
  the web app does not fall back; the email default, the refusal, and that the file is
  written before the check; the exact demo user names; the fixed Pulumi organization; the
  unused `interstack:dependencies`; the wrong `Pulumi.main.yaml` project names; the fixed
  Pulumi Cloud setting; the stack-name rules; the list of PPX binaries and the missing
  OCaml install step.
- **Measured:** the release zip size (about 16 MB, `3.0.0-alpha.346`) and the number of
  alpha releases (346).
- **Not tried:** none of this has been run in a new account. The results in §2 follow
  directly from the code, but nobody has seen them happen.
- **General AWS behaviour, not checked here:** CloudFront verification of new accounts,
  Lambda memory limits of new accounts, and whether Amazon Location is available in a
  region. For §5.1: who a layer can be shared with, that the storage limit applies per
  region, the `lambda:Layer` condition, and that functions keep a deleted layer version
  until their next update.
- **Still open:** whether the committed JavaScript is enough to deploy (§3.1), and whether
  a platform that bakes by itself can tell which deploy it belongs to (§5.2).
