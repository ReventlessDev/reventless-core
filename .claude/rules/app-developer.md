# App Developer Guidelines

## Plugin Isolation

- Never import directly from another plugin's source code
- Use **spec packages** for extension point type definitions
- Cross-plugin communication flows through ExtensionPoint and Extension components only

## Naming Conventions

- **Aggregates:** singular nouns (Product, Order, Customer)
- **Read models / views:** plural nouns (Products, Orders, Customers)
- **Commands:** imperative (Add, UpdateName, PlaceOrder)
- **Events:** past tense (Added, NameUpdated, OrderPlaced)
- **Extension points:** dotted names ("Catalog.Products", "Ordering.Orders")
- **Plugin namespaces:** `{Plugin}Plugin` (CatalogPlugin)
- **Spec namespaces:** `{Plugin}Spec` (CatalogSpec)

### File naming

The folder supplies the kind; the spec file never carries a kind suffix; body files always use `<SpecStem>_<KindWord>.res` with an underscore.

| Folder | Spec file | Body file(s) |
|---|---|---|
| `Aggregate/` | `<Entity>.res` | `<Entity>_Behavior.res`, `<Entity>_Mappings.res`† |
| `StateChangeSlice/` | `<Slice>.res` | `<Slice>_Behavior.res` |
| `StateViewSlice/` | `<Name>.res` | `<Name>_Projection.res` |
| `StateViewSliceStream/` | `<Name>.res` | `<Name>_Projection.res` |
| `ReadModel/` | `<Plural>.res` | `<Plural>_Projections.res` |
| `ReadModelStream/` | `<Plural>.res` | `<Plural>_Projections.res` |
| `AutomationSlice/` | `<Slice>.res` | `<Slice>_Automation.res` (process + per-source mappings inline) |
| `InboundTranslationSlice/` | `<Slice>.res` | `<Slice>_Translation.res` |
| `OutboundTranslationSlice/` | `<Slice>.res` | `<Slice>_Translation.res` |
| `Extension/` | — | `<Name>_Extension.res` |
| `ExtensionPoint/` | `<Name>_ExtensionPoint.res` | `<Name>_ExtensionPointMapping.res` |
| `Task/` | `<Name>.res` | — |

† only when EventMappings exist for that aggregate.

**Stem uniqueness:** within one plugin, every `.res` filename stem must be unique across folders. The plugin generator emits an error naming both files when it finds a collision (e.g. an Aggregate `ProductDemand.res` next to a ReadModel `ProductDemand.res` — rename the ReadModel to `ProductDemands.res`). The body-file singular/plural distinction (`_Projection` vs `_Projections`) is meaningful: one function vs a list of mappings.

## PPX Annotations

### File-level

