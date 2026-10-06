# Plan: a command's rule looked up by its name, without a cast

**Date:** 2026-10-01<br/>
**Status:** Proposed. Nothing built.<br/>
**Relates to:** `done/roles-a-plugin-declares-and-a-platform-provides.md` (the rule
type this changes, `rule<'role>`), `generated-surfaces-state-required-access.md`
(what `requiredAccess` is derived from).

**In plain words.** Every command spec has a function that says who may issue
each of its commands: `commandAuthorization: command => rule`. The framework
never has a real command when it needs the answer. It asks "who may issue
`ArchiveProduct`?" while building the API, the published plugin structure and the
local resolvers, before anyone has sent anything. So it fakes a command from the
constructor's name (`{TAG: "ArchiveProduct"}`, or the bare string for a
constructor without payload) and casts the spec's function with `Obj.magic` so it
accepts the fake.

That cast hides two lies: the fake is not a `command`, and the function is called
at a type it was not written for. Neither is checked. A rule that read a field of
its command would crash on the fake, and nothing would say so until it ran.

This plan replaces the function with the question the framework actually asks:
`authorizationOf: string => rule<role>`, keyed by the constructor's name. The PPX
already knows every constructor and its rule, because it writes the switch today,
so it can write this one instead. No fake command is needed, so no cast.

---

## §1 — What is there today

The casts, all in `reventless-core`. Each calls a spec's
`commandAuthorization` with an `unknown` that it casts to the spec's `command`,
then turns the result into names with `Authorization.named`:

| File | Line | What it feeds |
| --- | --- | --- |
| `plugin/component/Plugin_Structure.res` | 1709, 1744 | `requiredAccess` / `requiredRoles` per command, for state-change slices and aggregates |
| `plugin/component/Plugin_Builder.res` | 218, 240 | the local resolver hook, and the aggregates' AppSync `fieldPermissions` |
| `plugin/component/Plugin_Helpers.res` | 1154 | the local resolver hook for slices |
| `admin/Platform_Admin_Structure.res` | 41 | the admin `Plugin` aggregate's command defs |
| `components/Dcb/Dcb_Builder.res` | 538, 554, 1082, 1114 | the slices' resolver hook, their AppSync `fieldPermissions`, inbound translations |

The receiving side is typed `~commandAuthorization: unknown => permission` in
`Plugin_Structure` (`toCommandDef`, `extractCommandDefs`), `Dcb_Builder`,
`Plugin_Helpers.platformHooks` and the local
`CommandGeneratorResolvers_GraphQL.register`.

The fakes are built in four places, each with its own `Obj.magic`:
`Plugin_Structure.syntheticCommand`, `Plugin_Builder` (line 238),
`Dcb_Builder.permissionForFirstConstructor` and its sibling loop, and
`CommandGeneratorResolvers_GraphQL.syntheticCommand`. The same files also cast
`commandSchema` to `S.t<unknown>` with `Obj.magic` where `S.castToUnknown` would
do.

Views have no such problem: `authorization` is a value, read typed.

Who calls `commandAuthorization` with a real command: only the GWT, in
`Behavior_GWT.Acting`, which already knows the command's name
(`Message.variantNameOfJson`).

## §2 — The member

The command-carrying spec module types (`Aggregate.Spec`, `StateChangeSlice.Spec`,
`InboundTranslationSlice.Spec`) replace

```rescript
let commandAuthorization: command => Authorization.rule<role>
```

with

```rescript
/** Who may issue the command with this constructor name. Total: a name the spec
    does not know gets the spec's default rule, as a spliced command does today. */
let authorizationOf: string => Authorization.rule<role>
```

- **Generated, not written.** The PPX emits it from the same per-constructor
  `@authorize` attributes and file-level `@@reventless.authorize` it reads now:

  ```rescript
  let authorizationOf = name =>
    switch name {
    | "ArchiveProduct" => AllowRoles([Admin, Merchandiser])
    | _ => AllowAuthenticated
    }
  ```

  The names are copied from the constructors the type declares, so they cannot
  drift from it, and a misspelled role is still the compiler's error at the case.
- **Spliced constructors** (a trait's commands spread into the host's type) get
  the file default through `_`, which is what the generated switch's wildcard
  gives them today. The PPX already treats a spread as non-exhaustive.
- **A spec that writes its own** (the framework's `ExtensionMapping`, test
  fixtures) writes `let authorizationOf = _ => AllowAuthenticated`, or a switch
  on names. A string switch there is weaker than a constructor switch; it is also
  what the framework has been doing behind the cast, now in the open.
- **The GWT** looks the rule up by the command's name, which `Acting` already
  computes for its refusal message.

`commandAuthorization` is removed rather than kept beside it: two members saying
the same thing would be two places to disagree, and nothing needs the typed form
once the GWT reads the name.

## §3 — The framework side

- `~commandAuthorization: unknown => permission` becomes
  `~authorizationOf: string => permission` at every receiving site in [§1](#1--what-is-there-today). Each
  call site passes `name => M.Spec.authorizationOf(name)->Authorization.named`,
  which erases the role (see the roles plan) explicitly rather than inside a cast.
- The four fake-command builders are deleted. Their callers already hold the
  constructor name; `isVariantPayloadBearing` stays only where something other
  than authorization needs it.
- The `commandSchema->Obj.magic` casts in the same functions become
  `S.castToUnknown`.
- `Dcb_Builder.permissionForFirstConstructor` keeps its "first constructor"
  semantics, now as `authorizationOf(first)`.

## §4 — Order of work

1. The roles change (parameterised `rule<'role>`, `Authorization.named`) has
   landed, so the member is written once in its final type.
2. PPX: emit `authorizationOf` instead of `commandAuthorization`, for file specs
   and for inline specs (`walk_inline_specs`). The PPX shell tests assert the
   switch on names, a spread falling to the default, and that no
   `commandAuthorization` is emitted.
3. Spec module types and the hand-written specs: `ExtensionMapping`, the GWT
   fixtures, and the test and integration fixtures that declare their own.
4. The receiving sites and the deleted fake builders ([§3](#3--the-framework-side)); the GWT's `Acting`.
5. Tests: the local resolver test (`CommandAuthorizationTest`) and
   `PluginStructureAccessTest` exercise the same behaviour through the new
   member; a grep in the review confirms no `Obj.magic` remains on an
   authorization path.

One commit; it is breaking for anyone who wrote `commandAuthorization` by hand,
which alpha allows.

## §5 — The same shape, not covered here

`commandTransition` is cast the same way (`unknown => Transition.t<string>`, five
sites) and called with the same fakes. It cannot follow this plan as written: its
switch is written by the host, not generated, so there is no PPX-owned list of
constructor-to-answer pairs to emit by name. Removing that cast needs its own
design (for example, the PPX wrapping the host's switch in a by-name lookup over
the declared constructors), and is left to a plan of its own.
