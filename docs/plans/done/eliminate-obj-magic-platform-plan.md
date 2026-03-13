# Plan: Eliminate Obj.magic from Platform DcbSpec Boundaries

**Status:** Complete
**Complexity:** L2 (cross-package type hierarchy change)

## Problem

Both Platform implementations (AWS and in-memory) used `Obj.magic` to coerce `Plugin_Builder.make` and `Core_Builder.make` into `ReventlessInfra.Plugin.T` and `ReventlessInfra.Core.T` respectively. There were **4 `Obj.magic` calls**:

- `reventless-aws/src/Platform.res` — Plugin make, Core make
- `reventless-in-memory/src/Platform.res` — Plugin make, Core make

### Root Cause

The `make` functions accept `~dcbSpec: module(Plugin.DcbSpec)=?`, but `Plugin.DcbSpec` resolved to different nominal paths in reventless-core vs reventless-infra. The DcbSpec module type contains arrays of `module(StateChangeSlice.T ...)` etc., and these slice T module types differed between the two packages:

- **Infra**: Abstract `type component`, `type dcbEventLogComponent`
- **Core**: Concrete equations (`type component = Component.t<t, outputs, operations>`) + extra fields (`queryDbName`)

## Solution: Option B — Unify the T Type Hierarchies

### Approach

1. **Enrich Infra's T module types** with the concrete type equations and extra fields that Core's T types have
2. **Add phantom `type t`** to each Infra slice module (used as brand parameter in `Component.t<t, outputs, operations>`)
3. **Add `type t` and `type component<'ops>`** to Infra's DcbEventLog module (reordered types above module type T)
4. **Make Core re-export Infra's `t` types** (`type t = ReventlessInfra.X.t`) so type equations expand identically
5. **Alias Core's DcbSpec = Infra's DcbSpec** — now possible because the referenced T types are structurally identical after expansion
6. **Remove `Obj.magic`** from both Platform files

### Key Insight

The previous attempt to alias DcbSpec failed because Infra's T types were abstract — `Dcb_Builder` couldn't call `Component.outputs` on an abstract `component` type. By enriching Infra's T types with concrete equations and having Core re-export Infra's phantom `t` types, the type equations in both packages expand to the same resolved types. The module type alias then works because the inner T types are structurally identical.

### Files Changed

**Infra (reventless-infra/src/components/):**
- `DcbEventLog.res` — Reordered types above module type T; added `type t`, `type component<'ops> = Component.t<t, outputs, 'ops>`; made T.component concrete
- `StateChangeSlice.res` — Added `type t`; made T.dcbEventLogComponent and T.component concrete
- `StateViewSlice.res` — Same as StateChangeSlice
- `AutomationSlice.res` — Same + added `let queryDbName: string` to T
- `OutboundTranslationSlice.res` — Same + added `let queryDbName: string` to T
- `InboundTranslationSlice.res` — Added `type t`; made T.component concrete; added `let queryDbName: string` to T

**Core (reventless-core/src/components/):**
- `DcbEventLog/DcbEventLog.res` — `type t = ReventlessInfra.DcbEventLog.t`
- `StateChangeSlice/StateChangeSlice.res` — `type t = ReventlessInfra.StateChangeSlice.t`
- `StateViewSlice/StateViewSlice.res` — `type t = ReventlessInfra.StateViewSlice.t`
- `AutomationSlice/AutomationSlice.res` — `type t = ReventlessInfra.AutomationSlice.t`
- `OutboundTranslationSlice/OutboundTranslationSlice.res` — `type t = ReventlessInfra.OutboundTranslationSlice.t`
- `InboundTranslationSlice/InboundTranslationSlice.res` — `type t = ReventlessInfra.InboundTranslationSlice.t`
- `Plugin/Plugin.res` — `module type DcbSpec = ReventlessInfra.Plugin.DcbSpec`

**Platform files:**
- `reventless-aws/src/Platform.res` — Removed `Obj.magic` from Plugin and Core make
- `reventless-in-memory/src/Platform.res` — Removed `Obj.magic` from Plugin and Core make

### Verification

- Clean build: 0 errors, 0 warnings
- All tests pass: 94 suites, 783 tests
