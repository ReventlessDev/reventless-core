# Plan: roles a plugin declares and a platform provides

**Date:** 2026-10-01<br/>
**Status:** Proposed; the open questions were decided on 2026-10-01 (§11).
Nothing built.<br/>
**Relates to:** `a-command-acts-only-on-what-the-caller-owns.md` (the GWT
`Caller` this extends), `active-role-narrows-the-token.md` (the "active role" a
person picks), `generated-surfaces-state-required-access.md` (what
`requiredAccess` holds and who compares it), `identity-is-a-capability-not-a-cognito-handle.md`
(the deploy gate §5 joins), `model-sidecar-annotation-arguments.md` (what the
model sidecar records, for the spike), `appsync-refusal-vocabulary.md` (what a
refusal says on each transport).

**In plain words.** A command that only some people may issue says so today
with a group name written as a string, for example
`@authorize(AllowGroups(["Admin", "Merchandiser"]))`. A typo in that string is
not caught anywhere: the command is simply refused for everybody who was meant to
have it, and only on a deployed stack does anyone notice. Nothing checks that the
group a plugin asks for is one the deployment actually has, and no test in the
examples says who may issue which command.

This plan gives the framework two words with two meanings. A **role** is a job
someone does (Merchandiser, Fulfilment, Admin). A plugin declares the roles its
commands need, as a type, so a misspelled role does not compile. A **group** is
how an identity provider records that a person has a role: the `groups` in a
login token, the groups of a user pool, the `groups` of an account in
`users.yaml`. The platform says which group stands for which role, and a check
at deploy and at start refuses a plugin that needs a role the platform cannot
provide. Scenarios in the examples then say, next to each command's behaviour,
which roles may issue it and which are refused.

---

## §1 — What is there today

- **The rule.** `Authorization.permission` in `reventless-spec` has four cases:
  `AllowGroups(array<string>)`, `AllowAuthenticated`, `AllowAnonymous`,
  `DenyAll`. `Authorization.isAllowed(rule, identity)` decides it against
  `Identity.groups`.
- **The annotation.** `@authorize(<rule>)` on a command constructor and
  `@@reventless.authorize(<rule>)` on a file. The PPX
  (`AuthorizationInjection.ml`) copies the rule *as an expression* into a
  generated `commandAuthorization` (commands) or `authorization` (views). It
  does not require a string literal.
- **Enforcement, per transport.** The local GraphQL resolver evaluates
  `isAllowed` and answers a refused command with `CommandRejected`,
  `errorCode: "Forbidden"`. On AWS the rule becomes Cognito group directives on
  the AppSync schema, and AppSync refuses the call itself, with a GraphQL error.
  The decision is the same; the wire shape is not (see
  `appsync-refusal-vocabulary.md`).
- **Published.** Each command and view publishes the group names it requires as
  `requiredAccess: option<array<string>>` in the plugin structure. The name is
  already neutral and can stay.
- **Groups come from the deployment.** On AWS the platform stack declares the
  administrator group; every other group exists because an accounts manifest
  (`users.yaml`) names it and a provisioning run creates it
  (`ProvisionCognito.ensureGroup`). Nothing compares those names with what the
  plugins require.
- **Elevation.** `OwnerScope.elevatedGroups` (from `setElevatedGroups` or
  `REVENTLESS_ELEVATED_GROUPS`) lists the groups exempt from `@owner` rules.
  `AdminGroup.name` exists only to keep the administrator's name the same in
  both places, and its own comment records that annotations cannot use it
  because they take a literal. As shown above, they can take an expression.
- **Usage.** The hybrid example names `Merchandiser` in dozens of
  `AllowGroups([...])` annotations across the catalog, `Fulfilment` on
  `ShipOrder`, and `Admin` throughout. The aggregates and DCB examples each have
  one file with three `Admin`-only rules.
- **Tests.** The framework tests the mechanism:
  `reventless/local/tests/adapter/CommandAuthorizationTest.res` (the local
  resolver), `reventless/aws/tests/AppSync_AdapterTest.res` (directives),
  `reventless/core/tests/plugin/PluginStructureAccessTest.res` (published
  access). No example tests its own rules.
