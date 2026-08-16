---
title: Authorization
sidebar_label: Authorization
---

# Authorization

Reventless is authenticated by default: every command and every query expects a
caller, and the framework decides what that caller may do before your decision
logic runs. This page covers what the defaults are, how to narrow them, and how
to exercise the result locally.

## The default is "any authenticated caller"

Every command-carrying component (aggregate, StateChangeSlice,
InboundTranslationSlice) gets a `commandAuthorization` binding, and every
query-carrying one (ReadModel, StateViewSlice) gets an `authorization` binding,
injected for you with the rule `AllowAuthenticated`. So a spec that says nothing
about authorization is already closed to anonymous callers — you narrow from
there rather than remembering to lock something down.

The four rules:

| Rule | Allows |
|---|---|
| `AllowAuthenticated` | Any caller who signed in. The default. |
| `AllowGroups(["Admin", "Merchandiser"])` | Callers in at least one of the named groups. |
| `AllowAnonymous` | Everybody, signed in or not. Use deliberately. |
| `DenyAll` | Nobody. For a command only another component may issue. |

Groups are plain strings, not a framework enum, so your application's group
vocabulary stays yours.

## Narrowing a whole file

Put the rule at the top of the spec file:

```rescript
@@reventless.spec
@@reventless.authorize(AllowGroups(["Admin"]))
```

Every command in that file (or the whole view, for a query component) now
requires the named group.

## Narrowing one command

More often, different commands in the same slice deserve different rules. Put
the annotation **before the constructor name**:

```rescript
@schema
type command =
  | @authorize(AllowGroups(["Admin", "Merchandiser"])) AddCategory({
      categoryId: string,
      name: string,
    })
  | @authorize(AllowGroups(["Admin"])) PurgeCategory({categoryId: string})
```

Anything left unannotated keeps the file-level rule, or the framework default if
there is none.

The rule is evaluated at the API resolver, before the command is published — a
refused command never reaches the queue, never reaches your `decide`, and never
appears in the log.

## Rows that belong to a caller

Authorization answers *may this caller do this*. A separate question is *whose
rows are these* — answered by [`@owner`](./reventless-ppx.md), which names the
field holding the id of the principal a record belongs to:

```rescript
@schema
type command =
  PlaceOrder({
    @noDcbTag @owner customerId: string,
    productIds: array<string>,
  })
```

On the write path the framework **overwrites** that field with the authenticated
caller's id, so a forged value and an absent one produce the same row. On a
view's state, reads narrow to the caller's own rows on every transport. The two
halves are the point: a client cannot place an order as somebody else, and
cannot read one either.

## Who is exempt

Some roles exist precisely to read across owners — a fulfilment desk works other
people's orders. That exemption is **deployment configuration**, never part of an
annotation, so two views cannot disagree about who an operator is:

```bash
REVENTLESS_ELEVATED_GROUPS=Admin,Fulfilment
```

or, in a platform root, before the plugins are built:

```rescript
Reventless.OwnerScope.setElevatedGroups(["Admin", "Fulfilment"])
```

An explicit call wins over the environment. The default is **empty** in both
directions: a deployment that configures nothing shows operators too little
rather than showing customers each other.

Note that elevation and authorization are independent. Being elevated lifts
owner scoping; it does not grant a command whose rule you fail.

## Index-scoped queries

An `@index` can carry a `group` and an `authTable`, which restricts queries
through that index to callers in the named group. Use it when a view is
generally readable but one access path — by customer, by internal reference —
should not be.

## Trying it locally

The local platform authenticates against a YAML file rather than a cloud
identity provider, so you can hold an account per role and switch between them:

```yaml
- username: admin
  password: admin
  groups: [Admin, Shopper]

- username: shopper
  password: shopper
  groups: [Shopper]
```

Sign in through the shell's login page, or send `X-User: admin` on a request. A
request with **no** `X-User` header falls back to an unprivileged `defaultUser`
so casual browsing works without logging in.

**Test the roles, not the fallback.** To check what an administrator sees, log in
as one — granting extra groups to the fallback user tests a configuration that
will never be deployed. Neither shortcut exists on AWS, where Cognito issues the
identity and group membership comes from the user pool.

See [Run and deploy](./local-development.md) for the rest of the local setup, and
[Test it on AWS](/tutorials/test-on-aws) for creating your first deployed user.
