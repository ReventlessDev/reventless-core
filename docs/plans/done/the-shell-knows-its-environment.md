# Plan: the shell knows its environment, and the local platform serves a chosen UI directory

**Date:** 2026-10-18<br/>
**Status:** ✅ Done. [U1](#u1--one-resolver-for-the-shells-environment) to
[U5](#u5--docs-and-release) are built; the release goes out with the next push. What
differs from the steps is listed under [Outcome](#outcome).<br/>
**Touches:** `reventless/aws` (`Util_ShellConfig`, the host UI part of `Platform.deployPlatform`),
`reventless/local` (`ShellConfig`, `UiHints`, `UiSlots`, `BakedManifest`, `HostShellDist`,
`Platform.makePlatform`), `reventless/spec` (one shared resolver), and the guides
`local-dev.md` and `deploy-environments.md`.<br/>
**Builds on:** [an-app-declares-its-environments.md](../an-app-declares-its-environments.md)
(environments with a purpose, recorded with every deployment) and
[host-ui-shell-config-choices.md](host-ui-shell-config-choices.md) (the composed
`config.json`).<br/>
**Companion:** reventless-ui. The shell reads the two keys and draws an environment badge; the
host shell's start command serves the directory [U4](#u4--the-local-platform-honours-assetsdir)
writes to.

## Goal

The host shell can tell its users which environment they are in: *local* on a developer's
machine, the environment's name on a deployed platform that is not production, and nothing in
production. Both platforms write that into `config.json`, from what core already knows about
every deployment. And the local platform writes the host UI's files into a directory the app
chooses, as the AWS platform already does with `assetsDir`.

## Why

- **People enter data into the wrong system** when a test platform looks exactly like
  production. A badge in the shell header, on the login page and in the tab title prevents
  that, but the shell cannot draw it: nothing tells it the environment.
- **Core knows the environment and does not pass it on.** The stack name is the environment in
  resource tags (`reventless:environment`), the deploy hook and the deployment record. A
  declared environment and its purpose reach every deploy through
  `DeploymentProvenance` ([an-app-declares-its-environments.md](../an-app-declares-its-environments.md)).
  `Util_ShellConfig.fields` writes endpoints, the admin group, slots, the baked manifest and
  view modes, but neither of these.
- **The shell already has a key for the name and nobody fills it.** `Config.t` reads
  `environment` as a string; with `platformName`, it scopes the single-platform views. Today it
  is set only by hand in a console's own `config.json`.
- **Nothing tells production apart, except a list of stack names.** `Util_HostUiDomain`
  (`hostUiProdStacks`, default `["prod", "main"]`) is the AWS platform's one notion of a
  production stack; it decides the domain name, the store layout and log retention. A declared
  environment's `purpose` can say `production` too. The shell needs one answer, and it should be
  the one these two already give, not a third.
- **The local platform can only write into the installed host shell package.**
  `HostShellDist.dir()` resolves `@reventlessdev/reventless-host-shell/dist` from the working
  directory, and every local writer (`ShellConfig`, `UiHints`, `UiSlots`, `BakedManifest`) writes
  there. An app that composes its own UI bundle (extra modules beside the shell, a build of its
  own) cannot point the local platform at it, while on AWS `hostUiBundle.assetsDir` does exactly
  that. The local platform carries the field only to fit the shared signature.

## The shape

Two keys in `config.json`, both computed by the platform:

```json
{ "environment": "test", "environmentPurpose": "test" }
```

| Platform | `environment` | `environmentPurpose` |
|---|---|---|
| Local | `"local"` | `"local"` |
| AWS, declared environment | `DeploymentProvenance.environment` | `DeploymentProvenance.purpose` |
| AWS, no declaration | the stack name | `"production"` when the stack is in `hostUiProdStacks`, absent otherwise |

- **`environment` keeps its meaning.** It is the name the deployment record and the inspector
  use (`exportDeploymentMetadata`: the declared environment, else the stack), which is what the
  shell's platform scope already expects.
- **`environmentPurpose` is the purpose's name**: `dev`, `test`, `production`, `demo`,
  `review`, a team's own word, or `local`. Absent means "not known to be production". The shell
  shows a badge for everything except `production`, so a missing declaration is visible rather
  than hidden.
- **One resolver decides both**, used by the AWS platform and by any tool that needs the same
  answer at deploy time (a step that runs before Pulumi reads `REVENTLESS_ENVIRONMENT_PURPOSE`
  and the stack the same way).
- **The local platform honours `hostUiBundle.assetsDir`.** When set, the local writers write
  there; when absent, they write into the host shell package's `dist/` as today.

## Steps

The steps are numbered U1 to U5. **U** stands for *UI configuration*.

### U1 — One resolver for the shell's environment

In `reventless/spec`, beside `DeploymentProvenance`: `ShellEnvironment.resolve(~provenance,
~stack, ~prodStacks)` returns `{name: string, purpose: option<string>}` by the table above. Pure;
no Pulumi.

`Util_HostUiDomain.resolveProdStacks` stays the source of `prodStacks`; the resolver takes the
list as an argument so `spec` does not depend on `aws`.

#### Tests

- A declared environment wins over the stack: `{environment: "test", purpose: "test"}` on stack
  `test-eu` gives `test` / `test`.
- No declaration, stack `prod` with the default list: `prod` / `production`.
- No declaration, stack `alpha`: `alpha` / none.
- A declared purpose of a team's own (`staging`) is passed through unchanged.

### U2 — The AWS platform writes both keys

In `Platform.deployPlatform`, the computed array that feeds `Util_ShellConfig.fields` gains
`environment` and `environmentPurpose` (the latter only when known), from [U1](#u1--one-resolver-for-the-shells-environment) with
`Pulumi.getStackName()`, `DeploymentProvenance.current()` and `resolveProdStacks()`.

Both become computed keys: a `shellConfig` that names either fails the deploy with the collision
guard's message, as it does for `manifestUrl`. No example sets either today.

#### Tests

In `Util_ShellConfigTest.res`: both keys present in `fields`' output when computed; absent purpose
leaves the key out; `shellConfig` naming `environment` fails with the guard.

### U3 — The local platform writes both keys

`ShellConfig.computedKeys` gains both keys, and `overlay` writes `environment: "local"`,
`environmentPurpose: "local"`. The local platform's deploy hook keeps its own values; aligning
them is [Q3](#open-questions).

#### Tests

In `local/tests/ShellConfigTest.res`: both keys in the overlay; the baseline dance unchanged;
`shellConfig` naming either key fails.

### U4 — The local platform honours `assetsDir`

- `makePlatform` resolves the host UI directory once: `hostUiBundle.assetsDir` if set, else
  `HostShellDist.dir()`.
- `ShellConfig.emit`, `UiHints.emit`/`watch`, `UiSlots.emit`/`watch` and `BakedManifest.emit` take
  that directory. `BakedManifest` gains the `~dir` argument the other three already have as a
  test seam; for all four it becomes the real parameter.
- The local platform's `hostUiBundleConfig` comment drops `assetsDir` from the fields "carried
  only to fit the signature".
- The baseline step of `ShellConfig.emit` works unchanged in a chosen directory: whatever
  `config.json` the app put there is the baseline, and the overlay is written over it.

The other half is in reventless-ui: the host shell's start command serves a directory it is
given instead of its own `dist/`. Until it does, a chosen directory is written but not served;
the guide says so.

#### Tests

- Each writer writes into a temporary directory passed as `assetsDir` and leaves the package's
  `dist/` untouched.
- Without `assetsDir`, behaviour is byte-for-byte today's (the existing tests).

### U5 — Docs and release

- `docs/guides/local-dev.md`: the two keys, and `assetsDir` on the local platform (the section on
  the host UI bundle and `dist/`).
- `docs/guides/deploy-environments.md`: "What every deployment records" gains what the shell
  receives, and how `purpose` decides the badge.
- A release of `reventless/spec`, `reventless/aws` and `reventless/local`; the examples pick it
  up with their next pin.

## Order

[U1](#u1--one-resolver-for-the-shells-environment) first;
[U2](#u2--the-aws-platform-writes-both-keys) and [U3](#u3--the-local-platform-writes-both-keys)
after it, in either order. [U4](#u4--the-local-platform-honours-assetsdir) is independent of the
other three and can land first. [U5](#u5--docs-and-release) closes.

## Risks

- **A `shellConfig` that already names `environment`** fails the deploy after [U2](#u2--the-aws-platform-writes-both-keys). None in this
  repository does; the release notes say so. The fix is to delete the entry, since the platform
  now writes the same value.
- **`hostUiProdStacks` now also decides the badge.** A team with a production stack outside the
  list sees a badge in production until it declares the environment or extends the list. That is
  the safe direction: a badge too many, never one too few.

## Open questions

1. **One object key (`environment: {name, purpose}`) or two flat keys?** Recommendation: two
   flat keys. `environment` is already a string the shell reads for its platform scope;
   changing its type would break that reader and every hand-written console config.
2. **Should the platform also write `platformName`,** so the shell's platform scope works
   without a hand-written config? Recommendation: yes, but in its own change; it touches the
   scope's behaviour, not the badge.
3. **The local deploy hook reports `environment` as the stack name in two places and `"local"`
   in a third.** Recommendation: align on `"local"` in a separate fix; the badge does not depend
   on it.

## Outcome

In plain words: both platforms now tell the shell which environment it runs in, and the
local platform writes the host UI's files into the app's chosen directory. Four details differ
from the steps above.

- **[U1](#u1--one-resolver-for-the-shells-environment): a declared environment without a
  purpose falls back to the stack list.** `ShellEnvironment.resolve` takes the name from the
  declaration, else the stack, and the purpose from the declaration, else `production` for a
  stack in `prodStacks`. The table's two rows are the two ends of this rule. The module also
  carries the key names and `configFields`, so both platforms write the keys the same way.
- **[U2](#u2--the-aws-platform-writes-both-keys): `Util_ShellConfig.fields` takes
  `~environment`** instead of the deploy adding the keys to `computed`. That way the test calls
  the same code path the deploy does. The collision guard covers the keys as before.
- **[U3](#u3--the-local-platform-writes-both-keys): a local platform that declares nothing now
  writes `config.json`.** The overlay always carries the two keys, so the shell's `config.json`
  gets them and a `config.base.json` whenever a shell is installed. Without the package, or
  without a `config.json` in the directory, the environment keys alone are dropped silently. A
  missing package or baseline is still an error only when something else is declared.
- **[U5](#u5--docs-and-release): two more docs.** The `config.json` contract in
  [`ui-fragments-deployment.md`](../../../packages/doc/docs-infrastructure/ui-fragments-deployment.md#configjson-contract)
  and [§5.5](../../../packages/doc/docs-app/ui-configuration.md#55-the-environment) of
  [`ui-configuration.md`](../../../packages/doc/docs-app/ui-configuration.md) describe the
  two keys too, and [local-dev.md](../../guides/local-dev.md#where-the-host-ui-files-go-assetsdir)
  and [deploy-environments.md](../../guides/deploy-environments.md#what-the-host-shell-is-told)
  carry the guide sections.

## Not in scope

- Drawing the badge: the shell's change in reventless-ui.
- Serving the chosen directory locally: the host shell's start command, in reventless-ui.
- Local `viewModes`: still the backlog plan
  [Backlog/shell-config-json-contract-and-local-view-modes.md](../Backlog/shell-config-json-contract-and-local-view-modes.md).
  A chosen `assetsDir` lets an app ship its own `config.json` baseline with `viewModes`, which
  narrows that gap without closing it.