- **Vocabulary.** The provider-agnostic layer says "group" (74 uses in
  `reventless-spec`, against 5 of "role"). "Role" already means the *active
  role* a person picks, a plugin's "business role" in the admin view, and, in
  `reventless-aws`, AWS IAM roles (over 200 uses). Docs drift to "role" whenever
  they describe what a person does.

## §2 — The two words

| Word | Means | Belongs to | Examples |
| --- | --- | --- | --- |
| **role** | a job someone does, which a command or view requires | the plugin (domain) | `Merchandiser`, `Fulfilment`, `Admin` |
| **group** | how an identity provider records that a person has a role | the deployment | `Identity.groups`, a user pool's groups, `users.yaml` |

- Annotations, plugins, the elevated list and GWT scenarios speak of **roles**.
- `Identity`, tokens, identity providers and account manifests keep **groups**.
- The platform maps roles to groups. By default a role maps to the group of the
  same name, so a deployment that names its groups after its roles configures
  nothing.
- Where "role" means an AWS IAM role, the code says so (`iamRole`, execution
  role), so the two never share a bare name.
- The *active role* keeps its name and its mechanism: it is stored, and the
  token narrowed to it, as **the group that stands for the role** a person is
  acting in. Nothing in that mechanism learns what a role is.
- **Journeys** (`done/curated-manifest-per-journey.md`) are keyed by group, and
  stay so: they are deployment configuration, compared with token groups.
- **A role here is the coarse gate** on who may issue a command or read a view.
  A later permissions or accounts layer may add permission sets, nested groups or
  per-tenant roles *on top of* it; this plan neither builds nor forecloses that,
  which is why §10 lists those as out of scope rather than rejected.

## §3 — A plugin declares its roles

Each plugin that restricts anything declares the roles it uses in a file named
`Roles.res` in its `src/`, holding a plain variant:

```rescript
// src/Roles.res
type t =
  | Admin
  | Merchandiser
```

and its annotations name those cases:

```rescript
| @authorize(AllowRoles([Merchandiser, Admin])) AddProduct({...})
```

A misspelled case fails to compile as "constructor not found in `Roles.t`".

**How it works (decided, to be confirmed by the spike in step 1).**

- **Found by convention, no marker.** The PPX and the plugin generator recognise
  the plugin's `Roles.res` by name and shape, as the generator already finds a
  plugin's identities (`<Name>Id.res` calling `Id.Make`).
- **Strings at runtime, by coercion.** A variant whose cases carry no payload is
  a string at runtime, and ReScript coerces such a variant to `string` safely
  with `:>`. The PPX already copies the rule as an expression; for `AllowRoles`
  it wraps each element as `((Merchandiser : Roles.t) :> string)`. No unchecked
  cast is involved.
- **The rule's type** is `AllowRoles(array<Role.name>)`, where `Role.name` is a
  string naming a role *before* mapping. Enforcement maps it to a group (§4).
- **Fallback**, if the spike shows the coercion cannot be generated cleanly:
  role values made once per plugin, `let merchandiser = Role.make("Merchandiser")`,
  with the annotation reading `AllowRoles([Roles.merchandiser])`.

**Roles are joined by name.** Two plugins that each declare `Fulfilment` mean the
same role, and §5 compares names, so each plugin declares only the roles it uses
and no shared package is needed. A shared spec package is for roles that become
part of a contract between plugins, and none do yet (§11, decision 4).

**The administrator.** The framework's own administrator role is `Role.admin`
(named `Admin`), replacing `AdminGroup.name`. A plugin that lists `Admin` in its
`Roles.res` means the same role, by the same rule.

## §4 — A platform provides groups for those roles

The platform root states:

- **which group stands for which role**, only where they differ:
  `Platform.roleGroups([(Merchandiser, "shop-merch-team")])`. Everything else
  maps to the group of the same name.
