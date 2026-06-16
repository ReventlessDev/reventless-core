# Directive Naming Consistency

## Problem

The `Call` constructor and `callHandler` type names in `ExtensionPointMapping` and `ExtensionMapping` are inconsistent with the rest of the directive vocabulary in the framework. All sibling constructors follow a `Verb<Noun>` pattern (`PublishCommand`, `PublishEvent`, `PublishEventAsync`, `PublishAggregateCommand`, `PublishStateChangeSliceCommand`, `PublishExtensionPointCommand`, `ForwardCommand`); only `Call` breaks the pattern with a bare verb.

The framework already names the typed payload a **directive** — `module type Spec` in both files declares `@schema type directive` (ExtensionPointMapping.res:52, ExtensionMapping.res:99) — and inline log messages already say "Call directive" (ExtensionPointMapping.res:220, 286; ExtensionMapping.res:364, 437). So the noun is established; only the constructor and handler-type names lag.

## Current state

### Variant definitions
| File:line | Variant type | Constructor |
|---|---|---|
| `reventless-infra/src/types/ExtensionPointMapping.res:7-12` | type alias `callHandler<'msg>` | (4-arg signature with `Schedule.create`, `Schedule.delete`, `QueryEngine.operations`, `'msg`) |
| `reventless-infra/src/types/ExtensionPointMapping.res:22-24` | `commandAction<'command, 'msg>` | `PublishCommand`, **`Call(callHandler<'msg>, 'msg)`** |
| `reventless-infra/src/types/ExtensionPointMapping.res:34-37` | `eventAction<'event, 'msg>` | `PublishEvent`, `PublishEventAsync`, **`Call(callHandler<'msg>, 'msg)`** |
| `reventless-infra/src/types/ExtensionPointMapping.res:116-118` | `abstractCommandAction` | `AbstractPublishCommand`, **`AbstractCall(string, unit => promise<unit>)`** |
| `reventless-infra/src/types/ExtensionPointMapping.res:121-124` | `abstractEventAction<'evt>` | `AbstractPublishEvent`, `AbstractPublishEventAsync`, **`AbstractCall(unit => promise<unit>)`** |
| `reventless-infra/src/types/ExtensionMapping.res:26-35` | `incomingCommandAction<…>` | `PublishAggregateCommand` (+async/plural variants), `PublishStateChangeSliceCommand` (+variants), `PublishExtensionPointCommand`, `ForwardCommand`, **`Call('msg => promise<unit>, 'msg)`** |
| `reventless-infra/src/types/ExtensionMapping.res:45-48` | `outgoingCommandAction<…>` | `PublishExtensionPointCommand`, `ForwardCommand`, **`Call('msg => promise<unit>, 'msg)`** |
| `reventless-infra/src/types/ExtensionMapping.res:178-184` | `abstractIncomingCommandAction` | (Abstract publish variants), **`AbstractCall(Reventless.Handler.handler<unit>)`** |
| `reventless-infra/src/types/ExtensionMapping.res:186-189` | `abstractOutgoingCommandAction` | (Abstract publish variants), **`AbstractCall(Reventless.Handler.handler<unit>)`** |

### Mapping callsites (where user-side `Call` is encoded into `AbstractCall`)
- `ExtensionPointMapping.res:219-225` (incoming command → `AbstractCall(reference, …)`)
- `ExtensionPointMapping.res:285-288` (outgoing event → `AbstractCall(…)`)
- `ExtensionMapping.res:363-365` (incoming event → `AbstractCall(…)`)
- `ExtensionMapping.res:436-438` (outgoing event → `AbstractCall(…)`)

### Dispatch sites (where `AbstractCall` is executed)
- `reventless-core/src/components/ExtensionPoint/ExtensionPoint_Callback.res:77-88` (`applyCommandAction`, destructures `AbstractCall(reference, handler)`)
- `reventless-core/src/components/ExtensionPoint/ExtensionPoint_Operations.res:121-127` (`applyEventAction`, `AbstractCall(handler)`)
- `reventless-core/src/components/Extension/Extension_Operations.res:108-113` (`let handle = async handler => …` helper)
- `reventless-core/src/components/Extension/Extension_Operations.res:141, 151` (`AbstractCall(handler) => handler->handle`)

