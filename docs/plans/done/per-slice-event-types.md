# Per-Slice Event Types (DCB Event Type Decoupling)

**Analysis**: `docs/analysis/dcb-event-type-coupling.md` (Option B)
**Status**: Done
**Breaking**: Yes — all existing slice specs and plugin DcbSpecs were updated

## Goal

Decouple DCB slices from the shared event log union type. Each slice declares its own `producedEvent` and `consumedEvent` types instead of referencing a monolithic `DcbEventLogSpec.event`. Consumed events are structural projections — they may be payload-less, carry a field subset, or use the full shape. The framework validates compatibility at build time and runtime.

---

## Step 1: DcbValidation module in reventless-spec — DONE

**Files**: `reventless/reventless-spec/src/components/DcbValidation.res`

Validation rules implemented:
1. Payload equivalence across producers (field names, types, tag annotations)
2. Every consumed event has a producer
3. Consumed fields exist in produced shape (payload-less always valid)
4. Type compatibility between consumed and produced field types

Handles single payload-less variant schemas (`String({const})`) correctly.

**Tests**: `reventless/reventless-core/tests/dcb/DcbValidationTest.res` — 12 tests passing.

- [x] Implement `DcbValidation.validateProducedAndConsumed`
- [x] Unit tests for payload equivalence across multiple producers
- [x] Unit tests for consumed-without-producer detection
- [x] Unit tests for field subset validation (including payload-less)
- [x] Unit tests for type compatibility checks

---

## Step 2: Consumed event decode path with payload-less support — DONE

**Files**: `reventless/reventless-spec/src/components/DcbDecode.res`

Decoder handles:
- Payload-less variants: TAG match only, constructs value via `S.parseJsonOrThrow` on bare string
- Partial projections: sury parse with field subset (extra fields ignored)
- Full shape: standard sury parse
- Single payload-less variant: handles `String({const})` schema (not just Union)
- Unknown event types: returns `None`

**Tests**: `reventless/reventless-core/tests/dcb/DcbDecodeTest.res` — 10 tests passing.

- [x] Implement `DcbDecode.makeDecoder`
- [x] Handle payload-less variants (TAG match only, no sury)
- [x] Handle single payload-less variants (`String({const})` schema)
- [x] Handle field-subset variants (sury parse with extra field tolerance)
- [x] Unit tests: payload-less decode, partial projection decode, full shape decode, unknown event skip

---

## Step 3: Update slice spec types — DONE

**Files changed**:
- `reventless/reventless-spec/src/components/StateChangeSlice.res` — `producedEvent` + `consumedEvent` replace `module DcbEventLogSpec`
- `reventless/reventless-spec/src/components/StateViewSlice.res` — `consumedEvent` replaces `module DcbEventLogSpec` + `type event`
- `reventless/reventless-spec/src/components/AutomationSlice.res` — `consumedEvent` replaces `module DcbEventLogSpec`
- `reventless/reventless-spec/src/components/OutboundTranslationSlice.res` — `consumedEvent` replaces `module DcbEventLogSpec`
- `reventless/reventless-spec/src/components/InboundTranslationSlice.res` — removed `module DcbEventLogSpec`
- `reventless/reventless-spec/src/components/DcbEventLog.res` — removed `@schema type event`

- [x] Update all spec types

---

## Step 4: Update T module types and builders — DONE

**Infra layer** (`reventless/reventless-infra/src/`):
- `DcbEventLog.res` — unparameterized `operations` with raw event types (`rawEvent`, `rawSequencedEvent`, `rawReadResult`)
- All slice T module types — removed `type dcbEvent` and `dcbEventLogComponent`, `make` takes `DcbEventLog.component` directly
- `Plugin.res` — `DcbSpec` removed `type event`, arrays now `array<module(StateChangeSlice.T)>` etc.
- `types/Platform.res` — removed all `with type dcbEvent` from Make functors

**Core layer** (`reventless/reventless-core/src/`):
- `DcbEventLog_Operations.res` — simplified to raw event pass-through with EventTopic publishing
- `StateChangeSlice_Callback.res` — uses `DcbDecode.makeDecoder` for consumed events, encodes produced events locally with `Spec.producedEventSchema`
- `StateViewSlice_Callback.res` — decodes raw events with consumed event schema via DcbDecode
- AutomationSlice, OutboundTranslation, InboundTranslation builders/callbacks — same pattern
- All slice `_Builder.res` and `.res` files — removed `type dcbEvent`

- [x] All infra and core builder/callback files updated

