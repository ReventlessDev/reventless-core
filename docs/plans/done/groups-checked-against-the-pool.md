# Plan: the groups a deployment provides, read from the user pool

**Date:** 2026-10-01<br/>
**Status:** Done (2026-10-01). Built as described, except where [§10](#10--as-built) says how
and why the build departed from it.<br/>
**Follows:** `roles-a-plugin-declares-and-a-platform-provides.md`. This plan
fixes a gap in that plan's [§5](roles-a-plugin-declares-and-a-platform-provides.md#5--a-check-that-the-platform-can-provide-every-role) check and settles its open item [§11.2](roles-a-plugin-declares-and-a-platform-provides.md#11--decisions-and-what-is-still-open) ("a
deploy-time comparison of the declared list with the pool's real groups").<br/>
**Relates to:** `../identity-is-a-capability-not-a-cognito-handle.md` (pool
resolution, and the identity provider as a capability),
`../active-role-store-scoped-to-the-pool.md` (a pool this stack did not create).

**In plain words.** Before a plugin deploys, the platform checks that every
role the plugin's commands and views need maps to a group the deployment has.
Today "has" means the groups in an accounts manifest (`users.yaml`). That file is
a record of what someone *meant* to create, not of what the user pool holds.
It is also read only from the directory the deploy runs in. A plugin stack runs
in its own directory, where there is no manifest, so its check saw only `Admin`.
The online shop's catalog and ordering stacks were refused on alpha even though
the pool has every group they need.

The obvious patch, listing the groups again in each plugin stack's config, makes
that stack pass but proves nothing. Any name you type there passes, whether or
not the pool has it. This plan instead asks the user pool which groups it has
and checks the plugin's roles against that answer.

---

## §1 — Why the check matters, and why it must ask the pool

On AWS a role becomes a Cognito group named in an AppSync directive
(`@aws_cognito_user_pools(cognito_groups: ["Merchandiser"])`). AppSync does not
check that the pool has that group. A token cannot carry a group the pool lacks,
so every caller is refused with `Unauthorized`. The deploy succeeds and no log
says why.

Deciding at runtime cannot help. Authorization asks only whether the token holds
the group. "The group does not exist" and "this person does not have the role"
look the same from there, so a deploy-time check is the only place the mistake
can show.

Its answer is only as good as its source:

| Source | What it tells you | Weakness |
| --- | --- | --- |
| accounts manifest / `users.example.yaml` | what a provisioning run will create | read from the deploy's working directory; absent in plugin stacks and in CI (gitignored); unrelated to a supplied pool |
| declared list (`Platform.providedGroups`, a config key) | what an author says the pool has | unverified; a typo passes; drifts from the pool |
| **the pool (`ListGroups`)** | what the pool has | needs the pool id, a region and read permission at deploy time |

Only the last answers the question the check asks.

A group can exist and have no members. That still refuses everybody, but it is
ordinary administration ("nobody holds this role yet"), not a configuration
mistake, and it is not this check's business.

## §2 — What fails today

- `Platform.Make()` (`reventless/aws/src/Platform.res`) provides
  `[adminGroup()] ++ AccountsManifest.declaredGroups()`.
- `declaredGroups` reads `<cwd>/.reventless/users.yaml`, else
  `<cwd>/users.example.yaml`.
- CI deploys the platform from `platform-aws/` (which has the template) and each
  plugin from `<plugin>-aws/` (which has neither). The platform builds no plugin,
  so its passing check covered only the elevated roles.
- The plugin `Main.res` is generated (`Codegen.res`, AWS variant), so a plugin
  stack has no hand-written root in which to call `Platform.providedGroups`.

Locally the manifest *is* the user store, so the groups it names exist by
construction. A root that loads the store from somewhere else can still make
the check read the wrong file ([§9](#9--the-local-platform-the-stores-source-not-the-working-directory)).

## §3 — The check reads the pool

Before `deployPlugin` builds the plugin, the deploy program resolves the pool
and lists its groups. The provided set is:

- **A pool the platform can list** (Cognito): the pool's groups, plus the groups
  the role mapping names. A mapped group the pool lacks still fails, because
  naming a group in `roleGroups` does not create it.
- **A provider that cannot be listed**: the declared list
  (`Platform.providedGroups`), as today. That keeps the check usable for an
  identity provider behind the capability seam that offers no listing.

When the pool can be listed, a declared group the pool lacks fails the deploy.
A declaration that contradicts the pool is the same mistake the check exists to
catch.

The manifest no longer counts on AWS. It describes what provisioning will
create, and [§5](#5--a-pool-the-platform-creates) handles the pool that provisioning has not reached yet.

**Pool id and region.** These resolve the same way the plugin stack already
resolves them for its resolvers:

- a supplied pool: `REVENTLESS_IDENTITY_PROVIDER_ID` / the sidecar /
  `platform:identityProviderId`, all synchronous;
- a pool the platform stack created: the platform stack's `identityProviderId`
  and `identityProviderRegion` outputs, read with
  `StackReference.getOutputValue` (a promise, and readable in a preview).

**Why this works in a preview.** `ListGroups` is a read call, not a resource, and
the check does not run inside an `Output.apply`. That was the reason the done
plan gave for a declared list ("where no call to the provider is possible"). It
holds for values from applied resources, not for a read against something that
already exists.

**Permission.** The deploy principal needs `cognito-idp:ListGroups` on the pool.
CI's deployer already creates groups through provisioning. Check it anyway, and
say so in the failure message when the call is denied, rather than reporting
"no groups".

## §4 — Where the await goes

`RoleCoverage.check` runs synchronously in `Plugin_Builder.make`, and
`DeployBootstrap` contributions are `unit => unit`. The listing has to finish
before the plugin is built. In order of preference:

1. **An awaited step in the generated plugin `Main`.** `Codegen` emits
   `await ReventlessAws.Platform.loadProvidedGroups()` before `deployPlugin`. It
   resolves the pool, lists its groups and stores them where
   `Role.providedGroups()` reads them. The generated `Main.res.mjs` is ESM, so
   top-level await is available; whether ReScript v12 emits it at module level
   is the spike's first question. The platform `Main` (hand-written) gets the
   same line for its elevated-role check.
2. **An async `DeployBootstrap` phase** (`PreDeployAsync`, awaited by the
   generated `Main`). It is more general, but it adds a second contribution type
   to a seam that has one caller for this.
3. **Fire and fail.** Start the listing without awaiting it, and throw when it
   resolves. Pulumi fails the run on an unhandled rejection, but during `up`
   the plugin's resources are already registering by then. Rejected: a check
   that may lose the race against the resources it guards is not a gate.

## §5 — A pool the platform creates

When the platform stack creates the pool, it creates the `Admin` group itself
(`Util_CognitoGroupUser.addUserGroup` in `Platform_Stack`). Every other group
appears only when a provisioning run (`ProvisionCognito.ensureGroup`) reads the
manifest. Provisioning happens after the deploy, so on a fresh stack [§3](#3--the-check-reads-the-pool) would
find only `Admin` and refuse every plugin before anyone could provision.

The deployment owns that pool, so it should create the groups its plugins need.
Options:

- **The plugin stack declares an `aws.cognito.UserGroup` for each role it needs.**
  Two plugins needing the same role would declare the same group from two
  stacks. Pulumi has no shared ownership, so the second create fails, and
  deleting either stack deletes the group the other still needs.
- **The platform stack declares the groups**, from a list the platform root
  states. That puts back a declared list, but one the deploy makes true rather
  than one it merely trusts. A plugin needing a role outside it still fails.
- **Provisioning runs before the plugin deploys.** CI orders "deploy platform →
  provision → deploy plugins". That adds no resources, but a manual first
  deploy fails until someone provisions.

*Open — decide in the spike.* Leaning to the second option: it is the only one
where the stack that owns the pool owns its groups.

A supplied pool is outside all of this. Its groups belong to whoever supplied it,
and [§3](#3--the-check-reads-the-pool)'s listing is the whole answer.

## §6 — Interim for alpha

Alpha's pool is supplied (`cognitoUserPoolManaged: false`), and its groups
(`Merchandiser`, `Fulfilment`, `Shopper`) exist. Its plugin deploys stay red
until [§3](#3--the-check-reads-the-pool) lands. A `platform:providedGroups` config key in each plugin stack
gets them green and was tried locally (both previews pass), but it is the
unverified list [§1](#1--why-the-check-matters-and-why-it-must-ask-the-pool) argues against, so it is not committed. If alpha must deploy
before [§3](#3--the-check-reads-the-pool), it can go in on a temporary basis and be removed in the commit that
lands [§3](#3--the-check-reads-the-pool).

## §7 — Order of work

1. **Spike.** Can top-level `await` be emitted from the generated `Main.res`
   ([§4.1](#4--where-the-await-goes))? Does `getOutputValue` resolve in a preview for a created pool? Does
   the CI deployer have `ListGroups`? Decide [§5](#5--a-pool-the-platform-creates).
2. **Binding.** `ListGroupsCommand` (paginated) in `rescript-aws-sdk`'s
   `CognitoIdentityServiceProvider`.
3. **Provided groups on AWS.** `Platform.loadProvidedGroups()` resolves the pool
   and lists it. `Role.provideGroupsFrom` takes the listed groups; the manifest
   source is dropped on AWS (kept locally). A declared group the pool lacks
   fails.
4. **Codegen.** The AWS `Main` emits the awaited call before `deployPlugin`.
   Refresh the generated `Main.res` / `.res.mjs` of every example.
5. **[§5](#5--a-pool-the-platform-creates)'s group creation** for a created pool.
6. **Tests.** `RoleCoverage` keeps its pure tests. Add tests for the provided
   set from a listing (listed, mapped-but-missing, declared-but-missing, denied
   call), with the client stubbed. Run a local `pulumi preview` of a plugin
   stack on alpha (supplied pool) and on a stack with a created pool.
7. **Docs.** `docs-app/authorization.md` §"Every role must have a group": the pool is the
   source on AWS, `providedGroups` is for providers that cannot be listed, and
   the permission the deployer needs.

## §8 — What this does not do

- It does not check that a group has members ([§1](#1--why-the-check-matters-and-why-it-must-ask-the-pool)).
- It does not ask anything outside the process on the local platform. There the
  user store is the identity provider, so its groups exist by construction; [§9](#9--the-local-platform-the-stores-source-not-the-working-directory)
  makes the check read the store's actual source.
- It does not compare groups at runtime. A group deleted from the pool after the
  deploy refuses its callers until the next deploy says so.

## §9 — The local platform: the store's source, not the working directory

**In plain words.** Locally there is no pool to ask. The user store holds the
accounts, so the groups it holds exist. The check should read whatever the
store will be loaded from, and today it can read the wrong file.

**Today.** `Platform.Make()` in `reventless/local` provides
`LocalAuth.knownGroups()` (the built-in admin and every user registered so far)
plus `AccountsManifest.declaredGroups()` (`<cwd>/.reventless/users.yaml`, else
`<cwd>/users.example.yaml`). The manifest is read from disk because the store
loads only when the servers start (`UserStore.autoLoadOnce`), after the plugins
are built and checked.

A root can load the store itself with `UserStore.load(~users)` or
`UserStore.load(~usersFile)`, and then `autoLoadOnce` does nothing. The check
does not know that happened:

| When the root calls `load` | What the check counts | Result |
| --- | --- | --- |
| before the plugins are built | the loaded users (already registered) **and** the cwd manifest | passes on groups from the cwd file, which the store never loaded |
| after the plugins are built | only the cwd manifest | refuses a plugin the loaded users would satisfy, or passes on groups they lack |
| never | the cwd manifest, which `autoLoadOnce` then loads | correct |

The template adds a smaller mismatch. The check counts `users.example.yaml`,
but the store never loads it. On a clone where `pnpm run setup` has not run yet,
the check passes and nobody can sign in. That is the job of `setup` and stays as
it is: the check is about a role nobody *can* hold, not one nobody holds yet.

**Change.** The provided groups come from the store's resolution, not from a
second read of the working directory:

- `UserStore` exposes the groups of its source without registering them: the
  `~users` entries, the `~usersFile` file, or the default path. The default
  path is the one `autoLoadOnce` would take, so the check and the store cannot
  read different files.
- When `load` has already run, the registered users are the answer, and the
  working directory no longer counts.
- A `load` call after the plugins are built is too late for the check. The
  platform says so (an error naming `UserStore.load`, since a store that changes
  after the check makes the check meaningless) rather than leaving it to chance.
  Tests call `load` before the platform starts, so none is affected; confirm in
  the spike.
- The template keeps counting, as a stand-in for the manifest `setup` will make
  from it.

**Tests.** One per row of the table above, plus a template-only directory.
`LocalAuthUserStoreTest` already loads from `~users` and `~usersFile` and can host
them.

**Order.** Independent of [§3](#3--the-check-reads-the-pool)–[§5](#5--a-pool-the-platform-creates). It can land first, as a small change on its own.

## §10 — As built

**The spike's answers.**

- *Top-level await.* ReScript emits it, and it runs under plain `node`. But
  Pulumi loads a program whose package is not `"type": "module"` with
  `require()`, and Node refuses `require()` of a module graph that awaits at the
  top level. The first preview failed on exactly that. So [§4.1](#4--where-the-await-goes) is built without
  the await: the generated `Main` exports
  `default = loadProvidedGroups()->Promise.thenResolve(() => deployPlugin(…))`,
  and `PostDeploy` runs inside it, after the plugin is registered. Pulumi
  resolves a promise among a program's exports, so the stack outputs keep their
  shape (`default` nesting included), as the alpha previews show. Making the
  packages `"type": "module"` was the other way out. It was rejected because Pulumi's
  ESM path refuses a module with both a default and named exports, which every
  ReScript `Main` has (`Platform`, the plugin module), and because it would change
  the exports other tools read.
- *Pool id in a preview.* `StackReference.getOutputValue` resolves in a preview.
  It is bound in `rescript-pulumi-pulumi`. A plugin stack and `Platform.Make()`
  share one reference (`Platform.platformStackReference`), since a second
  reference with the same name is a duplicate resource.
- *Permission.* The CI deployer has `cognito-idp:ListGroups` (an IAM policy
  simulation says allowed). An `AccessDeniedException` fails the deploy with a
  message naming the permission.
- *Platform roots.* They build no plugin, so they run no plugin-role check and
  need no listing. Only the generated plugin `Main`s (and the scaffold template
  `docs/templates/deploy-aws/plugin-Main.res`) call `loadProvidedGroups`.

**[§3](#3--the-check-reads-the-pool), departure.** The manifest still counts on AWS where nothing was listed: a
program that creates its pool in the same run, or a hand-written root that does
not call `loadProvidedGroups`. Refusing those outright would have broken every
hand-written root on upgrade, for a case the generated roots no longer hit.
`Role.listing`, once set, replaces every other source, the mapping included.

**[§5](#5--a-pool-the-platform-creates), decided.** No automatic group creation. On a pool the platform created,
the listing finds the administrator group, plus whatever `provision-accounts`
has created. A plugin needing another role fails until provisioning has run,
and the message says so. That failure is correct, because callers would be
refused, and it is loud. Creating groups from Pulumi would collide with the
groups provisioning already created on existing stacks (`GroupExistsException`). No stack in
this repository runs on a pool it created. Revisit if a fresh-stack first deploy
becomes a common path.

**[§6](#6--interim-for-alpha).** No longer needed: the alpha plugin stacks pass with no config change
(local `pulumi preview`, both stacks). Mapping `Merchandiser` to a group the pool
lacks (`REVENTLESS_ROLE_GROUPS=Merchandiser=NoSuchGroup`) fails the catalog
preview with the pool's real groups named, which shows the listing decides.

**[§9](#9--the-local-platform-the-stores-source-not-the-working-directory), as planned.** `UserStore.providedGroups` is the local platform's source.
`UserStore.pluginChecked` is set when `deployPlugin` starts, and an explicit
`load(~users | ~usersFile)` after it throws. The default `load()` stays allowed,
because it reads the file the check read.

**Where it lives.**

- `Role.provideListedGroups`, `Role.listing` and `Role.declaredButMissing`, and
  `RoleCoverage`'s two messages, are in `reventless-spec`.
- `Platform_ProvidedGroups` (pool resolution, paginated `ListGroups`) and
  `Platform.loadProvidedGroups` are in `reventless-aws`.
- `ListGroupsCommand` is in `rescript-aws-sdk`.
- `Codegen.renderMain` is in `reventless-spec`.
- `UserStore.providedGroups` is in `reventless-local`.

Tests: `RoleTest` (listing, mapped-but-missing, declared-but-missing),
`Platform_ProvidedGroupsTest` (pagination, exports, nesting), `PluginGeneratorTest`
(the generated `Main`), and `LocalAuthUserStoreTest` (the rows of [§9](#9--the-local-platform-the-stores-source-not-the-working-directory)'s table, and
the template).
