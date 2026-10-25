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
InboundTranslationSlice) gets an `authorizationOf` binding, and every
query-carrying one (ReadModel, StateViewSlice) gets an `authorization` binding,
injected for you with the rule `AllowAuthenticated`. So a spec that says nothing
about authorization is already closed to anonymous callers — you narrow from
there rather than remembering to lock something down.

The four rules:

| Rule | Allows |
|---|---|
| `AllowAuthenticated` | Any caller who signed in. The default. |
| `AllowRoles([Admin, Merchandiser])` | Callers holding at least one of the named roles. |
| `AllowAnonymous` | Everybody, signed in or not. Use deliberately. |
| `DenyAll` | Nobody. For a command only another component may issue. |

### A door open to everybody is limited

A command or inbound mutation whose rule is `AllowAnonymous` is counted per source
address, whoever the caller turns out to be: the limit is on the door, because the
door is what a script aims at. Past the limit the answer is `CommandRejected` with
`errorCode: "Throttled"` and cause `INFRASTRUCTURE`, and the count starts again in
the next window.

The limit is deployment configuration, `requests/seconds`, ten an hour by default:

```bash
REVENTLESS_ANONYMOUS_REQUEST_LIMIT=10/3600
```

A value that does not parse fails the request rather than falling back to the
default. The local platform enforces it on its GraphQL doors; a deployed platform
admits no anonymous field yet, and the door it will have reads the same setting.

How often an *address* may be written to is a different limit and belongs to the
domain: count it in a `decide`, where it is recorded and survives a replay.

## Roles and groups

Two words, with two meanings:

- A **role** is a job someone does, such as `Merchandiser`, `Fulfilment` or
  `Admin`. Rules name roles. A role belongs to the plugin.
- A **group** is how an identity provider records that a person has a role: the
  `groups` in a sign-in token, the groups of a user pool, the `groups` of an
  account in `users.yaml`. Groups belong to the deployment.

A plugin declares the roles its rules use, as a variant in `src/Roles.res`:

```rescript
// src/Roles.res
type t =
  | Admin
  | Merchandiser
```

Rules then name its cases. A misspelled role does not compile:

```text
The constructor Merchandisr does not belong to type Roles.t
Hint: Did you mean Merchandiser?
```

`Admin` is the framework's own administrator role. A plugin that lists it means
the same role, because roles are joined by name: two plugins that each declare
`Fulfilment` mean one role, and neither needs a shared package for it.

By default each role is the group of the same name, so a deployment that names
its groups after its roles configures nothing. Where they differ, the platform
root says so, before the platform is built:

```rescript
ReventlessAws.Platform.roleGroups([
  (Reventless.Role.make((CatalogPlugin.Roles.Merchandiser :> string)), "shop-merch-team"),
])
module Platform = ReventlessAws.Platform.Make()
```

The resolver, the AppSync directives, the published `requiredAccess` and the
elevated list all use the group a role maps to. `Platform.groupOf(role)` and
`Platform.adminGroup()` give a platform root the same answer, for anything it
grants by group itself. A mapping stated after the platform is built is refused,
because part of the deployment would already be using the old one.

### Every role must have a group

When a plugin is built, at deploy (preview included) and at local start, the
platform checks that every role its rules name, and every elevated role, maps to
a group it provides. Otherwise the rule would refuse everybody it was written
for, and only a deployed stack would show it.

**On AWS, the user pool is asked.** A plugin's deploy program lists the pool's
groups before it builds the plugin (`Platform.loadProvidedGroups()`, which the
generated `Main.res` calls), and those groups are the whole answer. A role mapped
to a group the pool does not have is missing like any other: naming a group does
not create it. A group declared with `Platform.providedGroups` that the pool does
not have fails the deploy too. The deploying principal needs
`cognito-idp:ListGroups` on the pool. A pool the platform stack created has only
the administrator group until `provision-accounts` creates the manifest's groups,
so on a fresh stack, provision before deploying a plugin that needs another role.

Where there is no pool to ask (a program that creates its pool in the same run,
or a root that does not call `loadProvidedGroups`), the groups provided are:

- the administrator group,
- the groups of the accounts manifest (`.reventless/users.yaml`, or the
  `users.example.yaml` it is made from), read from the directory the deploy runs in,
- the groups the role mapping names,
- the groups a platform root declares with `Platform.providedGroups([...])`, for an
  identity provider that cannot be listed.

**Locally,** the groups provided are those of the accounts the platform can sign
in as: the built-in ones, plus the accounts manifest (or its template) that the
servers load at start. A root that loads other accounts with `UserStore.load(~users)`
or `UserStore.load(~usersFile)` must do it before deploying plugins. Then those
accounts count, and the working directory's manifest does not. Loading them after
a plugin has been built is refused, since the check would have compared the plugin
with other accounts.

A missing group fails with the plugin, the command or view, the role, and what to
do about it.