---

## Step 5: Update Dcb_Builder — schema merge and validation wiring — DONE

- `Dcb_Builder.res` — removed `DcbSpec.event`, removed `with type dcbEvent = DcbSpec.event` from all module unpacking, wired `DcbValidation.validateProducedAndConsumed`, collects event schemas from `producedEventSchema`
- `DcbEventLog_Builder.res` — works without typed event union, uses raw operations

- [x] Validation wired into Dcb_Builder.construct
- [x] DcbEventLog operations use raw types

---

## Step 6: Update InMemory provider — DONE

- `Platform.res` — removed all `with type dcbEvent` constraints from Make functors
- `DcbEventLog_Builder.res` — updated for unparameterized operations
- `StateChangeSlice_Builder.res` — updated `~dcbEventLog` parameter type
- Validation runs via Dcb_Builder.construct (same code path as AWS)

- [x] InMemory platform updated
- [x] All 248 in-memory tests pass

---

## Step 7: Update example applications — DONE

**Catalog plugin** (12 files):
- 8 StateChangeSlices: producedEvent (full shape + tags) + consumedEvent (payload-less or partial)
- 2 StateViewSlices: consumedEvent only (fields needed for projection)
- 1 InboundTranslationSlice: removed DcbEventLogSpec only
- CatalogEventLog.res: reduced to just `moduleUrl`
- CatalogPlugin.res: removed `type event`, removed `with type dcbEvent`

**Ordering plugin** (15 files):
- 7 StateChangeSlices, 3 StateViewSlices, 1 AutomationSlice, 1 OutboundTranslationSlice
- OrderingEventLog.res: reduced to just `moduleUrl`
- OrderingPlugin.res: same simplification

**Hybrid examples**: updated to match

- [x] All example slices migrated
- [x] All example plugin files updated

---

## Step 8: Validation tests — DONE

Framework-level validation tests in `DcbValidationTest.res` (12 tests) cover:
- Consumed fields not in produced shape
- Consumed events with no matching producer
- Payload divergence across multiple producers of the same TAG
- Type mismatches
- Payload-less consumed variants (always valid)
- Multiple producers with identical shapes (valid)

Per-plugin validation tests deferred — the Dcb_Builder already runs validation at construction time, which surfaces errors during both `npm test` (InMemory) and `pulumi up` (AWS).

- [x] Framework validation tests
- [ ] Per-plugin one-line validation tests (optional, deferred)

---

## Step 9: Update AWS adapter — DONE

- `Platform.res` — removed `with type dcbEvent` from StateChangeSlice Make
- `StateChangeSlice_Builder.res` — removed `with type dcbEvent`
- `StateViewSlice_Builder_Bundled.res` — removed `type dcbEvent`, `type dcbEventLogComponent`
- `AutomationSlice_Builder_Bundled.res` — same
- `OutboundTranslationSlice_Builder_Bundled.res` — same
- AWS runtime entry points: compile with new spec types

- [x] All AWS adapter files updated
- [x] Builds successfully

---

## Step 10: Documentation — DEFERRED

Not yet updated. Documentation changes are mechanical follow-up work.

- [ ] Update component docs
- [ ] Update platform-and-plugin-guide
- [ ] Update inner-workings documentation
- [ ] Add consumed event projection pattern guide

---

## Step 11: Cleanup — DONE

- [x] `DcbEventLog.Spec.event` removed
- [x] `dcbEvent` type removed from all T module types
- [x] Zero new warnings (only pre-existing warning 3 for deprecated `Exn.raiseError`)
- [x] Full test suite: 252 (reventless-core) + 248 (reventless-in-memory) = 500 tests passing
- [x] Full build succeeds across all packages

---

## Summary of key files added/changed

**New files:**
- `reventless-spec/src/components/DcbValidation.res` — produced/consumed schema validation
- `reventless-spec/src/components/DcbDecode.res` — consumed event decoder (payload-less, partial, full)
- `reventless-core/tests/dcb/DcbValidationTest.res` — 12 validation tests
- `reventless-core/tests/dcb/DcbDecodeTest.res` — 10 decode tests

**Key architectural changes:**
- `DcbEventLog.operations` — unparameterized, works with raw `{eventType, data, tags}` events
- `StateChangeSlice_Callback` — encodes produced events locally, decodes consumed events via DcbDecode
- `StateViewSlice_Callback` / `AutomationSlice_Callback` — decode raw EventTopic events via DcbDecode
- `Dcb_Builder` — collects and validates schemas from all slices at construction time