- **which roles are elevated**: `OwnerScope.setElevatedRoles([Admin, Fulfilment])`,
  resolved through the mapping. `setElevatedGroups` **stays supported** beside it,
  as the group-level form of the same setting, for a platform root that already
  states groups or that consumes a published list of group names; it is not
  deprecated. Where both are given, the explicit settings are joined.

**Roles are resolved to groups once, where the mapping is known, and everything
downstream keeps receiving groups.** That matters most for elevation. A
deployment is two kinds of process: the deploy program (or the local platform
root) knows the mapping, while the function runtimes that stamp commands and
serve SQL-backed reads never see it. The only carrier both share is the
environment, and a deployed stack has already failed once because the deploy and
the runtimes disagreed about who was elevated. So:

- the platform resolves the elevated roles to groups and keeps handing runtimes
  `REVENTLESS_ELEVATED_GROUPS` with **those resolved groups**, exactly as
  `Util_OwnerScopeEnv` does today;
- there is **no second environment variable**: `REVENTLESS_ELEVATED_GROUPS` stays
  the one carrier, read as group names, and the deploy workflow's
  `elevated-groups` input keeps feeding it. Roles enter only in code, through
  `setElevatedRoles`. Two variables for one fact would be two places to
  disagree, which is the failure above;
- the resolution order stays as it is: an explicit setting, then the
  environment, then empty;
- a client that mirrors the elevated list in its configuration keeps receiving
  the same resolved group names, from the same resolution, so the browser and
  the server cannot disagree.

Enforcement uses the mapped group names: the local resolver passes them to
`isAllowed`, and the AWS platform writes them into the AppSync directives. A
plugin therefore never learns what a deployment calls its groups, and must never
hold a group name itself: a plugin that creates accounts (`createPrincipal(~groups)`
in `identity-is-a-capability-not-a-cognito-handle.md`) asks the platform for the
group that stands for a role.

## §5 — A check that the platform can provide every role

At deploy (preview included) and at start, for every component of every plugin:

- every role its rules name, read from the rules *before* mapping, must map to
  a group the platform provides;
- every elevated role must, too.

"Provides" means the administrator group the platform declares, plus the groups
of the accounts manifest, plus the groups named in the role mapping. A missing
one fails with the plugin, the component, the command or view, and the role
named. It runs in the deploy gate that already checks a trait's
`capabilityNeeds`, and that `identity-is-a-capability-not-a-cognito-handle.md`
extends to identity capabilities, rather than as a gate of its own.

**A supplied user pool.** A deployment on a pool it did not create may have
groups that no manifest names. Its platform root declares them,
`~providedGroups=["shop-merch-team"]`, and they count as provided. The check
still fails by default: a warning would bring back the silent "refused for
everyone" this plan exists to remove. A plain declared list also works in a
preview, locally and in tests, where no call to the provider is possible; a
check that runs only when the deploy has applied resources is skipped by a
preview. Comparing the declared list with the pool's real groups can come later
as an extra check (§11).

## §6 — `AllowGroups` becomes `AllowRoles`

- `Authorization.permission` gains `AllowRoles(array<Role.name>)`.
- `requiredAccess` keeps its name and shape (strings), and holds the **mapped
  group names**, not role names. Its consumers compare it with the groups in the
  caller's token (`generated-surfaces-state-required-access.md`), alongside other
  access keys in the same namespace; a role name no token carries would gate a
  surface shut. With the default mapping the values do not change at all.
- The plugin structure gains no required field (a required field added to it has
  wedged plugin registration before), so clients that read it are unaffected.
- **`AllowGroups` and `AdminGroup` stay, deprecated,** until the examples, the docs
  and the authoring tools that write `@authorize` have moved. Until then
  `AllowGroups` keeps working, the PPX warns on every use naming `AllowRoles`,
  and the §5 check treats its strings as roles. They are then removed in a `feat!`
  commit **before the framework graduates from alpha**, so the first stable
  release has only `AllowRoles`. (On `alpha` a breaking commit bumps only the
  prerelease counter; the major moves at graduation, so removing earlier costs
  external users nothing extra.)
- `REVENTLESS_ELEVATED_GROUPS` is **not** deprecated: it is the permanent runtime
  carrier (§4).
