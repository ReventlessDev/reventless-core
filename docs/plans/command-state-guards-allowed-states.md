# Command state guards: `allowedStates` + `statusField`

Scope: let AutoUI hide commands that the backend would reject due to the
entity's current state. First production use case: Plugin `Activate`
shouldn't appear next to a `Connected` plugin; `Deactivate` shouldn't
appear next to an `Inactive` one. Sweep examples for parity.

Approach: declarative metadata pipeline.
- Each `commandDef` gains `allowedStates: option<array<string>>` — `None`
  → always show; `Some([...])` → show iff row's status ∈ the set.
- Each `queryableDef` gains `statusField: option<string>` so AutoUI knows
  which row field to read. Spec author declares it (`Some("status")`),
  or PPX infers it from a `@status`-annotated state field.

## Workstreams

### A — Type + SDL pipeline

| Step | File | Change |
|---|---|---|
| A.1 | `reventless-spec/src/components/Plugin.res` | Add `allowedStates: option<array<string>>` to `commandDef`. Add `statusField: option<string>` to `queryableDef`. |
| A.2 | `reventless-core/src/admin/Platform_UIDefinitionsApi.res` | SDL: `Platform_UICommandDef` gets `allowedStates: [String!]`; `Platform_UIReadSideDef` gets `statusField: String`. `encodeCommandDef` + `encodeQueryableDef` emit the new fields (nullable string array / string). |
| A.3 | `reventless-core/tests/admin/Platform_UIDefinitionsApiTest.res` | Add cases: `null` allowedStates encodes as `[]` or null per SDL nullability choice; populated array round-trips; `statusField` round-trips. |

### B — PPX support

| Step | File | Change |
|---|---|---|
| B.1 | `packages/reventless-ppx/src/ppx/StateAnnotations.ml` | New `@status` field-level attribute (no payload). Mirror `@id` helpers. Error on duplicate `@status` annotations within the same state record. |
| B.2 | new `packages/reventless-ppx/src/ppx/AllowedStatesAnnotation.ml` | Per-variant `@allowedStates([Status1, Status2])` attribute whose **payload is an expression list of status-type constructors**, not a string list. The PPX (a) extracts each constructor's leaf identifier as a string for the metadata payload, and (b) emits a synthetic `let _ = StatusModule.Status1` witness binding at module top per referenced constructor so the compiler errors at the original site if a constructor is misspelled, renamed, or removed. The same witness shape works for both payloadless and payload variants: a payloadless constructor is a value, a payload constructor is an unapplied function — both are valid right-hand sides of a `let _ =` binding, so the PPX never needs to know the variant's arity. Supports both qualified (`OrdersStatus.Submitted`) and bare (`Submitted`, when the type is in scope) forms. Final emitted binding is unchanged in shape: `let commandSchema = ReventlessInfra.Api.markAllowedStates(commandSchema, [|("V1", [|"Submitted"; "Shipped"|]); ...|])`. |
| B.3 | `reventless-core/src/components/Api/Api.res` (or wherever `markNoApiVariants` lives) | New `markAllowedStates` helper attaching the mapping to schema metadata. New `getAllowedStates(commandSchema, ~variantName)` for codegen consumers. |
| B.4 | `packages/reventless-ppx/src/bin/bin.ml` | Wire the new attribute handler into the pipeline. |
| B.5 | `packages/reventless-ppx/lib/ppx-macos.exe`, `ppx-linux.exe` | Rebuild both binaries. Linux rebuild via Docker per existing PPX workflow. |

### C — Codegen + hand-rolled population

| Step | File | Change |
|---|---|---|
| C.1 | `reventless-core/src/components/Plugin/Plugin_Structure.res` | `toCommandDef` reads `getAllowedStates(commandSchema, ~variantName)` and populates `allowedStates`. |
| C.2 | `reventless-core/src/components/Plugin/Plugin_Structure.res` | Read model `queryableDef` builders populate `statusField` via resolution order: (1) field with explicit `@status` annotation; (2) field literally named `status`; (3) `None`. Mirrors how `@displayName`/`labelField` falls back to a conventionally-named string field. The convention is convenience only — an explicit `@status` on any other field shadows the implicit `status`-by-name match. |
| C.3 | `reventless-core/src/admin/Platform_Admin_Structure.res` | Hand-rolled `activateCommand` gets `allowedStates: Some(["Inactive"])`. `deactivateCommand` gets `allowedStates: Some(["Connected", "Disconnected"])`. `pluginReadModel` gets `statusField: Some("status")`. Hand-rolled `commandDef` literals stay string-based (no PPX expansion happens at value-construction sites — only on PPX-driven aggregate command type declarations). |

### D — Consumer impact (out of scope here)

AutoUI in the host-shell needs to read the two new metadata fields and
apply a per-row filter to the command menu: keep a command iff its
`allowedStates` is `None` OR the row's tag for the read model's
`statusField` ∈ `allowedStates`. When `statusField` is `None`, the
filter is a no-op (back-compat).

Note: the row's status value may serialize as either a JSON string (for
payloadless variants — sury's default) or an object with a `TAG`
property (for payload variants). The consumer-side filter needs a tiny
helper that normalises both shapes to a tag string before comparing
against `allowedStates`. Tracked in the UI-repo plan.

