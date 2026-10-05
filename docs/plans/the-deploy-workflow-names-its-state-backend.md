# Plan: the deploy workflow names its state backend

**Date:** 2026-10-05<br/>
**Status:** 🚧 S1, S3 and S4 built 2026-10-05; S2 (a real pull request on an S3 backend) is
open. See *As built*.<br/>
**Touches:** `.github/workflows/deploy-reventless-aws.yml` (the reusable deploy workflow),
`docs/guides/deploy-environments.md`, and a new section of the deploy guide. `reventless/aws`
only if a check of the local deploy finds it needs one (S4).<br/>
**Builds on:** [an-app-declares-its-environments](an-app-declares-its-environments.md) (E2 and
E3: the stacks a push, a tag and a pull request deploy to).

## Goal

An app whose Pulumi state lives in a self-managed backend (an S3 bucket, say) deploys with the
reusable workflow just as an app on Pulumi Cloud does: the same jobs and environments, and the
same review stacks per pull request. It names its backend and its secrets provider, and passes no
Pulumi access token.

## Why

- **The workflow assumes Pulumi Cloud.** Nothing in it sets `PULUMI_BACKEND_URL`, and
  `PULUMI_ACCESS_TOKEN` is a required secret. A caller on a self-managed backend has to copy the
  workflow and set the URL by hand in every job. Its copy then misses each change made here: the
  environments of E2, the review stacks of E3, tag deploys.
- **The workflow already describes backends, but only half of it.** `pulumi-concurrent-updates`
  says whether the backend tolerates parallel updates, and its description names self-managed
  backends. The backend itself is the missing half.
- **A stack the workflow creates gets the wrong secrets provider.** E3 creates review stacks
  with `pulumi stack select --create`, and E2 creates a stack for an environment deployed for
  the first time. On a self-managed backend a new stack defaults to the passphrase provider. A
  team that encrypts with a KMS key (`awskms://alias/…`) then has a stack it cannot decrypt
  without a passphrase it never set. `pulumi config cp` from the base stack fails the same way.
- **Open consumers today:** any app deploying with this workflow to a self-managed backend.
  `seed-aws` already takes a backend URL (`ReventlessSeedAws.res`), so seeding such an app works
  and deploying it does not.

## S1 — Two inputs and an optional token

- **`pulumi-backend-url`** (string, default empty): when set, exported as `PULUMI_BACKEND_URL`
  in every job that runs Pulumi (platform, plugins, bake, destroy-review). Empty keeps today's
  Pulumi Cloud login.
- **`pulumi-secrets-provider`** (string, default empty): passed as `--secrets-provider` wherever
  the workflow creates a stack (`stack select --create`, `stack init`). It may hold `{stack}`,
  replaced by the stack's name, for a team with one key per environment
  (`awskms://alias/app-pulumi-{stack}?region=…`). For a review stack, `{stack}` is the base
  environment's stack, so the review stack shares the base's key. Empty keeps Pulumi's default.
- **`PULUMI_ACCESS_TOKEN`** becomes optional. A job fails early, saying why, when neither the
  token nor a backend URL is given.
- The concurrency group and `max-parallel` stay with `pulumi-concurrent-updates`. Its
  description already says to set it for a self-managed backend.

### Tests

- The workflow parses, and every `run:` script passes `bash -n` (as E3 checked).
- The resolve-and-select steps, run locally against a `file://` backend standing in for S3:
  - a new stack gets the provider named, with `{stack}` replaced;
  - a review stack gets the base's provider;
  - `config cp` from the base works;
  - with no backend input, the behaviour is today's.

## S2 — A review stack on a self-managed backend

E3 has not yet run against a real pull request. Run it once against an S3 backend, from opening
the pull request to closing it:
- the review stacks are created with the base's secrets provider;
- the configuration is copied;
- the app deploys and is reachable;
- closing the pull request removes the stacks.

Record what happened in E3's *As built*.

## S3 — The guide

The deploy guide gets a section *A self-managed state backend*. It covers:
- the two inputs, and the permissions the deploy identity needs (the state bucket, and the
  KMS key when one is used);
- the secrets provider for stacks the workflow creates;
- `pulumi-concurrent-updates: true`;
- migrating existing stacks: `pulumi stack export` and `import`, then `change-secrets-provider`
  once per stack.

`deploy-environments.md` gets one paragraph on review stacks and the secrets provider.

## S4 — The local deploy