- `AdminGroup` is replaced by `Role.admin`, resolved through the mapping like any
  role, at every site that hard-codes the administrator today: the admin API's
  group decoration on both platforms (`AppSync_Adapter.injectAwsAuthAll` on AWS,
  the `Platform_*` field wrapper locally), the default elevated list, and the six
  `AdminGroup.name` uses. Clients that key on the administrator group receive the
  mapped name. The module stays as a deprecated alias for the transition period.
- **A platform root can ask for any role's resolved group.** Code outside the
  framework that grants access by group, such as a platform root deploying extra
  admin-only components, must not write `"Admin"` either. The platform exposes
  the resolution it uses itself: `Platform.groupOf(role)`, with
  `Platform.adminGroup()` for `Role.admin`. These are the same names it writes into
  the AppSync directives, the shell configuration and `REVENTLESS_ELEVATED_GROUPS`,
  so a root that uses them cannot disagree with the platform.
- Docs: `authorization.md` describes roles and groups as in §2;
  `reventless-ppx.md` documents `AllowRoles` and the `Roles` module.

## §7 — GWT scenarios state the caller's roles

`Caller`, from the ownership plan, becomes a small identity instead of only an
ownership claim:

- `Caller.owner(id)` — a person who owns what records `id`, holding no
  restricted role;
- `Caller.inRoles([Merchandiser])` — a person holding those roles;
- `Caller.owner(id, ~roles=[...])` — both;
- `Caller.operator` — exempt from ownership rules, as today;
- `Caller.anonymous` — no identity.

`whenCmd` then checks, in the order production does:

1. the command's `commandAuthorization` against the caller's roles;
2. the ownership rule.

`thenRefused` passes for either refusal, since both are `Forbidden` to a
client; the scenario's title says which rule refused. A scenario without
`asCaller` is checked against neither, so every existing scenario is unchanged.

Who counts as an operator stays a property of `Caller.operator` rather than being
derived from roles through the elevated list. That keeps a scenario independent
of what a platform root configures; the elevated list is a deployment fact and is
tested where deployments are.

Views with `@@reventless.authorize` can follow in the query DSL later; this plan
covers commands.

## §8 — Role-based scenarios in the examples

Every command in the examples whose rule is not the default gets scenarios in its
`_GWT.res`, beside its behaviour:

- **one accepted scenario per role the rule names** (for `AllowRoles([Admin,
  Merchandiser])`: one as `Admin`, one as `Merchandiser`);
- **one refused scenario for a caller who holds none of them** — a shopper
  (`Caller.owner(c1)`), and `Caller.anonymous` where the rule is not
  `AllowAnonymous`;
- **`DenyAll`**: refused for every caller, `Admin` included;
- **`AllowAnonymous`**: accepted for `Caller.anonymous`.

Scope, from §1:

- **hybrid catalog**: the `Admin` / `Merchandiser` commands (adding, renaming,
  archiving and unarchiving products and categories, their images);
- **hybrid ordering**: `ShipOrder` (`Admin`, `Fulfilment`), the `DenyAll` and
  `AllowAnonymous` commands, and `CancelOrder`'s existing ownership scenarios
  restated with roles where that reads better;
- **aggregates and DCB examples**: the commands behind their `Admin`-only rules.

The lifecycle check already leaves refused scenarios out, and the accepted ones
add evidence it can use. `pnpm run check:lifecycle:update` refreshes the model
files in the commit that adds them.

Published values that hold group names keep holding them. In particular the
example seed package keeps exporting `Storefront.elevatedGroups` (group names)
when step 6 adds a role-typed list beside it, because other platform roots pass
that export to `setElevatedGroups`.

## §9 — Order of work

