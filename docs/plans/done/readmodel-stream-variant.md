# ReadModelStream variant — live updates for classic ReadModels

## Problem

On the deployed `online-shop-hybrid` (alpha), registering a customer returns
`CommandAccepted` and the row lands in DynamoDB (a reload shows it), but the
AutoUI customer list does **not** live-update.

Root cause: live updates (AppSync Events "Source B") are driven by a
`StateTopic_AppSync` Lambda that tails a **DynamoDB Stream** on the read model's
QueryDb table. That Lambda is only created in `Platform.res`'s
`subscriptionInfraHook` for QueryDbs registered in
`QueryDbStorage_DynamoDbStream.streamRegistry` — which is populated only by the
**stream-enabled** storage maker.

- Classic `ReadModel` → `Platform.ReadModel.Make` → `ReadModel_Builder_Single` →
  `QueryDbStorage.DynamoDb` (**no stream**) → no StateTopic Lambda → no publish.
- Plain `StateViewSlice` → `StateViewSlice_Builder` → also no stream.
- Only `StateViewSliceStream` and `Counter` get streams.

DCB slices can opt into streaming via the `StateViewSliceStream/` folder, but
classic aggregate-projection **ReadModels have no streaming variant at all**.

Verified against deployed alpha (<account-id> / eu-west-1): the only StateTopic
Lambdas are `ProductsStateTopicLambda` and `ProductDemandStateTopicLambda` (the
two catalog `StateViewSliceStream` components). No Customers/Orders/etc.

## Decision

Add a `ReadModelStream/` folder variant, exactly parallel to
`StateViewSliceStream/`: same spec/projection files, opt-in via folder name,
keeps live updates an explicit (cost-conscious) choice. Apply it to the hybrid
example so every AutoUI list refreshes live (Customers + Orders +
AvailableProducts).

Rejected: stream-all-by-default (reverses the documented "plain is cheaper"
trade-off, adds a Lambda to every read model); annotation opt-in (same PPX cost,
less consistent with the existing folder convention).

## Touchpoints

1. **PPX** (`packages/reventless-ppx/src/ppx/Util.ml`):
   - `is_in_readmodel_folder` → prefix-match a path segment starting with
     `ReadModel` (covers `ReadModel`, `ReadModels`, `ReadModelStream`,
     `ReadModelStreams`) — mirrors `is_stateview_filename`'s prefix approach.
   - `is_readmodel_filename` folder check → same prefix match.
   - `dsl_kind_of_segment` → map `ReadModelStream`/`ReadModelStreams` to
     `MultiSourceProjection` (so moved `_GWT.res` tests still infer the DSL).
   - Rebuild **both** `ppx-osx-x64.exe` and `ppx-linux.exe`.
2. **reventless-infra** (`src/types/Platform.res`): add `module ReadModelStream`
   to `Platform.T` (same signature as `ReadModel`).
3. **reventless-aws**: new `ReadModel_Builder_Single_Stream.res` (clone of
   `ReadModel_Builder_Single` using `QueryDbStorage_DynamoDbStream`); add
   `module ReadModelStream` to `Platform.res`.
4. **reventless-in-memory** (`src/Platform.res`): add `module ReadModelStream`
   aliasing `ReadModelMaker` (no streams in-memory — identical to ReadModel).
5. **Generator** (`reventless-spec/src/generator/`):
   - `Discovery.res`: `ReadModelStream` componentType + folder mapping.
   - `Pairing.res`: add `stream: bool` to `readModelDef`; classify
     `ReadModelStream` files (specs flagged `stream:true`, projections collected
     alongside ReadModel projections).
   - `Codegen.res`: `renderReadModels` emits `Platform.ReadModelStream.Make` when
     `stream`, else `Platform.ReadModel.Make`. All other read-model wiring
     (make-params, pluginStructure, uiFragments) treats streamed read models
     identically.
6. **Example** (`online-shop-hybrid/ordering`): `git mv`
   - `src/Customer/ReadModel` → `src/Customer/ReadModelStream` (+ tests)
   - `src/Order/StateViewSlice` → `src/Order/StateViewSliceStream` (+ tests)
   - `src/CatalogProduct/StateViewSlice` → `.../StateViewSliceStream` (+ tests)
   - Regenerate `Plugin.res`, rebuild, re-stage `.res.mjs`.
7. **Docs**: `platform-and-plugin-guide.md` (ReadModelStream section),
   `appsync-events-live-updates.md` (read-model streaming note),
   `.claude/rules/app-developer.md` naming table.

## Status — COMPLETE

- [x] PPX edits + binary rebuild (both `ppx-osx-x64.exe` + `ppx-linux.exe`)
- [x] reventless-infra Platform.T (`module ReadModelStream` + `ReadModelComponentT` alias)
- [x] reventless-aws builder (`ReadModel_Builder_Single_Stream.res`) + `Platform.ReadModelStream` module
- [x] reventless-in-memory alias
- [x] generator (Discovery/Pairing/Codegen — `stream` flag on `readModelDef`)
- [x] example folder moves + regenerate (`Plugin.res` now emits `Platform.ReadModelStream.Make` for Customers, `Platform.StateViewSliceStream.Make` for Orders/AvailableProducts)
- [x] build green + zero warnings; ordering (55) + platform-in-memory flow (3) tests pass
- [x] docs (platform guide ReadModelStream section, live-updates opt-in note, naming table)

### Notes / out of scope

- **Deploy required:** the fix is server-side. A redeploy of `online-shop-hybrid`
  creates the `CustomersStateTopicLambda`; the host-shell already subscribes on
  the `Ordering_Customers` list field, so live updates start working with no UI
  change.
- **Pre-existing failures (NOT caused by this work):**
  - `reventless-codegen` forward golden test: 2 `dilger` fixtures drift on
    `package.json` — the emitter writes `version: "0.0.0"` but the last release
    commit bumped the committed fixtures to `1.0.0-alpha.29`. Predates this work.
  - `reventless-in-memory` suite: 65 `TypeError: Uuid.v4 is not a function`
    failures — environmental (`import('uuid').v4` is `undefined` even in plain
    node at repo root). Unrelated to this change.
- Catalog's `Categories` / `CatalogActivity` read models were intentionally left
  query-only (not in agreed scope).