`deploy-app` uses whatever Pulumi login is active. Its error message, when no login is found,
names only Pulumi Cloud and `--local`. Check a local deploy against an S3 backend. Make the
message name `pulumi login s3://…` too, and change anything the check finds.

## Risks

- **A wrong provider on an existing stack is not touched.** The input applies only to stacks
  the workflow creates. A stack created earlier with the passphrase provider keeps it until
  `change-secrets-provider`. The guide says so.
- **Per-environment keys.** `{stack}` covers one key per stack name. A team with another scheme
  sets the provider in each `Pulumi.<stack>.yaml` itself and leaves the input empty.

## Not in scope

- Which backend an app should choose.
- Reading Pulumi state after a deploy: whoever reads it, reads it from the backend the app
  chose.

## As built (2026-10-05)

- **S1** as planned: `pulumi-backend-url`, `pulumi-secrets-provider`, and an optional
  `PULUMI_ACCESS_TOKEN`. Each job that runs Pulumi starts with *Check the Pulumi backend*. A
  *Resolve secrets provider* step after *Resolve environment* replaces `{stack}`, using the
  base stack for a review. Both `stack select --create` steps pass the result. The workflow has
  no `stack init`. Checked locally: the YAML parses, and all 40 `run:` scripts pass `bash -n`.
  The platform job's steps were taken from the YAML and run against a `file://` backend through
  a `pulumi` shim that logs each call. Five cases: a new environment stack (`{stack}` replaced),
  a review stack (the base's provider, configuration copied, secret readable), a second push
  from a fresh runner, no inputs (the command line is the same as before), and neither token nor
  URL (the job fails, naming both). The shim ran `awskms://` as `passphrase`. Run directly,
  `stack select --create --secrets-provider awskms://…` calls KMS for a new stack and ignores
  the flag for an existing one.
- **Found and fixed in E3:** a review stack's configuration was never copied on any backend
  whose secrets provider writes the stack file. `stack select --create` writes
  `Pulumi.<stack>.yaml` (the salt or the KMS key), and only after that did the step test
  whether the file was missing. The test now runs before the select. On Pulumi Cloud's default
  provider no file is written, which is why E3's check did not see it.
- **S3** *4i. A self-managed state backend* in `docs-infrastructure/deployment-guide.md`, the
  secrets table updated, and a paragraph in `deploy-environments.md`. **Changed from the plan:**
  the migration changes the secrets provider *before* the export, not after the import.
  `stack init` on the new backend reuses the encryption settings in `Pulumi.<stack>.yaml`
  (observed against `file://` backends), so a stack imported first is left with secrets the new
  backend cannot decrypt. Not run end-to-end: that needs a real KMS key.
- **S4** the "not logged in" message names `pulumi login s3://<bucket>`, and so does the
  tutorial. Checked by running `deploy-app up` not logged in, and against a `file://` backend
  without a passphrase: both stop at the check with the right message. Nothing else needed
  changing. An `s3://` URL takes the same path as `file://`, and the stacks `deploy-app`
  creates use the passphrase that check asks for. Not run: an `up` against a real bucket.
- **Not built:** a passphrase input. A self-managed stack on the passphrase provider cannot be
  deployed by the workflow; the guide says to change it to a key.
- **Found and fixed in E3, any backend:** a review plugin stack deployed against the *base*
  platform. `config cp` copies `platform:stack: <org>/<platform>/<base>` verbatim, so a pull
  request would have registered its plugins on the shared environment's API. After the copy,
  the up step now rewrites every plain setting naming `<org>/<project>/<base-stack>`, for a
  project in the deploy manifest, to the review stack. That covers `platform:stack` and
  JSON lists such as `interstack:dependencies`. A stack the app does not deploy keeps its
  reference. Checked against a `file://` backend: own references retargeted, a foreign
  project, a near-miss name (`…/devX`) and a secret untouched. Checked on the hybrid example's
  real project names as well.
- **Checked against the business repo's S3 estate (read-only):** its stacks use
  `awskms://alias/reventless-pulumi-alpha?region=eu-central-1`, one key per stack name, which
  is what `{stack}` is for. Its own migration from Pulumi Cloud found the same order as S3
  (change the provider on Pulumi Cloud first). It also found the org rewrite
  (`<org>/` → `organization/`) the guide now covers. It deploys from a fork of this workflow
  with the URL hard-coded, waiting for `pulumi-backend-url`.
- **S2 open:** a pull request opened, updated and closed against an S3 backend on AWS. The
  business estate has no review environment and no `pull_request` trigger, so running S2 there
  means first moving it onto this workflow.