### Other touch points
- `@schema type directive` in both `Spec` module types (ExtensionPointMapping.res:52, ExtensionMapping.res:99) — already the established term for the typed payload.
- Comments and log strings already use the word "directive" (ExtensionPointMapping.res:220, 286; ExtensionMapping.res:364, 437; Extension_Operations.res implicit via "calling handler").
- The PPX (`reventless-ppx/`) does **not** emit `Call` / `callHandler` / `handle` names — it only auto-`open`s the modules. A rename in `reventless-infra` is transparent to the PPX.
- Example plugins (`examples/online-shop-{aggregates,dcb,hybrid}`) currently use only `Publish*` / `Forward*` constructors. No user-facing `Call` usages today, which makes this a low-blast-radius rename.

## Naming options

All four options keep the existing `Publish*` / `Forward*` family and only change the `Call` constructor + supporting names. Pick one — the rest of the plan is identical regardless of choice.

### Option A — `HandleDirective` *(recommended)*
| Old | New |
|---|---|
| `Call(handler, msg)` (user-facing constructor) | `HandleDirective(handler, directive)` |
| `callHandler<'msg>` (type alias in EPM) | `directiveHandler<'directive>` |
| `AbstractCall(…)` (internal) | `AbstractHandleDirective(…)` |
| `let handle = …` (Extension_Operations.res:108) | `let handleDirective = …` |

**Why**: matches the `Verb<Noun>` shape of every other constructor, picks up the noun (`directive`) the framework already exposes through `Spec.directive`, and reads naturally — "publish a command", "publish an event", "forward a command", "handle a directive". The `Handle` verb also matches the existing private helper `handle`.

### Option B — `RunDirective`
Same renames as A but with `Run` instead of `Handle`. Slightly more action-oriented, less suggestive of a long-lived handler. Loses the alignment with the existing `handle` helper.

### Option C — `CallHandler`
| Old | New |
|---|---|
| `Call(handler, msg)` | `CallHandler(handler, directive)` |
| `callHandler<'msg>` | (unchanged) |
| `AbstractCall(…)` | `AbstractCallHandler(…)` |
| `let handle = …` | `let callHandler = …` (collides with type alias — would need a different value name) |

**Why not**: smallest semantic move, but reuses the already-loaded word "Call" and keeps the `Call` / `callHandler` name pair the user already flagged as confusing. Constructor `CallHandler` and type alias `callHandler` differ only in case — same word, two roles.

### Option D — `Dispatch`
Bare verb, no noun. Symmetric with the existing bare-verb `Call` rather than the noun-bearing siblings, so it doesn't actually solve the inconsistency. Listed only for completeness; not recommended.

**Recommendation: Option A** (`HandleDirective` / `directiveHandler` / `handleDirective`). The rest of this plan assumes A; for B/C/D substitute the names verbatim.

## Steps

### 1. Rename in `reventless-infra/src/types/ExtensionPointMapping.res`
- `type callHandler<'msg>` → `type directiveHandler<'directive>` (rename type param for clarity)
- `Call(callHandler<'msg>, 'msg)` → `HandleDirective(directiveHandler<'directive>, 'directive)` in both `commandAction` and `eventAction`
- `AbstractCall(reference, handler)` → `AbstractHandleDirective(reference, handler)` in `abstractCommandAction`
- `AbstractCall(handler)` → `AbstractHandleDirective(handler)` in `abstractEventAction`
- Mapping callsites in `doMapIncomingCommands` (line 219) and `doMapOutgoingEvent` (line 285): pattern-match on `HandleDirective` and emit `AbstractHandleDirective`
- Update the leading docstrings (lines 14-19, 26-32) to use the new constructor name and the word "directive" consistently
- Update log strings at lines 220, 286 from `"incoming Call directive"` / `"Call directive"` to `"incoming directive"` / `"directive"` (the word "Call" is no longer in the variant name)

### 2. Rename in `reventless-infra/src/types/ExtensionMapping.res`
- `Call('msg => promise<unit>, 'msg)` → `HandleDirective(Reventless.Handler.handler<'directive>, 'directive)` in `incomingCommandAction` and `outgoingCommandAction`
  - *Side-effect*: this also switches the handler-arg type from inline `'msg => promise<unit>` to the named `Reventless.Handler.handler` alias, matching the abstract form. Drop the type-param rename if you want to minimize churn; otherwise this aligns Extension with ExtensionPoint stylistically.
