# Plan: the deploy workflow names its state backend

**Date:** 2026-10-05<br/>
**Status:** 📝 Drafted, not started.<br/>
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