1. **Spike.** Decide §3's surface, answering separately:
   - what compiles in an annotation, and what the PPX copies into
     `commandAuthorization`;
   - the model sidecar: it records no constructor attributes today
     (`model-sidecar-annotation-arguments.md`), so a command's rule is not in it
     at all, and where it does record arguments it records them as source text,
     so `AllowRoles([Merchandiser])` would arrive unresolved;
   - the GWT sidecar: it records only `thenRefused` as `forbidden`, which does
     not depend on the rule's syntax;
   - tools that read and write `@authorize` as text: a bare `Merchandiser`
     survives a text round trip, but resolving it to a name needs the plugin's
     `Roles` module;
   - that the `Roles.res` convention and the generated coercion (§3) compile,
     and give a readable error for a misspelled role.
   Record the answers here before step 2.
2. **Spec and PPX.** `Role.name`, `AllowRoles`, the coercion, the deprecation of
   `AllowGroups`, `Role.admin`. Unit tests for `isAllowed` with roles mapped to
   groups.
3. **Platforms.** The role mapping, `setElevatedRoles` resolved into
   `REVENTLESS_ELEVATED_GROUPS`, `providedGroups`, on both platforms; the AppSync
   directives written from mapped groups. The local resolver test and the directive test extended with a
   mapping that renames a group.
4. **The check (§5).** At deploy and at start, with a test per failure it names.
5. **GWT (§7).** `Caller` with roles; authorization before ownership; tests in
   `reventless/gwt/tests`.
6. **Examples.** Migrate annotations to `AllowRoles` with a `Roles` module per
   plugin; add the §8 scenarios; refresh lifecycle models.
7. **Docs** as in §6, and the terminology of §2 applied to existing comments
   where "role" and "group" are mixed.

Steps 2 to 7 can ship in one commit or in several; step 6 should not land before
step 5.

## §10 — What this does not do

These are out of scope here, not rejected; a later permissions layer may add
them on top of the roles this plan introduces (§2).

- **No permissions model.** A role grants what the annotations say it grants;
  there is no separate list of permissions per role.
- **No role hierarchy or nested groups.** `Admin` is not implicitly a
  `Merchandiser`; a rule that should admit both names both, as today.
- **No per-tenant roles** (§11, item 6).
- **No change to how a provider issues groups**, to the active-role mechanism, or
  to AWS IAM roles.
- **No change to what a refusal looks like on the wire**; that stays with
  `appsync-refusal-vocabulary.md`.

## §11 — Decisions and what is still open

1. **The annotation syntax** is `@authorize(AllowRoles([Merchandiser]))`, with
   the plugin's roles in a `Roles.res` found by convention and the PPX generating
   a safe coercion to strings (§3). *Open:* the spike in step 1 confirms it; the
   fallback is role values made once per plugin.
2. **Supplied user pools** declare their groups with `providedGroups`, and the
   check fails by default (§5). *Open:* whether to add, later, a deploy-time
   comparison of the declared list with the pool's real groups.
3. **Old names.** `AllowGroups` and `AdminGroup` are deprecated and removed in a
   `feat!` before the framework graduates from alpha (§6).
   `REVENTLESS_ELEVATED_GROUPS` stays as the only environment variable; there is
   no `REVENTLESS_ELEVATED_ROLES` (§4).
4. **Shared roles.** Each example plugin declares its own roles; they are joined
   by name, and the hybrid example's roles do not overlap anyway (`Merchandiser`
   in catalog, `Fulfilment` in ordering, `Admin` from the framework). A shared
   package is introduced only when a role becomes part of a contract between
   plugins, and the docs say so.
5. **Authoring tools** that write `@authorize` keep *reading* `AllowGroups`
   indefinitely, because existing code contains it, and switch to *writing*
   `AllowRoles` with a `Roles.res` once the released framework supports it,
   gated on that version. They stop writing `AllowGroups` before its removal
   (decision 3). This repository's own generator does not write `@authorize`.
6. **Per-tenant roles** are out of this plan. A tenant-scoped role ("administrator
   of organisation X") is not a fixed group and cannot be a gate at the API
   layer. Its place already exists: `registerCommandInterceptor` in
   `CommandGenerator_Callback` runs with the caller's identity before a command
   is published, which is where a later permissions layer can decide it, on top
   of the coarse role check. Nothing in this plan's mapping assumes roles are
   global beyond that gate.
