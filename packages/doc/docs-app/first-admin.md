---
title: The first administrator
sidebar_label: First administrator
---

# The first administrator

A deployed Reventless platform authenticates every caller, and it starts with no
accounts at all. That is deliberate — accounts are not stack resources, and a
`pulumi destroy` should not be able to empty a directory of people — but it does
mean there is exactly one step between a successful deploy and an application you
can sign in to. This page is that step.

It applies to **cloud deployments only**. The local platform ships with a built-in
`admin` account already in the administrator group, so nothing here is needed
while you are developing — see [Run and deploy](./local-development.md).

## What a deploy creates, and what it does not

A default (auto-mode) deploy provisions the whole identity side except the people:

| The stack creates | The stack does not create |
| --- | --- |
| The identity provider (a Cognito user pool) | Any account |
| The app client the UI signs in through | |
| The `Admin` group | |
| An elevated-groups default naming `Admin` | |

The last row matters more than it looks, and it is covered in
[Two mechanisms, one answer](#two-mechanisms-one-answer) below.

## The one command

From your `platform-aws` package, once `pulumi up` has finished:

```bash
pnpm exec provision-admin \
  --provider-id $(pulumi stack output identityProviderId) \
  --email you@example.com
```

It creates the group if it is missing, creates the account if it is missing, sets
a **permanent** password, adds the account to the group, and prints what you need:

```text
pool     eu-west-1_AbCdEfGhI
group    Admin (already present)
user     you@example.com (created)
password (set, permanent)
member   you@example.com in Admin

The first administrator is ready.

  provider   eu-west-1_AbCdEfGhI
  sign in as you@example.com
  password   rHq7TmXkPd3wFvNbGz8y
  group      Admin
```

The password is generated rather than asked for, because Cognito keeps no
recoverable copy — it exists in that output or nowhere. Treat it as a bootstrap
credential: sign in, change it, and do not paste it where logs are kept. Running
the command again is safe and mints a new one, which is the usual reason to run it
twice.

The command provisions nothing a stack owns — no pool, no table, no trigger — so
it is safe to run against a deployment that is already live.

## Signing in

Open the host-shell URL from the stack outputs and sign in with the address and
password above. Because the password was set as permanent, there is **no**
password-change challenge on first sign-in; you land straight in the application.

You should be able to reach the administration views (the Plugins view among
them) and to read owner-scoped views belonging to other people. If you can sign in
but owner-scoped views come back **empty**, that is the specific failure the next
section describes.

## Two mechanisms, one answer

"Who is an administrator" is decided twice, by two independent mechanisms, and
nothing makes them agree:

1. **Authorization** — whether a caller may reach a field at all. This is what
   `@@reventless.authorize(AllowGroups(["Admin"]))` states, and it is checked per
   command and per query. See [Authorization](./authorization.md).
2. **Owner scoping** — whether a caller reads across owners or only their own
   rows. This is `REVENTLESS_ELEVATED_GROUPS`, and it is what `@owner` narrows on.

They fail differently, and the second fails quietly. A caller outside the group
gets a refusal, which is visible. A caller in the group but *not* elevated passes
every authorization check and then sees empty screens — because an empty
owner-scoped view and a view with nothing in it are indistinguishable.

A default deploy sets both for you: the stack declares the `Admin` group and
defaults the elevated list to it, so an administrator provisioned by the command
above is elevated without anyone configuring anything.

**If you override one, override both.** A deployment that names its own operator
groups:

```rescript
Reventless.OwnerScope.setElevatedGroups(["Admin", "Fulfilment"])
```

wins over the default entirely — including the empty list, if you deliberately
elevate nobody. Setting `REVENTLESS_ELEVATED_GROUPS` counts as answering too, so a
value you export in CI is not overridden. What you must not do is narrow *one*
mechanism and leave the other: a group that authorizes but is not elevated is the
empty-screens case above, and a group that is elevated but not authorized is
simply refused.

You can read the group name back from the stack rather than from source:

```bash
pulumi stack output identityProviderAdminGroup
```

## The rest of the cast

`provision-admin` stops at one account on purpose: the first administrator is the
one that cannot be made from a signed-in session, because there is no signed-in
session yet. Everyone else — a demo's shopper and merchandiser, a company's
staff — is a list, and a list belongs in a file rather than in a dozen CLI
invocations.

Declare them in `.reventless/users.yaml`, beside the platform package you deploy
from:

```yaml
- username: shopper
  password: ""
  groups: [Shopper]

- username: merch
  password: ""
  groups: [Merchandiser, Shopper]
```

Then:

```bash
pnpm exec provision-accounts \
  --provider-id "$(pulumi stack output identityProviderId)"
```

For each entry it creates the groups named, creates the account, sets a permanent
password and applies the memberships — then **writes back into the file** the two
things you cannot know in advance: the generated password, and the `sub` the pool
minted. That second one matters more than it looks: owner-scoped rows are keyed by
it, and `pnpm run seed` reads it to key demo data to the accounts you actually log
in as. Nobody pastes a UUID.

Leave `password: ""` and one is generated for you. **A password already in the
file is never replaced**, so a second run is safe — which is the normal case, because
adding one colleague to a list of four means running it again.

The command knows nothing about any particular application's cast; the manifest is
yours. Each example ships a `users.example.yaml` beside its `platform-aws` package
to copy from.

### It also runs with no AWS account

```bash
pnpm exec provision-accounts --prepare-only
```

Validates the manifest and fills in empty passwords, and creates nothing. That is
the *whole* of provisioning on the local platform, where the manifest **is** the
user store — the in-memory auth adapter hydrates from it at startup, so there is
no principal to create. Same file, same format, same command; only the second half
is Cognito's.

### What is still missing

Runtime user administration — adding a colleague from inside the running product.
That is a different problem, and the framework is growing an identity capability to
own it. `provision-accounts` is a provisioning tool: it is for standing a
deployment up, not for running it.

If you are self-registering rather than administering, note that a pool is created
admin-only by default; `platform:signUpMode` opens it. See
[Platform capabilities](./platform-capabilities.md).

## On a supplied pool

If you deploy against an identity provider you already own — a pool set with
`platform:identityProviderId` rather than created by the stack — none of the
auto-mode conveniences apply to the pool itself:

- The stack does **not** declare the `Admin` group. A group is a pool-level fact,
  and two stacks sharing one provider would each try to declare it, with the
  second failing on a name that already exists. `provision-admin` creates it
  instead, beside the first administrator who needs it.
- Everything else is the same. The command takes the same arguments, and
  `--provider-id` defaults to `REVENTLESS_IDENTITY_PROVIDER_ID`, which a BYO
  deployment usually exports already.
- The elevated-groups default still applies — it is a property of the platform,
  not of who created the pool.

The pool and its active-role store are provisioned by
`pnpm exec provision-identity`, which is a separate bin because it provisions
infrastructure and this one deliberately does not.

## Related

- [Authorization](./authorization.md) — the rules, `@owner`, and elevation
- [Run and deploy](./local-development.md) — the local platform's built-in accounts
- [Test it on AWS](/tutorials/test-on-aws) — the rest of the first-deploy walkthrough