- `@@reventless.spec` — on all spec files (aggregates, read models, extension points, slices, tasks). Auto-injects `let name`, `module Id`, `let moduleUrl`. Derives name from filename (strips component suffixes like `_ReadModel`, `_ExtensionPoint`, `_Behavior`, etc.). In `*Spec` namespaces, auto-prefixes with plugin name for dotted EP names. For files inside a `ReadModel/` (or `ReadModelStream/`) folder declaring `@schema type state` without a `let config`, also auto-injects `open Reventless.ReadModel; let config = config(); let subIdConfig = None`. For files inside a `StateViewSlice/` (or `StateViewSliceStream/`) folder, also auto-injects `open Reventless.Projection` (brings `Set`, `Update`, `UpdateWithDefault`, `Delete` into scope) and `let config = config(); let subIdConfig = None`. For files inside an `ExtensionPoint/` folder (or whose stem ends `_ExtensionPointMapping`), also auto-injects `open ReventlessInfra.ExtensionPointMapping` (brings `PublishEvent`, `PublishCommand`, `PublishEventAsync`, `Call` into scope). In `@@reventless.spec`-annotated files, any `module Delegate` is auto-transformed (injects `module Id`, `@schema type command = unit`, dcbTags on `*Id` event fields, `@schema type error = unit`, `let moduleUrl`).
- `@@reventless.spec("ExplicitName")` — same, with explicit name override
- `@@reventless.behavior` — on all behavior files (`*_Behavior.res`). Auto-injects `open Spec`, `module Spec = Spec`, `let moduleUrl`. Derives spec module from filename (strips `_Behavior` suffix).
- `@@reventless.behavior(SpecName)` — same, with explicit spec module name
- `@@reventless.mappings` — on `*_Mappings.res` (Aggregate event-mapping siblings) and `*_Projections.res` (multi-source ReadModel mappings). Infers domain from folder (`Aggregate/` → `Reventless.EventMapping`; `ReadModel/` or `ReadModelStream/` → `Reventless.Projection`; `AutomationSlice/` → `Reventless.AutomationSlice`). Injects `open <Domain>` (and `open Reventless.Message` for projections), `module Target = <Spec>`, `module M = <Domain>.Mappings.Make(Target)`, `module type Mapping = M.Mapping`, `let moduleUrl`. Inside the file, scans inner modules: for any `module X = { ... }` with both `let name = "..."` and `@schema type event`, treats it as a DCB Source — injects `module Id = Reventless.Id.String` (if absent) and applies the dcbTag transform on the event type's `*Id` fields. The user writes `let mappings: array<module(Mapping)> = [...]` and the per-source `Mapping.Make` modules.
- `@@reventless.automation` — on `*_Automation.res`. Existing classic injections (`open Spec`, `module Spec = Spec`, `let moduleUrl`) PLUS the same `Mappings.Make` wrapper as above (since the merged file holds both `process` and per-source `Mapping.Make` modules) PLUS the same Source-module scan.
- `@@reventless.extension` — on `Extension/<Name>_Extension.res`. Injects `open ReventlessInfra.ExtensionMapping`; applies the `Delegate` auto-transform inside the file's `Mapping` module (same as ExtensionPointMapping files).
- `@@reventless.task` — on `Task/<Name>.res`. Injects `let name = "<Filename>"` from the filename stem if absent, `let moduleUrl` if absent, and `open Reventless` if absent.
- `@@reventless.visibility(Public | Internal)` — file-level visibility hint on ReadModel and StateViewSlice files only. Defaults to `Public`. `Internal` hides the component from the AutoUI manifest (panels + pages) and surfaces `x-reventless-visibility: "Internal"` on the generated JSON Schema for external consumers; GraphQL exposure, authorization, resolver provisioning, and `pluginStructure.queryableDef` are unaffected — visibility is a UX hint, not a security boundary. Rejected on Aggregate / `*Slice` (non-query) files with a clear compile error. Auto-injected `let visibility = Reventless.Visibility.Public` is added to spec files by default; the attribute overrides it. `Internal` cases require manual `let visibility: Reventless.Visibility.t = Public` on hand-written inline spec modules that live INSIDE function/builder bodies (the PPX only walks top-level inline modules — same constraint as `let authorization`).
- `@@reventless.async` — file-level opt-in to async command dispatch on Aggregate spec files (`Aggregate/<Name>.res`) and StateChangeSlice spec files (`StateChangeSlice/<Name>.res`). Default is sync: `Platform.Aggregate.Make` / `Platform.StateChangeSlice.Make` render an inline-dispatch Lambda that returns `CommandAccepted` or `CommandRejected` to the AppSync mutation. With this attribute, the plugin generator emits `MakeAsync` instead, routing the component to a FIFO-backed Lambda that returns `CommandPending` (fire-and-forget). The PPX consumes the attribute so it doesn't reach the ReScript compiler; the generator reads the raw `.res` source and flips the emitted factory. Async aggregates land in a separate `AllAggregatesAsync` Lambda; async StateChangeSlices share a per-plugin `<Plugin>StateChangesAsync` Lambda (sync slices go to `<Plugin>StateChanges`). Both async Lambdas are only created when at least one component opts in — sync-only setups don't pay the extra Lambda cost. Pick async for high-contention writes, long-running command handlers, or callers that already poll Subscription.onX for the outcome. Tune the four command-handler Lambdas independently via `Platform.MakeWithConfig`'s `commandHandlerConfig` field (memory, timeout, reserved concurrency, SQS batch size, ephemeral `/tmp`, log retention, env vars); see `docs/guides/lambda-deployment.md` § 10.
- `@@reventless.systemCallable` — file-level opt-in on StateChangeSlice and StateViewSlice (incl. Stream) spec files marking the component's GraphQL fields as deploy-time IAM (SigV4) callable in addition to Cognito. Generator-read from raw source (like `@@reventless.async`): threaded as `~systemCallableComponents` on the generated `Platform.Plugin.make`, sets `systemCallable: true` on the component's mutation/query schema entries, and the AWS provider emits the multi-auth `@aws_cognito_user_pools(...) @aws_iam` directive on those fields (all other fields keep single-mode `@aws_auth`). Opt in only for fields a deploy-time system caller actually invokes and scope the IAM principal per `docs/guides/appsync-iam-system-caller.md`.

