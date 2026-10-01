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

A third case needs one more declaration: a command that acts on something that
already exists. `CancelOrder` carries only `{orderId}`, so stamping has nothing
to overwrite, and a caller who knows another shopper's order id could cancel it.
Mark the owner on the event the slice consumes:

```rescript
@schema
type consumedEvent =
  | OrderPlaced({productIds: array<string>, @owner customerId: string})
```

The framework then reads who owns the order from the order's own history and
refuses a caller who is not that owner, before `decide` runs. The refusal has the
same shape as an authorization refusal (`CommandRejected`, `errorCode:
"Forbidden"`). Exempt callers, described below, still act on anyone's order, and
so does a command the platform issues itself, such as an automation's.

A slice keyed by its owner needs none of this. When the owner field is the
slice's partition, as with a caller's own notification preferences, stamping
already confines every command to the caller's partition.

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

An explicit call wins over the environment, and either counts as an answer — a
deployment that names its operators is never overridden, including when it names
nobody.

Say nothing and the answer depends on the platform. A cloud platform defaults the
list to the administrator group it declares, so the account made by
`provision-admin` is elevated without anyone configuring it. Everywhere else the
default is **empty**, which shows operators too little rather than showing
customers each other — the direction a wrong guess should fail in.

An exempt caller is one of two kinds:

- **an operator**: a signed-in person in a group on that list, and
- **the platform itself**: its own service traffic, such as an IAM-signed call
  between components, or a command an automation issues.

Exempt callers are treated the same way by every `@owner` rule. Their commands
are not stamped, so an operator can place an order for a customer. Their reads
are not narrowed, so they see every owner's rows. And they may act on things
other people own, so an operator can cancel any customer's order.

An administrator is an operator only because the administrator group is on the
list. On a cloud platform it is there by default. Locally, or once a deployment
states its own list, it is there only if that list names it. Other roles can be
operators too: the shop example lists `Fulfilment` beside `Admin`, because
working other customers' orders is that role's ordinary job.

Note that elevation and authorization are independent. They answer two
questions:

| Question | Answered by | Example |
| --- | --- | --- |
| May this caller issue this command at all? | `@authorize` on the command | `ShipOrder` admits `Admin` and `Fulfilment` |
| May this caller see, or act on, what other people own? | the elevated-groups list | an operator cancels any customer's order |

Being elevated does not grant a command whose rule you fail, and passing a
command's rule does not let you act on someone else's thing. They are also the
two halves of "who is an administrator", and a deployment that narrows one should
narrow the other — see [The first administrator](./first-admin.md).

In a GWT scenario, `Caller.operator` stands for an exempt caller — see
[Who may act](./given-when-then.md#who-may-act-ascaller-and-thenrefused).

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
[The first administrator](./first-admin.md) for creating your first deployed user.
