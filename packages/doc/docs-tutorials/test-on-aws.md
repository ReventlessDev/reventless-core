---
title: Test it on AWS
---

# Test the deployed shop

Once the stacks are up (from [Deploy to your AWS account](./deploy-to-aws)), this
page shows how to find the live URLs, sign in, and verify the end-to-end path —
including live subscriptions.

## Find the live URLs

The platform stack exports the endpoints. From `platform-aws/`:

```bash
pulumi stack output --stack alpha
```

Look for the AppSync GraphQL endpoint and the CloudFront URL that serves the
host-shell SPA. Open the CloudFront URL in a browser.

## Log in against deployed Cognito

The deployed platform authenticates against the Cognito user pool configured on
the [deploy page](./deploy-to-aws) (Step 2). A freshly auto-provisioned pool has
no users yet. One command, run from `platform-aws/`, creates the shop's four demo
accounts:

```bash
pnpm exec provision-accounts
```

The committed `users.example.yaml` is copied to `.reventless/users.yaml` on first
run, so there is nothing to copy by hand. It creates `admin@example.com`,
`shopper@example.com`, `merch@example.com` and `fulfil@example.com` with their
groups, sets a generated permanent password for each (no password-change
challenge on first sign-in), and writes the passwords and the ids the pool minted
back into `.reventless/users.yaml` — read the sign-ins from there. The usernames
are addresses because a pool the deploy creates signs people in by email address;
`example.com` is reserved, so no mail reaches anyone. The seed below reads the
same file, so the demo data lands on the accounts you can actually log in as —
which is what makes `fulfil` and `merch` show different screens instead of empty
ones.

The tool checks the pool before it writes anything: if the pool could not sign in
one of the accounts, it stops and leaves the file as it was.

Sign in to the host-shell as `admin@example.com` and run the same smoke test you
ran locally: add a category and product, register a customer, place an order, and
confirm read models update.

### An administrator of your own

To sign in with your own address instead, make one administrator:

```bash
pnpm exec provision-admin --email you@example.com
```

That creates the account, sets a permanent password, puts it in the `Admin`
group, and prints the credentials once. Running it again is safe and mints a new
password.

Doing this by hand with `aws cognito-idp admin-create-user` works too, but it is
easy to stop one step early: an account that is not in the `Admin` group cannot
reach the administration views, and the symptom is a refusal much later. See
[The first administrator](/app/first-admin) for the full picture, including why being
in the group is only half of what makes someone an administrator.

## Seed demo data (optional)

To fill the views without clicking through by hand, run the demo seed against the
deployment. It drives the same public GraphQL command API as locally. The AWS
seed targets AWS by construction — run it from `platform-aws/`:

```bash
cd examples/online-shop-hybrid/platform-aws
pnpm run seed
```

It first asks which data set to seed (`full` or `sample`), then picks the stack
(one Pulumi stack auto-selects; otherwise it lists the stacks or reads
`SEED_STACK`). It reads that stack's `config.json` — the same file the host-shell
boots from — for the GraphQL and upload endpoints, region and Cognito client (or
the stack outputs directly when no host-shell URL is published), then asks which
account to seed as.

The accounts it offers come from `.reventless/users.yaml` beside the platform
(the file that records what was created in the pool), listed in the order the
file defines them with the first as the default; it holds the password too, so
there is nothing to type. Each must exist in the pool with a permanent password,
per the previous section. `SEED_USER` picks one by username or 1-based index, and
`SEED_USERS_FILE` points at a file elsewhere. Without such a file the seed asks
for a username and password instead.

Set `SEED_SET` (`full` or `sample`), `SEED_STACK` (the stack name), plus
`REVENTLESS_DEMO_USER`/`REVENTLESS_DEMO_PASSWORD` for a non-interactive (CI) run
— that pair bypasses the accounts file, so CI needs no copy of it.
The seed is non-idempotent — run it against a fresh deployment, not on top of
existing data.

**Skipping image uploads.** `SEED_SKIP_UPLOADS=1` seeds the domain data without
uploading product images (`imageUrl` is left empty) — use it when the deployment
serves no upload endpoint, or to seed fast.

**Pulumi backend.** The seed reads the stack from whatever backend your `pulumi`
CLI is logged into — Pulumi Cloud, a local directory, or an S3 bucket.
`SEED_PULUMI_BACKEND` names another backend for one run; it is passed as
`PULUMI_BACKEND_URL` on a copy of the environment, so your persistent
`pulumi login` is never changed. A self-hosted app can pin its own store in code
instead, e.g. `ReventlessSeedAws.connect(~backend="s3://<bucket>?region=<r>", ())`.

## Verify live channels end to end

The example ships a check that finds the deployment by itself and exercises the
browser's side of the live channels: a signed-in user subscribes to a
client channel, publishes to it and receives the event, and is refused when
publishing to the channel the platform's own change notifications travel on.

```bash
cd examples/online-shop-hybrid/platform-aws
pnpm run verify:client-publish
```

It picks the stack the way the seed does (`SEED_STACK` fixes it), reads the
endpoints from the deployment's `config.json`, and asks for a sign-in from
`.reventless/users.yaml`. It needs no AWS credentials.

## What you've proven

The deployed application runs the identical plugin code you tested locally — now
on real AWS infrastructure (DynamoDB, Lambda, SQS, AppSync, CloudFront, Cognito),
with live subscriptions flowing through the StateTopic Lambda to WebSocket
clients.

---

**Where to next?**

- Build your own application → [App Guide](/app/get-started).
- Point the deployed shell at your own domain →
  [Custom domain for the host UI](/infrastructure/custom-domain).
- Contribute to the framework → [Contributing](/framework/contributing).