### GWT (test) files

- `@@reventless.gwt` — on GWT test files. Auto-injects `open <Spec>` + `include ReventlessGwt.<Kind>_GWT.Make(<Spec>)`. `<Kind>` derived from the folder path (innermost segment wins) or filename, sharing the path vocabulary of `@@reventless.spec`: short folder names `StateChange` / `StateView` / `Automation` / `InboundTranslation` / `OutboundTranslation` map to `…Slice`; long `…Slice` and plural `…Slices` forms are recognised directly; filename substrings containing `Projection` or `Behavior` match their respective DSLs. Spec resolution order: (1) first top-level local module in the file → injection site is directly after that module; (2) otherwise the filename stem with `_GWT` / `GwtTest` / `Gwt` stripped — Spec is treated as an external module reference and the `open` + `include` are prepended to the top of the file. Canonical form is `{SpecModule}_GWT.res` in a slice folder with zero payload. **Companion fixtures auto-open:** when a sibling `<Stem>_Fixtures.res` exists on disk (`<Stem>` = GWT filename with `_GWT` / `GwtTest` / `Gwt` stripped), the PPX also emits `open <Stem>_Fixtures` between the Spec open and the include — fixture identifiers read unqualified in the test body. Manual `open <Stem>_Fixtures` is deduped. The companion rule keys off the filename stem regardless of payload, so `@@reventless.gwt(OtherSpec)` on `AddCategory_GWT.res` still auto-opens `AddCategory_Fixtures.res`.
- `@@reventless.gwt(SpecModule)` — explicit Spec. Treated as an external module reference — does NOT need to be a local binding; the compiler resolves it at the generated `include`.
- `@@reventless.gwt(SpecModule, BehaviorModule)` — Behavior DSL form (two-arg `Behavior_GWT.Make` functor). Zero-arg form picks the first two top-level modules in declaration order.

### DCB tag inference