### How a person comes to hold a role

A plugin may say, per role, how an account gets into it, in `src/Admission.res`
beside `Roles.res`:

```rescript
let table = Reventless.Admission.declare([
  (Roles.Shopper, SelfService),
  (Merchandiser, Invitation({by: [Admin]})),
  (Admin, Provisioned),
])
```

`SelfService` means a visitor who is not signed in proves control of an address
and chooses a password; `Provisioned` means an administrator makes the account by
hand, from the accounts manifest locally and with `provision-accounts` on AWS; a
role the table does not name is provisioned. `Invitation` declares that someone
already inside invites; the framework ships no door for it, so a plugin that
provides one marks it. The declaration is the hard cap: no runtime state opens a
role it does not declare self-service. Whether a self-service role is open *right
now* is domain state an administrator changes with a command, and such a role is
open until one closes it.

The doors a plugin provides say which part of admission they are, on the spec of
an inbound translation: `let admissionDoor = Reventless.Admission.Start` (or
`Complete`, or `Invite`). The platform writes them into the host shell's
`config.json` as `selfRegistration: {start, complete, roles}`, `roles` being the
groups a visitor may sign up for, so nobody names a mutation by hand.

At start the platform refuses a declaration it cannot honor, naming the role: a
self-service role whose group is the administrator's or an elevated one; one with
no door that starts and completes a registration; one on a platform that admits no
callers who are not signed in (a deployed platform, today); a self-service or
invited role without messaging and an identity provider provisioned; and a role by
invitation when nothing in the deployment provides an invite door. The hybrid
online shop declares shoppers self-service and its staff provisioned.

## Narrowing a whole file

Put the rule at the top of the spec file:

```rescript
@@reventless.spec
@@reventless.authorize(AllowRoles([Admin]))
```

Every command in that file (or the whole view, for a query component) now
requires the named role. For a view that means every query it has: the list, one
row by id, rows by ids, the reference door (`…Refs`) and each `@index` door.

## Narrowing one command

More often, different commands in the same slice deserve different rules. Put
the annotation **before the constructor name**:

```rescript
@schema
type command =
  | @authorize(AllowRoles([Admin, Merchandiser])) AddCategory({
      categoryId: string,
      name: string,
    })
  | @authorize(AllowRoles([Admin])) PurgeCategory({categoryId: string})
```

Anything left unannotated keeps the file-level rule, or the framework default if
there is none.

The rule is evaluated at the API resolver, before the command is published — a
refused command never reaches the queue, never reaches your `decide`, and never
appears in the log.

### Inbound translations

An InboundTranslationSlice has one mutation for all its commands, and the API
cannot know which commands an input will turn into until `translate` has run. So
it checks twice:

1. **At the mutation**, the caller must satisfy at least one command's rule.
2. **After `translate`**, each command the input produced is checked against its
   own rule. If any one is refused, none is sent: the mutation answers
   `CommandRejected` with `errorCode: "Forbidden"`, and the slice's audit log
   records the failure.

Where every command shares one rule, the second check never refuses anything the
first let through.

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
annotation, so two views cannot disagree about who an operator is. A platform
root states it as roles, before the plugins are built:

```rescript
Reventless.OwnerScope.setElevatedRoles(OnlineShopHybridSeed.Storefront.elevatedRoles)
```

or as groups, with `setElevatedGroups`, or in the environment:

```bash
REVENTLESS_ELEVATED_GROUPS=Admin,Fulfilment
```

Roles are resolved to their groups, and the environment variable always carries
groups, so the processes that never see the role mapping read the same list. An
explicit call wins over the environment (roles and groups stated together are
joined), and either counts as an answer — a deployment that names its operators
is never overridden, including when it names nobody.

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
[Who may act](./given-when-then.md#who-may-act-ascaller-and-thenforbidden).

## The framework's own stores

Some components keep a store beside the ones your plugin declares, so an operator
can see what the component is doing:

| Store | Kept by | Holds |
| --- | --- | --- |
| `<Slice>Todo` | an automation, an outbound translation | the work it has still to do |
| `<Slice>Schedule` | an automation that runs on a time | when it runs next, for each key |
| `<Slice>Audit` | an inbound translation | what it received, and what came of it |

Each one has a list query, such as `Ordering_NotificationIntakeTodos`. These rows
name your customers, your orders and the times your customers are written to, so
**only operators may read them**: the callers on the elevated list described
above. Everyone else is refused: an error on AWS, an empty answer locally.

The rule follows the list, so it needs no annotation. Two consequences:

- **A deployment that names no operators lets nobody read these stores.** Locally
  that is the default, so state the list in the platform root to see them there.
- **An elevated group must be one a role can name.** If a deployment maps the role
  `Admin` to the group `ops` and also lists `Admin` as an elevated group, no role
  stands for the group `Admin`. The platform refuses to deploy or start rather than guess.

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