- `AbstractCall(Reventless.Handler.handler<unit>)` → `AbstractHandleDirective(Reventless.Handler.handler<unit>)` in both abstract types
- Update docstrings at lines 14-24, 37-43 ("invoke an arbitrary async callback (`Call`)" → "handle an extension-point-defined directive (`HandleDirective`)")
- Update mapping callsites at lines 363-365, 436-438 (pattern + emission + log strings)

### 3. Update dispatch sites in `reventless-core/src/components/`
- `ExtensionPoint/ExtensionPoint_Callback.res:77-88` — rename pattern `AbstractCall(reference, handler)` → `AbstractHandleDirective(reference, handler)`; update the two error strings `"Error on calling handler"` → `"Error on handling directive"`
- `ExtensionPoint/ExtensionPoint_Operations.res:121-127` — same pattern rename plus error-string update
- `Extension/Extension_Operations.res`:
  - Line 108: rename the helper `let handle = …` → `let handleDirective = …` and its error string `"Error on calling handler"` → `"Error on handling directive"`
  - Lines 141, 151: `AbstractCall(handler) => handler->handle` → `AbstractHandleDirective(handler) => handler->handleDirective`

### 4. Verify exhaustiveness via the compiler
After every step the ReScript compiler should flag exactly the touchpoints listed above. If the compiler points at something not in this plan, stop and add it before continuing — it's likely a callsite the audit missed (DCB slices, Automation, etc., should have been clean per the audit, but verify).

### 5. Sweep grep for leftover terminology
```
grep -rn "Call(handler" reventless/ examples/ packages/
grep -rn "callHandler" reventless/ examples/ packages/
grep -rn "AbstractCall" reventless/ examples/ packages/
grep -rn "calling handler" reventless/
```
Each should return zero hits (apart from this plan file and any historical changelog).

### 6. Build + tests
- `pnpm run build` at repo root — must succeed with zero warnings (project requires zero warnings, see `.claude/rules/conventions.md`)
- `pnpm test` — all GWT tests pass
- The example plugins (`examples/online-shop-{aggregates,dcb,hybrid}`) don't use `Call` today, so they should compile unchanged.

### 7. Documentation
- `packages/doc/docs/reventless-components/extensionpoint.md` and `.../extension.md` — search for `Call` / `callHandler`; if any prose references the old names, update.
- `docs/guides/` — same sweep.

## Out of scope