- `@@reventless.dcbTags` — explicit opt-in for files outside `*Slice/` folders. Files inside any `*Slice/` folder (StateChangeSlice, StateViewSlice, AutomationSlice, InboundTranslationSlice, OutboundTranslationSlice) get dcbTags automatically via `@@reventless.spec`. Auto-injects `@s.matches(Reventless.DcbTag.string)` on: `*Id: string` scalar fields; element types of `*Id: array<string>` fields (singular name — tag key matches the field name `*Id`). For element types of `*Ids: array<string>` fields the trailing `s` is auto-stripped — the PPX emits `@s.matches(Reventless.DcbTag.stringForKey(~key="<*Id>"))` so plural-named multi-value fields share a tag key with their singular-named producers (e.g. `productIds` → tag key `productId`). Fine-grained control via field annotations (work in any `@@reventless.spec`/`@@reventless.behavior` file): `@partitionTag` marks the DCB partition key field when a variant has multiple `*Id` fields; `@crossPartition` (no payload, mirrors `@partitionTag`) marks a tag whose single-tag decision read must cross *all* partitions carrying it (a secondary-tag read) — the PPX emits `@s.matches(Reventless.DcbTag.crossPartition)`, the read routes to the per-tag `tag_<key>` GSI (`KEYS_ONLY` → `Query` keys + `BatchGet`/`GetItem` payloads), and the tag's consistency fence is bumped by *every* carrier (primary or secondary); default scope is partition-scoped, and the scope must agree across every event type carrying the key. **In practice `@crossPartition` is rarely hand-written:** cross-entity *reference* reads (a slice reading another entity's lifecycle by its id, e.g. `categoryId`) are **inferred** from the plugin's slice graph (`DcbScopeInference`, threaded by `Dcb_Builder` into both the decision-query read scope and the per-event write tags); reserve explicit `@crossPartition` for the case inference can't see — an **M:N capacity** read where a slice reads its *own* event type by a secondary key across all partitions (course-subscription capacity, "≤ N orders per product"). A `@crossPartition` the framework resolves as the slice's own partition is flagged as a contradiction; `@partitionTag` is still required on multi-`*Id` events (storage partition is not yet inferred); `@noTag` suppresses auto-tagging on a `*Id` field that is payload data, not a DCB key; `@dcbTag` explicitly tags a field that does not follow `*Id` naming (e.g. `sku`, `slug`); `@dcbTag("explicitKey")` carries a string payload that overrides the tag key (works on both `string` and `array<string>` — emits `DcbTag.stringForKey(~key="explicitKey")`); `@compositePartitionTag` (or `@compositePartitionTag("sep")`) marks a `string` field as one segment of a multi-field composite partition key — fields are joined in **declaration order**; the PPX assigns sequential positions and injects `@s.matches(DcbTag.compositePartitionMember(~position=N, ~sep="S"))`; requires ≥ 2 annotated fields and cannot be combined with `@partitionTag`. **Syntax: place these annotations BEFORE the field name** (`@partitionTag orderId: string`), not after the colon (`orderId: @partitionTag string`) — the ppx reads them from `pld_attributes` (field-level), not `ptyp_attributes` (type-level).

### Inner-module attributes

- `@reventless.delegate` — explicit opt-in for `Delegate`-like modules outside `*ExtensionPointMapping*` / `Extension/*_Extension.res` files. In `@@reventless.spec`-annotated `*ExtensionPointMapping*` files and `@@reventless.extension`-annotated extension files, the `Delegate` module is auto-transformed without this attribute.

### Schema annotations

- `@schema` on all serializable types (command, event, error, state)
- **`@schema type state` field annotations** (ReadModel and StateViewSlice files with `@@reventless.spec`):
  - `@id` / `@compositeId` — designate partition key field(s); generate `let makeId`
  - `@subId` / `@compositeSubId` — designate sort key field(s); generate `let subIdConfig`
  - `@index` / `@index("name")` / `@index({name: "name", projection: "KEYS_ONLY"})` — designate GSI key fields; generate `let config` with index entries. Record form supports: `name` (index name), `projection` (`"ALL"` default, `"KEYS_ONLY"`, `"INCLUDE"`), `fields` (array of strings for `INCLUDE` — note: `include` is reserved), `group` + `authTable` (AppSync authorization). Named `@index` paired with `@indexSubId("name")` for GSI sort key.
  - `@indexSubId("name")` — designate GSI sort key field(s) for the named index
  - `@resolves({table: "TableName", field: "fieldName"})` — cross-table single-ID resolver; generates `config.idResolvers` entry. Optional record keys: `via` (index name), `plugin`, `sourceSubId`, `subIdArg`.
  - `@resolvesMany({table: "TableName", field: "fieldName"})` — cross-table multi-ID resolver on `array<string>` fields; generates `config.idsResolvers` entry. Optional: `plugin`.
  - Note: `~to`/`~as` are ReScript reserved words; `@resolves`/`@resolvesMany` use **record** payload syntax `({key: "value"})`, NOT labeled-arg syntax

### PPX ordering

PPX ordering in `rescript.json`: `"ppx-flags": ["@reventlessdev/reventless-ppx/bin", "sury-ppx/bin"]` (reventless-ppx before sury-ppx).

## Idempotency

Commands that would produce no state change should return `Ok([])`, not an error. This is important because commands may be retried due to at-least-once delivery.

## Architecture Decision

Before adding a new entity, evaluate against `docs/guides/aggregate-vs-dcb-decision-guide.md`. Cross-entity consistency needs → DCB. Self-contained lifecycle → Aggregate.
