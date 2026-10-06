# Plan: roles a plugin declares and a platform provides

**Date:** 2026-10-01<br/>
**Status:** Done (2026-10-01). Built as described below; where the build departed
from the first draft, the section says how and why. The casts on the
authorization path that remain are planned away in
`../authorization-looked-up-by-command-name.md`.<br/>
**Relates to:** `a-command-acts-only-on-what-the-caller-owns.md` (the GWT
`Caller` this extends), `active-role-narrows-the-token.md` (the "active role" a
person picks), `generated-surfaces-state-required-access.md` (what
`requiredAccess` holds and who compares it), `identity-is-a-capability-not-a-cognito-handle.md`
(the deploy gate [§5](#5--a-check-that-the-platform-can-provide-every-role) joins), `model-sidecar-annotation-arguments.md` (what the
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
  which is why [§10](#10--what-this-does-not-do) lists those as out of scope rather than rejected.

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

**How it works (as built).**

- **The rule keeps the plugin's type.** The framework's rule is parameterised,
  `Authorization.rule<'role>`, and every spec module type declares `type role`.
  A spec's binding is `command => rule<role>` (or `rule<role>` for a view), so
  hovering over a rule shows `rule<Roles.t>` and each role is a `Roles.t` case.
  The first draft converted each case to a string inside the spec; that made the
  editor show `string` for what is a variant, and was dropped.
- **The PPX supplies `role`.** It copies the rule unchanged and annotates the
  generated binding `Reventless.Authorization.rule<role>`, so the bare cases
  resolve against `Roles.t` by their expected type. Beside it, it declares
  `type role`: the spec's own, if it has one; `Roles.t` when it writes the
  binding and the spec, its file or the package's `src/Roles.res` declares the
  roles; `Reventless.Role.name` otherwise — no roles to name, or a rule written by
  hand over the framework's `permission`.
- **Names where the framework takes over.** `permission = rule<Role.name>` is the
  form the framework compares, maps and publishes. `Authorization.named` turns a
  spec's rule into it at each place the framework reads one. A payload-less case
  is its name at run time, so `named` is an identity with a check, in a companion
  `.mjs`: a role that is not such a case is refused there.
- **`Role.name` is a private string.** A bare string is not a role. Code with no
  plugin variant to hand — a platform root, a framework test — says so with
  `Role.make("…")`.

**Roles are joined by name.** Two plugins that each declare `Fulfilment` mean the
same role, and [§5](#5--a-check-that-the-platform-can-provide-every-role) compares names, so each plugin declares only the roles it uses
and no shared package is needed. A shared spec package is for roles that become
part of a contract between plugins, and none do yet ([§11](#11--decisions-and-what-is-still-open), decision 4).

**The administrator.** The framework's own administrator role is `Role.admin`
(named `Admin`), replacing `AdminGroup.name`. A plugin that lists `Admin` in its
`Roles.res` means the same role, by the same rule. The core declares it in its own
`src/Roles.res`, for the platform's `Plugins` view.

## §4 — A platform provides groups for those roles

The platform root states:

- **which group stands for which role**, only where they differ:
  `ReventlessAws.Platform.roleGroups([(role, "shop-merch-team")])` (and the same
  on `ReventlessLocal.Platform`). Everything else maps to the group of the same
  name. These are functions of the platform package, called **before
  `Platform.Make()`**: the AWS platform writes the admin API's directive while it
  is built, and a mapping stated afterwards is refused rather than applied to
  half the deployment. A root holds roles from several plugins, so it names them
  as `Role.name`s: `Role.make((CatalogPlugin.Roles.Merchandiser :> string))`.
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
named.

As built, it runs in `Plugin_Builder.make` rather than in the `capabilityNeeds`
gate. That gate sits inside an `Output.apply` and only on a plugin stack, so a
preview skips it; `Plugin_Builder.make` receives the plugin structure
synchronously on both platforms. The roles travel on the structure as an optional
`requiredRoles` beside `requiredAccess` (kept off the admin API's wire). Locally,
"provides" also counts the built-in accounts, and the manifest is read directly
— the user store loads only when the servers start, after the check. A manifest
that does not exist yet counts as its `users.example.yaml`, the cast a fresh
clone provisions.

**A supplied user pool.** A deployment on a pool it did not create may have
groups that no manifest names. Its platform root declares them,
`Platform.providedGroups(["shop-merch-team"])`, and they count as provided. The check
still fails by default: a warning would bring back the silent "refused for
everyone" this plan exists to remove. A plain declared list also works in a
preview, locally and in tests, where no call to the provider is possible; a
check that runs only when the deploy has applied resources is skipped by a
preview. Comparing the declared list with the pool's real groups can come later
as an extra check ([§11](#11--decisions-and-what-is-still-open)).

## §6 — `AllowGroups` becomes `AllowRoles`

- `AllowGroups` is gone, and so is `AdminGroup`. The first draft kept both
  deprecated until graduation; as alpha may break and every use in this
  repository moved in the same change, keeping a second spelling of a rule bought
  nothing.
- `requiredAccess` keeps its name and shape (strings), and holds the **mapped
  group names**, not role names. Its consumers compare it with the groups in the
  caller's token (`generated-surfaces-state-required-access.md`), alongside other
  access keys in the same namespace; a role name no token carries would gate a
  surface shut. With the default mapping the values do not change at all.
- The plugin structure gains no required field (a required field added to it has
  wedged plugin registration before): `requiredRoles` is optional, and the
  required-scalars tripwire lists its elements beside `requiredAccess`'s.
- `REVENTLESS_ELEVATED_GROUPS` stays the runtime carrier of the elevated list
  ([§4](#4--a-platform-provides-groups-for-those-roles)).
- `Role.admin`, resolved through the mapping like any role, replaces the
  administrator's name at every site that hard-coded it: the admin API's group
  decoration on both platforms, the local built-in `admin` account, the Cognito
  group the stack declares, `provision-admin`, the default elevated list (now
  `defaultElevatedRoles([Role.admin])`), and the admin `Plugins` view's
  published access keys. Values that a module evaluated at load time became
  functions, because a module loads before the platform root has mapped
  anything.
- **A platform root can ask for any role's resolved group.** Code outside the
  framework that grants access by group must not write `"Admin"` either. The
  platform package exposes the resolution it uses itself: `Platform.groupOf(role)`
  and `Platform.adminGroup()`. The host shell gets the same answer as the
  computed `config.json` key `adminGroup`, written on both platforms where the
  administrator role is mapped away from `Admin` (the shell reads an absent key
  as `Admin`).
- Docs: `authorization.md` describes roles, groups, the mapping and the check;
  `reventless-ppx.md` documents `@authorize`, `Roles.res` and the injected
  `type role`; `given-when-then.md` the callers with roles.

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

`Caller.operator` holds no role: elevation does not grant a command whose rule
the caller fails, so an operator scenario on a restricted command is refused.
`Caller.inRoles` is a signed-in person who owns nothing the given events record.
The rule is checked against the scenario's roles, never through the role mapping.

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

Scope, from [§1](#1--what-is-there-today):

- **hybrid catalog**: the `Admin` / `Merchandiser` commands (adding, renaming,
  archiving and unarchiving products and categories, their images);
- **hybrid ordering**: `ShipOrder` (`Admin`, `Fulfilment`), the `DenyAll` and
  `AllowAnonymous` commands, and `CancelOrder`'s existing ownership scenarios
  restated with roles where that reads better;
- **aggregates and DCB examples**: the commands behind their `Admin`-only rules.

As built: none of the examples declares a `DenyAll` or `AllowAnonymous`
command, so those two cases are covered by the GWT package's own tests instead.
The shopper is a named example value (`shopper` in each catalog's examples,
`c1` in ordering), and no example declares a `Shopper` role: no rule requires
one, and a case only tests would use reads as evidence that a rule does.
`UnarchiveCategory` had no scenarios at all and got its behaviour scenarios too.

The lifecycle check already leaves refused scenarios out, and the accepted ones
add evidence it can use. `pnpm run check:lifecycle:update` refreshes the model
files in the commit that adds them.

Published values that hold group names keep holding them. In particular the
example seed package keeps exporting `Storefront.elevatedGroups` (group names)
beside the role-typed `Storefront.elevatedRoles`, because other platform roots
pass that export to `setElevatedGroups`.

## §9 — Order of work

1. **Spike.** Decide [§3](#3--a-plugin-declares-its-roles)'s surface, answering separately:
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
   - that the `Roles.res` convention and the generated coercion ([§3](#3--a-plugin-declares-its-roles)) compile,
     and give a readable error for a misspelled role.
   Record the answers here before step 2.

   **Answers (2026-10-01).** [§3](#3--a-plugin-declares-its-roles)'s surface holds; the fallback is not needed. The
   first answer was later revised (see [§3](#3--a-plugin-declares-its-roles)): the rule is no longer converted.
   - *The annotation and the copy.* `AllowRoles([Merchandiser, Admin])` is
     copied unchanged; the generated binding is annotated
     `Reventless.Authorization.rule<role>`, with `type role = Roles.t` beside
     it. The cases resolve against `Roles.t` by their expected type, which the
     compiler allows without `Roles` being opened.
   - *The generated reference survives dependency analysis.* `Roles` appears
     only in the PPX's output, never in the source. That is safe, because
     rewatch reads a file's dependencies from the post-PPX AST. The GWT
     companion-fixtures open (`open WithFixtures_Fixtures`, and the spec module
     itself) has relied on this since it shipped. The comment on the injected
     `commandTransition` claims the opposite. The example plugins, built from a
     wiped `lib/` with the generated `Roles.t` references, are the evidence
     against it.
   - *A misspelled role* fails with "The constructor Merchandisr does not
     belong to type Roles.t … Hint: Did you mean Merchandiser?", at the
     misspelled constructor.
   - *Where `Roles` comes from.* The PPX checks for the package's `src/Roles.res`
     on disk (as it finds a GWT file's `_Fixtures` companion), or a
     `module Roles` in the file or inline spec, and otherwise types the spec's
     roles as `Role.name`; a spec can always state `type role` itself.
   - *The model sidecar* records no constructor attributes, so no rule reaches it
     in either form; nothing changes there. *The GWT sidecar* records
     `thenRefused` as `forbidden`, independent of the rule. Neither needs work.
   - *Text tools.* The VS Code authoring round trip in the tools repository reads
     and writes the annotation as text, and a bare `Merchandiser` survives that.
     Offering a role picker needs the plugin's `Roles.res`, which that tool
     reads off disk like any source file ([§11](#11--decisions-and-what-is-still-open), decision 5).
   - *One carrier the plan did not list.* A table-backed view read on AWS through
     the Postgres resolver Lambda evaluates `isAllowed` at run time, so that
     runtime needs the role mapping too. It gets it through the environment,
     like the elevated groups: `REVENTLESS_ROLE_GROUPS` carries only the renamed
     roles (`Merchandiser=shop-merch-team`) and is written by the same function
     that writes `REVENTLESS_ELEVATED_GROUPS`. That is a different fact from
     elevation, so [§4](#4--a-platform-provides-groups-for-those-roles)'s "one variable for one fact" still holds.
   - *Where [§5](#5--a-check-that-the-platform-can-provide-every-role) runs.* `Plugin_Builder.make` receives the plugin structure
     synchronously on both platforms. The check runs there, outside any
     `Output.apply`, so a preview runs it too.
2. **Spec and PPX.** `Role.name`, `rule<'role>` with `AllowRoles`, `named`,
   the injected `type role`, `Role.admin`; `AllowGroups` and `AdminGroup`
   removed. Unit tests for `isAllowed` with roles mapped to groups.
3. **Platforms.** The role mapping, `setElevatedRoles` resolved into
   `REVENTLESS_ELEVATED_GROUPS`, `providedGroups`, on both platforms; the AppSync
   directives written from mapped groups. The local resolver test and the directive test extended with a
   mapping that renames a group.
4. **The check ([§5](#5--a-check-that-the-platform-can-provide-every-role)).** At deploy and at start, with a test per failure it names.
5. **GWT ([§7](#7--gwt-scenarios-state-the-callers-roles)).** `Caller` with roles; authorization before ownership; tests in
   `reventless/gwt/tests`.
6. **Examples.** Migrate annotations to `AllowRoles` with a `Roles` module per
   plugin; add the [§8](#8--role-based-scenarios-in-the-examples) scenarios; refresh lifecycle models.
7. **Docs** as in [§6](#6--allowgroups-becomes-allowroles), and the terminology of [§2](#2--the-two-words) applied to existing comments
   where "role" and "group" are mixed.

Steps 2 to 7 can ship in one commit or in several; step 6 should not land before
step 5.

## §10 — What this does not do

These are out of scope here, not rejected; a later permissions layer may add
them on top of the roles this plan introduces ([§2](#2--the-two-words)).

- **No permissions model.** A role grants what the annotations say it grants;
  there is no separate list of permissions per role.
- **No role hierarchy or nested groups.** `Admin` is not implicitly a
  `Merchandiser`; a rule that should admit both names both, as today.
- **No per-tenant roles** ([§11](#11--decisions-and-what-is-still-open), item 6).
- **No change to how a provider issues groups**, to the active-role mechanism, or
  to AWS IAM roles.
- **No change to what a refusal looks like on the wire**; that stays with
  `appsync-refusal-vocabulary.md`.

## §11 — Decisions and what is still open

1. **The annotation syntax** is `@authorize(AllowRoles([Merchandiser]))`, with
   the plugin's roles in a `Roles.res` found by convention and the rule typed by
   them ([§3](#3--a-plugin-declares-its-roles)).
2. **Supplied user pools** declare their groups with `providedGroups`, and the
   check fails by default ([§5](#5--a-check-that-the-platform-can-provide-every-role)). *Open:* whether to add, later, a deploy-time
   comparison of the declared list with the pool's real groups. Taken up in
   `groups-checked-against-the-pool.md`, after plugin stacks turned out to
   have no manifest to read.
3. **Old names.** `AllowGroups` and `AdminGroup` are removed in this change
   ([§6](#6--allowgroups-becomes-allowroles)).
   `REVENTLESS_ELEVATED_GROUPS` stays as the only environment variable; there is
   no `REVENTLESS_ELEVATED_ROLES` ([§4](#4--a-platform-provides-groups-for-those-roles)).
4. **Shared roles.** Each example plugin declares its own roles; they are joined
   by name, and the hybrid example's roles do not overlap anyway (`Merchandiser`
   in catalog, `Fulfilment` in ordering, `Admin` from the framework). A shared
   package is introduced only when a role becomes part of a contract between
   plugins, and the docs say so.
5. **Authoring tools** that write `@authorize` keep *reading* `AllowGroups`,
   because existing code contains it, and write `AllowRoles` with a `Roles.res`
   for a framework version that has it, gated on that version. This repository's
   own generator does not write `@authorize`.
6. **Per-tenant roles** are out of this plan. A tenant-scoped role ("administrator
   of organisation X") is not a fixed group and cannot be a gate at the API
   layer. Its place already exists: `registerCommandInterceptor` in
   `CommandGenerator_Callback` runs with the caller's identity before a command
   is published, which is where a later permissions layer can decide it, on top
   of the coarse role check. Nothing in this plan's mapping assumes roles are
   global beyond that gate.