That consumer change is tracked in its own plan in the UI repo and
ships in a separate `@reventlessdev/reventless-host-shell` /
`@reventlessdev/reventless-ui` release once A–C land here.

### E — Example sweep

| Step | File | Change |
|---|---|---|
| E.1 | `examples/online-shop-aggregates/ordering/src/Aggregate/Order.res` | Annotate `@allowedStates([Submitted])` on `ShipOrder`, `@allowedStates([Submitted])` on `CancelOrder`, etc. — payload is the actual status-type constructors, qualified if the type lives in a sibling module (e.g. `Orders.Submitted`). Add `@status` on the Orders read model state field. |
| E.2 | `examples/online-shop-dcb/...` | Equivalent for DCB Order if status-modeled there. |
| E.3 | Smoke-check the online-shop-hybrid platform — confirm the relevant Order rows show only the commands allowed for their current status. |

### F — Documentation

The new annotations join the existing AutoUI-affecting set (`@id`, `@subId`, `@displayName`, `@dcbTag`, etc.). Today these are documented per-annotation in `docs/guides/reventless-ppx.md` and referenced in passing from the AutoUI section of `docs/guides/platform-and-plugin-guide.md`, but there's no single place that maps "AutoUI behavior X → annotation that controls it". This workstream adds both the per-annotation reference entries and a consolidated AutoUI-side write-up.

| Step | File | Change |
|---|---|---|
| F.1 | `docs/guides/reventless-ppx.md` | New per-annotation entries for `@status` (field-level, no payload — marks the lifecycle status field on a read model state record; resolution falls back to a field literally named `status`; duplicate annotations error) and `@allowedStates` (per-variant on aggregate commands; payload is an expression list of status-type constructors; PPX emits witness bindings for compile-time existence checks; supports payloadless and payload variants uniformly). Mirror existing entries in shape — what-it-injects table, examples, edge cases. |
| F.2 | `docs/guides/platform-and-plugin-guide.md` (existing "AutoUI" section, around line 1504) | New subsection titled "Annotations that shape Auto UI" (or similar) consolidating: (a) `@displayName` for list-view labels, (b) `@id`/`@subId` for entity addressing, (c) `@status` + `@allowedStates` for command filtering, (d) `@dcbTag` for ID-typing in mutation args. Each entry is one paragraph linking to the per-annotation detail in `reventless-ppx.md`. Goal: a developer skim-reading the platform guide can see all AutoUI-affecting annotations in one place. |
| F.3 | Cross-link the new section from the existing `## AutoUI` heading anchor so the platform guide's table of contents (line 41) points at it. |

## Acceptance

- Plugin admin list: `...` menu on a Connected row shows only `Deactivate`. Same row after Deactivate shows only `Activate`.
- Online-shop-hybrid Orders list: shipped row hides `ShipOrder`/`CancelOrder`; submitted row shows all three.
- `Platform_UIDefinitions` GraphQL query returns the two new fields without breaking existing clients (they're additive + nullable).
- No regression in `pnpm test` for core, in-memory, or codegen forward tests.
- Zero PPX warnings; both PPX binaries rebuilt.
- `docs/guides/reventless-ppx.md` and `docs/guides/platform-and-plugin-guide.md` updated; Docusaurus build (`pnpm --filter ./packages/doc run build`) succeeds with no broken links.

## Risks

- **Inference correctness for the `@status` annotation.** If a read model has multiple status-like fields, the PPX needs to error on duplicate `@status` annotations rather than silently picking one. Mirror `@id`'s duplicate-detection.
- **Conventional `status`-by-name match (C.2).** A field literally named `status` is treated as the lifecycle status field even without an annotation. A spec that uses `status` for an unrelated purpose (HTTP code, feedback flag, etc.) and has no other status field will be incorrectly classified — the workaround is to add `@status` to the *actual* lifecycle field (the convention is shadowed by any explicit annotation), or rename the non-lifecycle field. Acceptable risk because the convention follows established `@displayName`/`@id` precedent; flag in changelog so existing specs can audit.
- **Codegen sync with hand-rolled `Platform_Admin_Structure`.** When the Plugin aggregate's behavior changes which states allow Activate/Deactivate, both the PPX-driven path and the hand-rolled Platform_Admin entry must update together.
- **Coupling to status field naming.** `statusField` lets the spec author override "status", but the *value* still has to be a string (no enum decoding on the UI side). That matches today's `status` schema; flag if a spec ever uses non-string status.
- **What `@allowedStates([Variant])` does and doesn't verify.** The witness binding catches: (a) typo in constructor name; (b) renamed/removed constructor at any use site. It does NOT verify that the listed constructors belong to the *correct* type (the one referenced by the read model's `statusField`) — cross-file type checking would need analysis that ReScript's PPX doesn't provide. A future enhancement could add a runtime assertion at platform start that re-validates each `allowedStates` array against the corresponding read model's status-field schema; deferred until the simpler form has proven useful.

## Release ordering

1. Land workstreams A–C + E + F in `reventless-core` on `alpha`. Push → semantic-release publishes new alpha. New metadata fields ship but are inert (no consumer yet); guides describe the dev experience so app authors can start annotating ahead of the UI release.
2. UI-side consumer change (tracked separately) ships in a subsequent
   `@reventlessdev/reventless-host-shell` / `@reventlessdev/reventless-ui` alpha.
3. Core bumps the host-shell dep to that new alpha; consumers get the filter end-to-end.