- The `Spec.directive` type itself stays as-is. It is the established public name for the typed payload.
- The handler signatures differ across domains (ExtensionPointMapping's `directiveHandler` carries Schedule + QueryEngine; ExtensionMapping uses `Reventless.Handler.handler<'directive>` with no infra args). This rename doesn't touch that asymmetry. Note the asymmetry is a **wiring** difference, not a code-ownership one — both EP and Extension mappings are app-authored (apps define their own extension points). The EP component is constructed with a scheduler (`ExtensionPoint_Builder` takes `~scheduler`, `ExtensionPoint_Operations.Ops` carries it) and threads it into the handler; the Extension component is never handed one (`Extension_Builder`/`Extension_Operations.Ops` have no scheduler), so its handler can't receive it. By convention extensions stay thin routers, so this is rarely felt — but if we want symmetry, the consumer's EventCollector path could thread the plugin scheduler into `Extension_Operations` the same way. A follow-up plan, not this one.
- `AbstractPublishCommand` carries an extra `reference` string (ExtensionPointMapping.res:117) used for batch error reporting. We mirror that on `AbstractHandleDirective(reference, …)` for the command-side variant (ExtensionPointMapping.res:118) — already the case today; no change needed.

## Migration impact

- **User code**: zero changes in shipped examples. External plugins built against the public `commandAction` / `eventAction` / `incomingCommandAction` / `outgoingCommandAction` types that emit `Call(...)` will need a one-line rename to `HandleDirective(...)`. This is a **breaking change** for any out-of-tree plugin.
- **Commit**: `feat!: rename Call directive to HandleDirective for naming consistency` — breaking change, triggers a major bump under semantic-release.
- **Changelog note**: callout that user-side `Call(handler, msg)` becomes `HandleDirective(handler, directive)` in both `ExtensionPointMapping` and `ExtensionMapping`. The handler-type name change (`callHandler` → `directiveHandler`) only matters for code that referenced the alias directly; most users construct the function inline.

## Open questions

1. Confirm Option A (`HandleDirective` / `directiveHandler` / `handleDirective`) is the desired naming. If not, pick B or C and substitute.
2. Should `ExtensionMapping`'s handler arg type move from inline `'msg => promise<unit>` to the named `Reventless.Handler.handler<'directive>` alias as part of step 2? Recommended (stylistic consistency with EP and with the existing `AbstractCall` payload), but optional — call it out before starting.

## Outcome

Executed Option A with the handler-arg type alias change in step 2 — answers to both open questions: yes.

**Files actually touched** (Option A + handler-arg alias swap):

Framework types:
- `reventless/reventless-infra/src/types/ExtensionPointMapping.res` — `callHandler<'msg>` → `directiveHandler<'directive>`; `Call(...)` → `HandleDirective(...)` on `commandAction`, `eventAction`; `AbstractCall(...)` → `AbstractHandleDirective(...)` on both abstract types; mapping callsites + docstrings + log strings updated.
- `reventless/reventless-infra/src/types/ExtensionMapping.res` — `Call('msg => promise<unit>, 'msg)` → `HandleDirective(Reventless.Handler.handler<'directive>, 'directive)` on `incomingCommandAction`, `outgoingCommandAction`; `AbstractCall(...)` → `AbstractHandleDirective(...)` on both abstract types; mapping callsites + docstrings + log strings updated.

Framework dispatch:
- `reventless/reventless-core/src/components/ExtensionPoint/ExtensionPoint_Callback.res` — pattern + error string.
- `reventless/reventless-core/src/components/ExtensionPoint/ExtensionPoint_Operations.res` — pattern + error string.
- `reventless/reventless-core/src/components/Extension/Extension_Operations.res` — `let handle` → `let handleDirective`; patterns + error string.

Framework admin usage:
- `reventless/reventless-core/src/admin/PluginExtensionPoint_Plugin.res` — local `let callHandler` binding → `let directiveHandler`; 8 `Call(callHandler, …)` callsites → `HandleDirective(directiveHandler, …)`.

Tests:
- `reventless/reventless-core/tests/extensionpoint/ExtensionPointFixtures.res` — `TestEPSpec.CallHandler({...})` test command → `TestEPSpec.TriggerDirective({...})` (semantically clearer); `AbstractCall(...)` → `AbstractHandleDirective(...)`.
- `reventless/reventless-core/tests/extensionpoint/ExtensionPointCallbackTest.res` — describe strings + `CallHandler` → `TriggerDirective` references.
- `reventless/reventless-core/tests/extensionpoint/ExtensionPointOperationsTest.res` — describe strings + comment + `AbstractCall(...)` → `AbstractHandleDirective(...)`.

**GWT touch points the original audit missed** (caught by build):
- `reventless/reventless-gwt/src/Delegate_GWT.res` — 4 sites (2 × `EPMapping.Call(_, _)`, 2 × `ExtMapping.Call(_, _)`) → `HandleDirective(_, _)`.
- `reventless/reventless-gwt/src/Flow_GWT.res` — 2 sites (1 × `EPMapping.Call`, 1 × `ExtMapping.Call`) → `HandleDirective(_, _)`.

**Validation**
- `pnpm run build` — clean, zero warnings.
- `pnpm test` — 195 suites / 1501 tests pass.
- Sweep grep for `\| Call(`, `AbstractCall`, `callHandler`, `calling handler`, `Call directive` — zero remaining hits in `reventless/`, `examples/`, `packages/` source (excluding build artefacts under `lib/ocaml/` and `lib/bs/`, which regenerate, and the unrelated `CommandTopic_Helpers.callHandlerWithArray` value binding).

**Docs touched**: none. The only doc-side hits were in an in-progress plan (`docs/plans/plugin-eventcollector-runtime-rewire-cross-plugin.md`) that documents a separate migration's historical state — left untouched. Published docs under `packages/doc/docs/` had no hits on the old terminology.
