#!/usr/bin/env bash
# Integration tests for reventless-ppx.
# Creates mini ReScript packages, compiles them through the PPX,
# and verifies the generated JS output matches expectations.
#
# Usage: ./test/run.sh
# Requires: node, npx (rescript and sury must be available)

set -euo pipefail
cd "$(dirname "$0")/.."

PASS=0
FAIL=0
PPX_BIN="$(pwd)/bin"
REPO_ROOT="$(cd ../.. && pwd)"

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1: $2"; FAIL=$((FAIL + 1)); }

assert_js_contains() {
  local file="$1" pattern="$2" label="$3"
  if grep -q "$pattern" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label" "expected '$pattern' in $(basename "$file")"
  fi
}

assert_js_not_contains() {
  local file="$1" pattern="$2" label="$3"
  if grep -q "$pattern" "$file" 2>/dev/null; then
    fail "$label" "unexpected '$pattern' in $(basename "$file")"
  else
    pass "$label"
  fi
}

# ─── Setup temp workspace ───────────────────────────────────────────

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# ─── Fixture: plugin package (has reventless-spec dependency) ───────

PLUGIN="$TMPDIR/plugin"
mkdir -p "$PLUGIN/src/Aggregate" "$PLUGIN/src/ReadModel"

cat > "$PLUGIN/package.json" <<'EOF'
{ "name": "@test/my-plugin" }
EOF

cat > "$PLUGIN/rescript.json" <<EOF
{
  "name": "@test/my-plugin",
  "namespace": "TestPlugin",
  "ppx-flags": ["$PPX_BIN", "sury-ppx/bin"],
  "package-specs": { "module": "esmodule", "in-source": true },
  "suffix": ".res.mjs",
  "sources": [{ "dir": "src", "subdirs": true }],
  "dependencies": ["sury", "@reventlessdev/reventless-spec"]
}
EOF

ln -s "$REPO_ROOT/node_modules" "$PLUGIN/node_modules"

# Spec file — no @schema needed, just test PPX injections
cat > "$PLUGIN/src/Aggregate/Product.res" <<'EOF'
@@reventless.spec

type command = Create
type event = Created
type error = unit
EOF

# Behavior file
cat > "$PLUGIN/src/Aggregate/ProductBehavior.res" <<'EOF'
@@reventless.behavior

type state = bool
let initialState = false
let evolve = (_s, _e: event) => true
let decide = (_s, _c: command) => Ok([Created])
EOF

# ReadModel — strips "ReadModel" suffix, auto-injects ReadModel defaults
cat > "$PLUGIN/src/ReadModel/ProductsReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = { productName: string }
EOF

# Authorization injection — per-constructor @authorize plus file-level default
cat > "$PLUGIN/src/Aggregate/Category.res" <<'EOF'
@@reventless.spec
@@reventless.authorize(AllowGroups(["Catalog"]))

@schema
type command =
  | Add({name: string})
  | Rename({name: string})
  | @authorize(AllowGroups(["Admin"])) Archive

@schema
type event =
  | Added({name: string})
  | Renamed({name: string})
  | Archived

@schema
type error = unit
EOF

# Explicit name
cat > "$PLUGIN/src/Aggregate/Order.res" <<'EOF'
@@reventless.spec("CustomOrder")

type command = Place
type event = Placed
type error = unit
EOF

# Note: `@reventless.projections` was retired — projection mappings now live
# in slice-local `<Plural>_Projections.res` files with `@@reventless.mappings`
# (covered by the multi-source ReadModel fixture below).

# ─── Fixture: spec package (no reventless-spec, namespace ends in Spec) ──

SPEC="$TMPDIR/spec"
mkdir -p "$SPEC/src"

cat > "$SPEC/package.json" <<'EOF'
{ "name": "@test/my-spec" }
EOF

cat > "$SPEC/rescript.json" <<EOF
{
  "name": "@test/my-spec",
  "namespace": "CatalogSpec",
  "ppx-flags": ["$PPX_BIN"],
  "package-specs": { "module": "esmodule", "in-source": true },
  "suffix": ".res.mjs",
  "sources": [{ "dir": "src", "subdirs": true }],
  "dependencies": []
}
EOF

ln -s "$REPO_ROOT/node_modules" "$SPEC/node_modules"

# EP spec — derives "Catalog.Products" from CatalogSpec namespace
cat > "$SPEC/src/ProductsExtensionPoint.res" <<'EOF'
@@reventless.spec

type command = unit
type event = ProductAdded
type directive = unit
EOF

# ─── Build PPX ──────────────────────────────────────────────────────

# ─── Fixture: DCB package (tests @@reventless.dcbTags) ──────────────

DCB="$TMPDIR/dcb"
mkdir -p "$DCB/src"

cat > "$DCB/package.json" <<'EOF'
{ "name": "@test/my-dcb" }
EOF

cat > "$DCB/rescript.json" <<EOF
{
  "name": "@test/my-dcb",
  "namespace": "TestDcb",
  "ppx-flags": ["$PPX_BIN", "sury-ppx/bin"],
  "package-specs": { "module": "esmodule", "in-source": true },
  "suffix": ".res.mjs",
  "sources": [{ "dir": "src", "subdirs": true }],
  "dependencies": ["sury", "@reventlessdev/reventless-spec", "@reventlessdev/reventless-infra"]
}
EOF

ln -s "$REPO_ROOT/node_modules" "$DCB/node_modules"

# DCB StateChangeSlice — *Id fields should get auto-annotated (explicit @@reventless.dcbTags)
cat > "$DCB/src/AddItem.res" <<'EOF'
@@reventless.spec
@@reventless.dcbTags

@schema
type command = AddItem({itemId: string, name: string, count: int, tagIds: array<string>})

@schema
type event = ItemAdded({itemId: string, name: string, count: int, tagIds: array<string>})

@schema
type error = AlreadyExists
EOF

# DCB Delegate module — @@reventless.spec auto-detects module Delegate, no @reventless.delegate needed
cat > "$DCB/src/ItemMapping.res" <<'EOF'
@@reventless.spec

module Delegate = {
  let name = "ItemCatalog"
  @schema
  type event =
    | ItemAdded({itemId: string, name: string})
    | ItemRemoved({itemId: string})
}

let mapOutgoingEvent = None
EOF

# ExtensionPointMapping — open ReventlessInfra.ExtensionPointMapping auto-injected by filename
cat > "$DCB/src/ItemExtensionPointMapping.res" <<'EOF'
@@reventless.spec

module ExtensionPoint = {
  let name = "Test.Items"
  let moduleUrl = "test"
  @schema type command = unit
  @schema type event = | ItemPublished({itemId: string})
  @schema type directive = unit
}

module Delegate = {
  let name = "ItemCatalog"
  @schema
  type event =
    | ItemAdded({itemId: string, name: string})
}

let mapIncomingCommand = (_id, _command, _meta) => []

let mapOutgoingEvent = Some((_id, event, _meta, _queryEngine) =>
  switch event {
  | Delegate.ItemAdded({itemId, name: _}) => [
      PublishEvent(itemId, ExtensionPoint.ItemPublished({itemId: itemId})),
    ]
  }
)
EOF

# Phase 8 + 9: file in StateChangeSlice/ folder — dcbTags auto-applied;
# *Id: array<string> and *Ids: array<string> also annotated on inner element
mkdir -p "$DCB/src/StateChangeSlice"
cat > "$DCB/src/StateChangeSlice/TransferItems.res" <<'EOF'
@@reventless.spec

@schema
type command = Transfer({fromId: string, toId: string,
  productId: array<string>, itemIds: array<string>})

@schema
type event = Transferred({fromId: string, toId: string,
  productId: array<string>, itemIds: array<string>})

@schema
type error = NotFound
EOF

# @partitionTag + @noTag + @dcbTag: in a slice folder (dcbTags auto-enabled)
cat > "$DCB/src/StateChangeSlice/RecordDemand.res" <<'EOF'
@@reventless.spec

@schema
type event =
  | DemandRecorded({
      @partitionTag productId: string,
      @noDcbTag orderId: string,
    })

@schema
type command = Record({
  @partitionTag productId: string,
  orderId: string,
})

@schema
type error = unit
EOF

# @crossPartition: marks a tag as a cross-partition (secondary-tag) read, in a
# slice folder (dcbTags auto-enabled). courseId is the partition; studentId is
# cross-partition.
cat > "$DCB/src/StateChangeSlice/SubscribeStudent.res" <<'EOF'
@@reventless.spec

@schema
type command = Subscribe({
  @partitionTag courseId: string,
  @crossPartition studentId: string,
})

@schema
type event =
  | StudentSubscribed({
      @partitionTag courseId: string,
      @crossPartition studentId: string,
    })

@schema
type error = unit
EOF

# Slice file whose name ends in a top-level-only suffix (Plugin)
# Entity name must retain the suffix
cat > "$DCB/src/StateChangeSlice/SyncPlugin.res" <<'EOF'
@@reventless.spec

@schema
type command = Sync
@schema
type event = Synced
@schema
type error = unit
EOF

# @noDcbTag: suppresses auto-tagging on *Id field that is not a DCB key
cat > "$DCB/src/StateChangeSlice/OrderPlacement.res" <<'EOF'
@@reventless.spec

@schema
type command = PlaceOrder({orderId: string, @noDcbTag customerId: string})
@schema
type event = OrderPlaced({@partitionTag orderId: string, customerId: string})
@schema
type error = unit
EOF

# @ref: cross-entity reference annotation in a slice folder (dcbTags auto-on).
# - scalar @ref keeps DCB-tag semantics with the field name as the tag key
# - plural *Ids array @ref must singularise the tag key (productIds → productId)
#   so it shares a key with singular-named producers (Reference.to_ ~key)
# - @ref + @noDcbTag drops the DCB tag (toWithoutDcbTag), so no key is emitted
cat > "$DCB/src/StateChangeSlice/OrderPicker.res" <<'EOF'
@@reventless.spec

@schema
type command = Pick({
  @partitionTag orderId: string,
  @ref("Customer") customerId: string,
  @ref("AvailableProducts") productIds: array<string>,
  @ref("Warehouse") @noDcbTag warehouseIds: array<string>,
})

@schema
type event = Picked({@partitionTag orderId: string})

@schema
type error = unit
EOF

# readConsistency: @@reventless.consistency(AlwaysStrong) build-time override
cat > "$DCB/src/StateChangeSlice/ConsistencyStrong.res" <<'EOF'
@@reventless.spec
@@reventless.consistency(AlwaysStrong)

@schema
type command = Bump({widgetId: string})
@schema
type event = Bumped({widgetId: string})
@schema
type error = unit
EOF

# @dcbTag: outside a slice folder (no dcbTags auto-enabled), non-*Id field name
cat > "$DCB/src/SkuCatalog.res" <<'EOF'
@@reventless.spec
@@reventless.dcbTags

@schema
type event =
  | SkuAdded({
      @dcbTag sku: string,
      name: string,
    })
EOF

# @dcbTag("explicitKey"): payload form remaps the tag key on a non-*Id field.
# Also covers an array<string> body: @dcbTag("productId") productSkus: array<string>.
cat > "$DCB/src/SkuRemap.res" <<'EOF'
@@reventless.spec
@@reventless.dcbTags

@schema
type event =
  | ScalarRemapped({
      @dcbTag("productSku") sku: string,
      name: string,
    })
  | ArrayRemapped({
      @dcbTag("productId") productSkus: array<string>,
    })
EOF

# StateView slice — View suffix should still be stripped inside slice folder
mkdir -p "$PLUGIN/src/StateView"
cat > "$PLUGIN/src/StateView/ProductsView.res" <<'EOF'
@@reventless.spec

@schema
type state = { count: int }
EOF

# ─── Fixture: @subId on ReadModel ──────────────────────────────────

cat > "$PLUGIN/src/ReadModel/VersionedReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = { itemId: string, @subId version: string, data: string }
EOF

# ─── Fixture: @compositeSubId on ReadModel ─────────────────────────

cat > "$PLUGIN/src/ReadModel/CompositeReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = {
  itemId: string,
  @compositeSubId region: string,
  @compositeSubId date: string,
  value: float,
}
EOF

# ─── Fixture: @compositeSubId with custom sep ─────────────────────

cat > "$PLUGIN/src/ReadModel/CustomSepReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = {
  itemId: string,
  @compositeSubId(":") tenantId: string,
  @compositeSubId location: string,
  data: string,
}
EOF

# ─── Fixture: no sub-ID annotation → subIdConfig = None ──────────

# (ProductsReadModel.res already defined above — has no @subId)

# ─── Fixture: StateViewSlice with @subId ──────────────────────────

mkdir -p "$PLUGIN/src/StateViewSlice"
cat > "$PLUGIN/src/StateViewSlice/TimelineView.res" <<'EOF'
@@reventless.spec

@schema
type state = { userId: string, @subId timestamp: string, action: string }

@schema
type consumedEvent = ActionPerformed({userId: string, timestamp: string, action: string})

let project = event => switch event {
  | ActionPerformed({userId, timestamp, action}) =>
    [Set(userId, {userId, timestamp, action})]
}
EOF

# ─── Fixture: standalone @index on ReadModel ─────────────────────

cat > "$PLUGIN/src/ReadModel/IndexedReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = { id: string, @index category: string, name: string }
EOF

# ─── Fixture: named @index + @indexSubId ──────────────────────────

cat > "$PLUGIN/src/ReadModel/OwnerReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = {
  id: string,
  @index("byOwner") ownerId: string,
  @indexSubId("byOwner") createdAt: string,
  name: string,
}
EOF

# ─── Fixture: no index annotations → config() empty ──────────────

# (ProductsReadModel.res above has no @index)

# ─── Fixture: @id on ReadModel ───────────────────────────────────

cat > "$PLUGIN/src/ReadModel/EntityReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = { @id entityId: string, name: string }
EOF

# ─── Fixture: @compositeId on ReadModel ──────────────────────────

cat > "$PLUGIN/src/ReadModel/CompositeKeyReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = {
  @compositeId environment: string,
  @compositeId platformName: string,
  name: string,
}
EOF

# ─── Fixture: @compositeId with custom sep ───────────────────────

cat > "$PLUGIN/src/ReadModel/CustomIdSepReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = {
  @compositeId(":") tenantId: string,
  @compositeId region: string,
  count: int,
}
EOF

# ─── Fixture: composite @index pk (2 fields → _name_pk) ──────────

cat > "$PLUGIN/src/ReadModel/CompositePkIndexReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = {
  id: string,
  @index("byRegion") countryId: string,
  @index("byRegion") regionId: string,
  name: string,
}
EOF

# ─── Fixture: composite @indexSubId sk (2 fields → _name_sk) ─────

cat > "$PLUGIN/src/ReadModel/CompositeSkIndexReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = {
  id: string,
  @index("byDate") categoryId: string,
  @indexSubId("byDate") year: string,
  @indexSubId("byDate") month: string,
  name: string,
}
EOF

# ─── Fixture: @index with KEYS_ONLY projection ───────────────────

cat > "$PLUGIN/src/ReadModel/KeysOnlyIndexReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = {
  id: string,
  @index({name: "byCategory", projection: "KEYS_ONLY"}) categoryId: string,
  name: string,
}
EOF

# ─── Fixture: @index with authorization (group + authTable) ──────

cat > "$PLUGIN/src/ReadModel/AuthIndexReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = {
  id: string,
  @index({name: "byOwner", group: "Admins", authTable: "AuthTable"}) ownerId: string,
  name: string,
}
EOF

# ─── Fixture: @index with INCLUDE projection ─────────────────────

cat > "$PLUGIN/src/ReadModel/IncludeIndexReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = {
  id: string,
  @index({name: "byTag", projection: "INCLUDE", fields: ["id", "name"]}) tagId: string,
  name: string,
}
EOF

# ─── Fixture: @resolves on ReadModel ────────────────────────────────

cat > "$PLUGIN/src/ReadModel/ResolvedReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = {
  id: string,
  @resolves({table: "Orders", field: "order"}) orderId: string,
  name: string,
}
EOF

# ─── Fixture: @resolves with via (index target) ─────────────────

cat > "$PLUGIN/src/ReadModel/IndexResolvedReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = {
  id: string,
  @resolves({table: "Products", field: "product", via: "byOwner"}) productId: string,
  name: string,
}
EOF

# ─── Fixture: @resolvesMany on ReadModel ─────────────────────────

cat > "$PLUGIN/src/ReadModel/MultiResolvedReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = {
  id: string,
  @resolvesMany({table: "Tags", field: "tags"}) tagIds: array<string>,
  name: string,
}
EOF

# ─── Fixture: @compositeId + @resolves on same type ──────────────

cat > "$PLUGIN/src/ReadModel/CompositeKeyResolvedReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = {
  @compositeId tenantId: string,
  @compositeId productId: string,
  @resolves({table: "Orders", field: "order"}) orderId: string,
  name: string,
}
EOF

# ─── Fixture: @hidden + @summary (visibility annotations) ───────

cat > "$PLUGIN/src/ReadModel/VisibilityReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = {
  @id id: string,
  @summary pluginName: string,
  @hidden deploymentId: string,
  description: string,
}
EOF

# ─── Fixture: @@reventless.visibility on ReadModel + StateViewSlice ─

# Default → visibility = Public
cat > "$PLUGIN/src/ReadModel/VisibilityDefaultReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = { @id id: string, name: string }
EOF

# @@reventless.visibility(Internal) on a ReadModel
cat > "$PLUGIN/src/ReadModel/VisibilityInternalReadModel.res" <<'EOF'
@@reventless.spec
@@reventless.visibility(Internal)

@schema
type state = { @id id: string, name: string }
EOF

# @@reventless.visibility(Internal) on a StateViewSlice
cat > "$PLUGIN/src/StateViewSlice/VisibilityInternalView.res" <<'EOF'
@@reventless.spec
@@reventless.visibility(Internal)

@schema
type state = { id: string, name: string }

@schema
type consumedEvent = Created({id: string, name: string})

let project = event => switch event {
  | Created({id, name}) => [Set(id, {id, name})]
}
EOF

# ─── Fixture: @scan + @scanSort (server-query opt-in) ─────────────

cat > "$PLUGIN/src/ReadModel/ScanReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = {
  @id id: string,
  @scan status: string,
  @scanSort name: string,
  description: string,
}
EOF

# ─── Fixture: @drillTarget + @collapsed (hierarchical rendering hints) ────

cat > "$PLUGIN/src/ReadModel/DrillReadModel.res" <<'EOF'
@@reventless.spec

@schema
type componentEntry = { kind: string, name: string }

@schema
type primaryResource = { resourceId: string, label: string }

@schema
type state = {
  @id id: string,
  @drillTarget("ResourceInventory") components: array<componentEntry>,
  @drillTarget({slice: "ResourceInventory", key: "kind/name"})
  componentsByKey: array<componentEntry>,
  @collapsed primaryResource: primaryResource,
  description: string,
}
EOF

# ─── Fixture: StateViewSlice without @subId ───────────────────────

cat > "$PLUGIN/src/StateViewSlice/SimpleView.res" <<'EOF'
@@reventless.spec

@schema
type state = { id: string, name: string }

@schema
type consumedEvent = Created({id: string, name: string})

let project = event => switch event {
  | Created({id, name}) => [Set(id, {id, name})]
}
EOF

# ─── Fixture: split-form StateViewSlice (@@reventless.projection) ──

# Spec — types only, no project function
cat > "$PLUGIN/src/StateViewSlice/SplitView.res" <<'EOF'
@@reventless.spec

@schema
type state = { id: string, count: int }

@schema
type consumedEvent = Counted({ id: string, count: int })
EOF

# Implementation — @@reventless.projection auto-injects:
#   open SplitView; module Spec = SplitView; let moduleUrl = ...
# and (because the file lives inside a StateView* folder)
#   open Reventless.Projection (so Set/Update/etc. constructors are in scope).
cat > "$PLUGIN/src/StateViewSlice/SplitView_Projection.res" <<'EOF'
@@reventless.projection

let project = (event: consumedEvent) => switch event {
  | Counted({id, count}) => [Set(id, {id: id, count: count})]
}
EOF

# Explicit Spec module name form
cat > "$PLUGIN/src/StateViewSlice/AltView.res" <<'EOF'
@@reventless.spec

@schema
type state = { id: string }

@schema
type consumedEvent = Created({ id: string })
EOF

cat > "$PLUGIN/src/StateViewSlice/AltProjection.res" <<'EOF'
@@reventless.projection(AltView)

let project = (event: consumedEvent) => switch event {
  | Created({id}) => [Set(id, {id: id})]
}
EOF

# ─── Fixture: split-form AutomationSlice (@@reventless.automation) ──

mkdir -p "$PLUGIN/src/AutomationSlice"
cat > "$PLUGIN/src/AutomationSlice/Sweep.res" <<'EOF'
@@reventless.spec

@schema
type consumedEvent = Triggered({ id: string })

@schema
type todoItem = { id: string }

@schema
type command = DoIt({ id: string })

let maxRetries = 3
let heartbeatInterval = 60
let targetName = "Doer"
EOF

cat > "$PLUGIN/src/AutomationSlice/Sweep_Automation.res" <<'EOF'
@@reventless.automation

let collect = (event: consumedEvent) => switch event {
  | Triggered({id}) => [(id, ({id: id}: todoItem))]
}
let resolve = (_event: consumedEvent) => None
let process = (id, item: todoItem) => Some((id, DoIt({id: item.id})))
EOF

# ─── Fixture: split-form InboundTranslationSlice ────────────────────

mkdir -p "$PLUGIN/src/InboundTranslationSlice"
cat > "$PLUGIN/src/InboundTranslationSlice/Hook.res" <<'EOF'
@@reventless.spec

@schema
type externalInput = { id: string, value: int }

@schema
type command = Apply({ id: string, value: int })
EOF

cat > "$PLUGIN/src/InboundTranslationSlice/Hook_Translation.res" <<'EOF'
@@reventless.translation

let translate = (input: externalInput) =>
  Ok([(input.id, Apply({id: input.id, value: input.value}))])
EOF

# ─── Fixture: split-form OutboundTranslationSlice ───────────────────

mkdir -p "$PLUGIN/src/OutboundTranslationSlice"
cat > "$PLUGIN/src/OutboundTranslationSlice/Notify.res" <<'EOF'
@@reventless.spec

@schema
type consumedEvent = Triggered({ id: string })

@schema
type outboundItem = { id: string }

@schema
type inboundCommand = Done({ id: string })
EOF

cat > "$PLUGIN/src/OutboundTranslationSlice/Notify_Translation.res" <<'EOF'
@@reventless.translation

let collect = (event: consumedEvent) => switch event {
  | Triggered({id}) => [(id, ({id: id}: outboundItem))]
}
let translate = async (id, item: outboundItem) =>
  Ok(Some((id, Done({id: item.id}))))
EOF

# ─── Fixture: @@reventless.mappings — ReadModel/<Stem>_Projections.res ──

# Source module — satisfies Reventless.Projection.Source via the spec PPX.
cat > "$PLUGIN/src/Aggregate/Source.res" <<'EOF'
@@reventless.spec

@schema
type command = Touch
@schema
type event = Touched({sourceId: string})
@schema
type error = unit
EOF

# A ReadModel target with a state schema and an explicit string @id field.
# Filename includes "ReadModel" so the @@reventless.spec PPX auto-generates
# config + subIdConfig (today's convention; renamed in Phase 3.3).
cat > "$PLUGIN/src/ReadModel/MirrorReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = { @id mirrorId: string, name: string }
EOF

# The Projections file under ReadModel/. The PPX should inject:
#   open Reventless.Projection
#   open Reventless.Message
#   module Target = MirrorReadModel
#   module M = Reventless.Projection.Mappings.Make(MirrorReadModel)
#   module type Mapping = M.Mapping
#   let moduleUrl
cat > "$PLUGIN/src/ReadModel/MirrorReadModel_Projections.res" <<'EOF'
@@reventless.mappings

module SourceMapping = Mapping.Make(
  Source,
  MirrorReadModel,
  {
    open Source
    let project = ({event, id, _}: Reventless.Message.event'<string, Source.event>) =>
      switch event {
      | Touched({sourceId}) =>
        Set(id, ({mirrorId: sourceId, name: "demo"}: MirrorReadModel.state))
      }
  },
)

let mappings: array<module(Mapping)> = [module(SourceMapping)]
EOF

# ─── Fixture: @@reventless.mappings — Aggregate/<Stem>_Mappings.res ──

# Aggregate Spec satisfying EventMapping.Source AND EventMapping.Target.
cat > "$PLUGIN/src/Aggregate/Echo.res" <<'EOF'
@@reventless.spec

@schema
type command = Send({echoId: string})
@schema
type event = Sent({echoId: string})
@schema
type error = unit
EOF

# The Aggregate _Mappings.res — uses Echo as both source and target (self-mapping).
# PPX should inject:
#   open Reventless.EventMapping
#   module Target = Echo
#   module M = Reventless.EventMapping.Mappings.Make(Echo)
#   module type Mapping = M.Mapping
#   let counter = None       (Aggregate-only)
#   let moduleUrl
cat > "$PLUGIN/src/Aggregate/Echo_Mappings.res" <<'EOF'
@@reventless.mappings

module SelfMapping = {
  module Source = Echo
  module Target = Echo
  let map = (id, event, _q) => switch event {
    | Echo.Sent(_) => [Publish(id, Echo.Send({echoId: "x"}))]
  }
}

let mappings: array<module(Mapping)> = [module(SelfMapping)]
EOF

# ─── Fixture: @@reventless.mappings — DCB Source module scan ─────────

# A Projections file with an inner "DCB Source" module (let name + @schema type event).
# The PPX should inject `module Id = Reventless.Id.String` + apply dcbTags inside.
cat > "$PLUGIN/src/ReadModel/SourceScanReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = { @id sourceScanId: string, name: string }
EOF

cat > "$PLUGIN/src/ReadModel/SourceScanReadModel_Projections.res" <<'EOF'
@@reventless.mappings

// Inner module that LOOKS like a DCB source — the PPX should auto-inject
// `module Id = Reventless.Id.String` and apply dcbTags on `*Id` event fields.
module DcbScannedSource = {
  let name = "ScannedDcbEventLog"
  @schema
  type event = | Scanned({scanId: string})
}

let mappings: array<module(Mapping)> = []
EOF

# ─── Fixture: @@reventless.automation extension — merged form ────────

# A merged AutomationSlice file with process + a per-source Mapping.Make call
# + let mappings. The PPX should inject the AutomationSlice.Mappings.Make
# wrapper alongside the existing classic injections.
cat > "$PLUGIN/src/AutomationSlice/MergedAutomation.res" <<'EOF'
@@reventless.spec

@schema
type todoItem = { mergedId: string }
@schema
type command = MergedDo({mergedId: string})

let maxRetries = 1
let heartbeatInterval = 1
let targetName = "MergedTarget"
EOF

cat > "$PLUGIN/src/AutomationSlice/MergedAutomation_Automation.res" <<'EOF'
@@reventless.automation

// Inner DCB Source — `module Id` and dcbTags should be auto-injected.
module MergedAutomationDcbSource = {
  let name = "MergedDcbEventLog"
  @schema
  type event = | Triggered({mergedId: string})
}

module FromDcb = Mapping.Make(
  MergedAutomationDcbSource,
  MergedAutomation,
  {
    open MergedAutomationDcbSource
    let collect = (event, _ctx) => switch event {
      | Triggered({mergedId}) =>
        [(mergedId, ({mergedId: mergedId}: MergedAutomation.todoItem))]
    }
    let resolve = _event => None
  },
)

let mappings: array<module(Mapping)> = [module(FromDcb)]

let process = (id, item: MergedAutomation.todoItem) =>
  Some((id, MergedDo({mergedId: item.mergedId})))
EOF

# ─── Fixture: @@reventless.extension — Extension/<Name>_Extension.res ─

mkdir -p "$DCB/src/Extension"
cat > "$DCB/src/Extension/Demo_Extension.res" <<'EOF'
@@reventless.extension

module Mapping = {
  // Inner Delegate — should get dcbTags + module Id injected by the PPX
  // (the same auto-transform spec files apply to a `module Delegate`).
  module Delegate = {
    let name = "DemoDelegate"
    @schema
    type event = | DemoEvent({demoId: string})
  }
}
EOF

# ─── Fixture: @@reventless.task — Task/<Name>.res ────────────────────

mkdir -p "$PLUGIN/src/Task"
cat > "$PLUGIN/src/Task/CleanupJob.res" <<'EOF'
@@reventless.task

let setup = (_queryEngine, _queryBucketName, _opts) =>
  ({Task.buckets: []}: Task.config)
EOF

# ─── Build PPX ──────────────────────────────────────────────────────

echo "Building PPX..."
(cd src && dune build 2>&1) || { echo "PPX build failed"; exit 1; }

# ─── Compile plugin package ─────────────────────────────────────────

echo "Compiling plugin package..."
if ! (cd "$PLUGIN" && npx rescript build 2>&1); then
  echo "Plugin build FAILED"
  exit 1
fi

echo ""
echo "=== Test: @@reventless.spec (filename-derived name) ==="
JS="$PLUGIN/src/Aggregate/Product.res.mjs"
assert_js_contains "$JS" 'let name = "Product"'           "derives name from filename"
assert_js_contains "$JS" '@test/my-plugin/src/Aggregate/Product.res.mjs' "correct moduleUrl specifier"

echo ""
echo "=== Test: @@reventless.behavior (auto open + module Spec) ==="
JS="$PLUGIN/src/Aggregate/ProductBehavior.res.mjs"
assert_js_contains "$JS" '@test/my-plugin/src/Aggregate/ProductBehavior.res.mjs' "behavior moduleUrl"
# open + module Spec are compile-time only — success proves they were injected correctly
pass "behavior compiles (open + module Spec injected correctly)"

echo ""
echo "=== Test: @authorize per-constructor + @@reventless.authorize file default ==="
JS="$PLUGIN/src/Aggregate/Category.res.mjs"
# File-level default lifted into the switch's wildcard branch
assert_js_contains "$JS" '"Catalog"'                       "@authorize: file-level default group present"
# Per-constructor rule lifted into a Archive case
assert_js_contains "$JS" '"Admin"'                         "@authorize: per-ctor Admin group present"
# Both lines refer to AllowGroups — qualified name fine, just confirm it's there
assert_js_contains "$JS" 'AllowGroups'                     "@authorize: AllowGroups constructor used"
# Generated switch retains a `command` parameter (not wildcard `_`)
assert_js_contains "$JS" 'function commandAuthorization(command)' "@authorize: switch lambda parameter"
# Sanity: @authorize attribute stripped from the AST so sury-ppx doesn't see it
assert_js_not_contains "$JS" 'authorize'                   "@authorize: attribute stripped from output"

echo ""
echo "=== Test: @@reventless.spec (ReadModel suffix stripped + defaults auto-injected) ==="
JS="$PLUGIN/src/ReadModel/ProductsReadModel.res.mjs"
assert_js_contains "$JS" 'let name = "Products"'          "strips ReadModel suffix"
assert_js_contains "$JS" 'config'                         "ReadModel config auto-injected"
assert_js_contains "$JS" 'subIdConfig'                    "ReadModel subIdConfig auto-injected"

echo ""
echo "=== Test: @@reventless.spec with explicit name ==="
JS="$PLUGIN/src/Aggregate/Order.res.mjs"
assert_js_contains "$JS" 'let name = "CustomOrder"'       "explicit name preserved"
assert_js_not_contains "$JS" 'let name = "Order"'         "does not inject derived name"

# Note: `@reventless.projections` was retired — its replacement is
# `@@reventless.mappings` covered by the multi-source ReadModel fixture below.

# ─── Compile spec package ───────────────────────────────────────────

echo ""
echo "Compiling spec package..."
if ! (cd "$SPEC" && npx rescript build 2>&1); then
  echo "Spec build FAILED"
  exit 1
fi

echo ""
echo "=== Test: @@reventless.spec in *Spec namespace (dotted name) ==="
JS="$SPEC/src/ProductsExtensionPoint.res.mjs"
assert_js_contains "$JS" 'let name = "Catalog.Products"'  "derives dotted name from namespace"
assert_js_contains "$JS" '@test/my-spec/src/ProductsExtensionPoint.res.mjs' "spec moduleUrl"

echo ""
echo "=== Test: no module Id in spec package (no reventless-spec dep) ==="
assert_js_not_contains "$JS" 'Reventless' "no Reventless reference in output"

# ─── Compile DCB package ────────────────────────────────────────────

echo ""
echo "Compiling DCB package..."
if ! (cd "$DCB" && npx rescript build 2>&1); then
  echo "DCB build FAILED"
  exit 1
fi

echo ""
echo "=== Test: @@reventless.dcbTags (*Id + *Ids auto-annotation) ==="
JS="$DCB/src/AddItem.res.mjs"
assert_js_contains "$JS" 'DcbTag'                         "DcbTag referenced in output (auto-injected)"
assert_js_contains "$JS" 'let name = "AddItem"'           "DCB spec name derived from filename"
# itemId (x2 types) + tagIds element (x2 types) + import = DcbTag refs
DCB_COUNT=$(grep -c 'DcbTag' "$JS" 2>/dev/null || echo 0)
if [ "$DCB_COUNT" -ge 4 ]; then
  pass "*Id and *Ids fields annotated (found $DCB_COUNT DcbTag refs)"
else
  fail "DcbTag injection count" "expected >=4 DcbTag refs for itemId+tagIds, got $DCB_COUNT"
fi
assert_js_contains "$JS" 'let moduleUrl'                   "DCB moduleUrl injected"

echo ""
echo "=== Test: module Delegate auto-detected via @@reventless.spec (no @reventless.delegate needed) ==="
JS="$DCB/src/ItemMapping.res.mjs"
assert_js_contains "$JS" 'DcbTag'                         "delegate: DcbTag injected on *Id event fields"
assert_js_contains "$JS" 'moduleUrl'                      "delegate: moduleUrl injected"
pass "delegate: auto-detected by module name (no @reventless.delegate attr, compiles)"

echo ""
echo "=== Test: *ExtensionPointMapping filename — open ReventlessInfra.ExtensionPointMapping auto-injected ==="
JS="$DCB/src/ItemExtensionPointMapping.res.mjs"
# PublishEvent is used without explicit open — compiles proves PPX injected the open
pass "EP mapping: compiles using PublishEvent without explicit open (PPX auto-injected)"
assert_js_contains "$JS" 'moduleUrl'                      "EP mapping: moduleUrl injected"

echo ""
echo "=== Test: Phase 8 — slice folder auto-applies dcbTags (no @@reventless.dcbTags needed) ==="
JS="$DCB/src/StateChangeSlice/TransferItems.res.mjs"
assert_js_contains "$JS" 'DcbTag'                         "slice folder: DcbTag auto-injected"
# fromId + toId each in command+event = 4 *Id refs; itemIds element in command+event = 2 more
# fromId+toId (x2 types) + productId array elems (x2 types) + itemIds array elems (x2 types)
SLICE_COUNT=$(grep -c 'DcbTag' "$JS" 2>/dev/null || echo 0)
if [ "$SLICE_COUNT" -ge 6 ]; then
  pass "slice folder: *Id scalar, *Id array, *Ids array all annotated (found $SLICE_COUNT)"
else
  fail "slice folder DcbTag count" "expected >=6 for fromId+toId+productId[]+itemIds[], got $SLICE_COUNT"
fi

echo ""
echo "=== Test: slice folder — top-level-only suffix NOT stripped (Plugin retained) ==="
JS="$DCB/src/StateChangeSlice/SyncPlugin.res.mjs"
assert_js_contains "$JS" 'let name = "SyncPlugin"'  "Plugin suffix retained inside slice folder"

echo ""
echo "=== Test: readConsistency — StateChangeSlice default is EscalateOnRetry ==="
JS="$DCB/src/StateChangeSlice/TransferItems.res.mjs"
assert_js_contains "$JS" 'readConsistency'  "slice: readConsistency binding injected"
assert_js_contains "$JS" 'EscalateOnRetry'  "slice: default readConsistency is EscalateOnRetry"

echo ""
echo "=== Test: readConsistency — @@reventless.consistency(AlwaysStrong) override ==="
JS="$DCB/src/StateChangeSlice/ConsistencyStrong.res.mjs"
assert_js_contains     "$JS" 'readConsistency'  "override: readConsistency binding present"
assert_js_contains     "$JS" 'AlwaysStrong'     "override: AlwaysStrong emitted"
assert_js_not_contains "$JS" 'EscalateOnRetry'  "override: default not emitted when overridden"
assert_js_not_contains "$JS" 'consistency'      "override: @@reventless.consistency attribute stripped"

echo ""
echo "=== Test: readConsistency — NOT injected on an Aggregate (slice-only field) ==="
assert_js_not_contains "$PLUGIN/src/Aggregate/Category.res.mjs" 'readConsistency' \
  "aggregate: readConsistency absent (field is StateChangeSlice-only)"

echo ""
echo "=== Test: @partitionTag injects DcbTag.partition; @noTag suppresses auto-tag ==="
JS="$DCB/src/StateChangeSlice/RecordDemand.res.mjs"
assert_js_contains    "$JS" 'partition'  "@partitionTag: DcbTag.partition injected"
assert_js_not_contains "$JS" 'partitionTag' "@partitionTag: field attr stripped"
# orderId ends in Id but has @noTag — should NOT appear as DcbTag.string
# productId has @partitionTag — count of 'partition' refs covers it
# orderId should not produce a 'string' schema beyond the plain S.string
assert_js_not_contains "$JS" 'noDcbTag'  "@noDcbTag: field attr stripped"
# Check orderId is NOT tagged: no DcbTag.string ref for orderId
# (partition ref covers productId; orderId must not add another DcbTag ref)
PARTITION_COUNT=$(grep -c 'DcbTag' "$JS" 2>/dev/null || echo 0)
if [ "$PARTITION_COUNT" -ge 1 ]; then
  pass "@partitionTag: DcbTag referenced in output"
else
  fail "@partitionTag DcbTag count" "expected >=1 DcbTag refs, got $PARTITION_COUNT"
fi
# Verify DcbTag.string is NOT present (orderId was suppressed, productId uses partition)
assert_js_not_contains "$JS" 'DcbTag.string' "@noTag: DcbTag.string absent (orderId suppressed)"

echo ""
echo "=== Test: @crossPartition injects DcbTag.crossPartition ==="
JS="$DCB/src/StateChangeSlice/SubscribeStudent.res.mjs"
assert_js_contains     "$JS" 'crossPartition' "@crossPartition: DcbTag.crossPartition injected"
assert_js_not_contains "$JS" 'partitionTag'   "@crossPartition: @partitionTag field attr stripped (courseId)"
# studentId ends in Id but is @crossPartition — must use crossPartition, not plain DcbTag.string
assert_js_contains     "$JS" '.partition'            "@crossPartition: courseId still DcbTag.partition"
assert_js_not_contains "$JS" 'DcbTag.string'         "@crossPartition: studentId uses crossPartition, not string"

echo ""
echo "=== Test: @noDcbTag suppresses auto-tagging on *Id field ==="
JS="$DCB/src/StateChangeSlice/OrderPlacement.res.mjs"
assert_js_not_contains "$JS" 'noDcbTag'  "@noDcbTag: annotation stripped from output"
# customerId ends in Id but has @noDcbTag — must not produce a DcbTag.string ref
# orderId has @partitionTag — produces a DcbTag.partition ref
assert_js_contains    "$JS" 'DcbTag'     "@noDcbTag: orderId still tagged via @partitionTag"
assert_js_not_contains "$JS" 'DcbTag.string' "@noDcbTag: customerId NOT tagged (suppressed)"

echo ""
echo "=== Test: @dcbTag injects DcbTag.string on non-*Id field ==="
JS="$DCB/src/SkuCatalog.res.mjs"
assert_js_contains    "$JS" 'DcbTag'    "@dcbTag: DcbTag referenced for non-*Id field"
assert_js_not_contains "$JS" 'dcbTag'   "@dcbTag: field attr stripped"

echo ""
echo "=== Test: *Ids: array<string> auto-singularises tag key via stringForKey ==="
JS="$DCB/src/StateChangeSlice/TransferItems.res.mjs"
# itemIds should be tagged via DcbTag.stringForKey(~key="itemId")
assert_js_contains "$JS" 'stringForKey' "*Ids array: stringForKey constructor emitted"
assert_js_contains "$JS" '"itemId"'      "*Ids array: singularised key 'itemId' present in output"

echo ""
echo "=== Test: @ref composes with DCB tag — scalar field-name key, plural *Ids singularised, @noDcbTag drops tag ==="
JS="$DCB/src/StateChangeSlice/OrderPicker.res.mjs"
assert_js_contains     "$JS" 'Reference'           "@ref: Reference module referenced in output"
assert_js_contains     "$JS" '"AvailableProducts"' "@ref: array ref entity 'AvailableProducts' present"
# productIds is a plural *Ids array — its DCB tag key MUST be singularised to
# productId so it correlates with singular-named producer events (the bug fix).
assert_js_contains     "$JS" '"productId"'          "@ref: plural *Ids array singularised to tag key 'productId'"
assert_js_not_contains "$JS" '"productIds"'         "@ref: plural field name NOT used as tag key"
assert_js_contains     "$JS" '"Customer"'           "@ref: scalar ref entity 'Customer' present"
# warehouseIds is @ref + @noDcbTag → toWithoutDcbTag, no DCB tag, no key override
assert_js_contains     "$JS" 'toWithoutDcbTag'      "@ref + @noDcbTag: toWithoutDcbTag emitted (no DCB tag)"
assert_js_not_contains "$JS" '"warehouseId"'        "@ref + @noDcbTag: no tag key emitted for warehouseIds"
assert_js_not_contains "$JS" 'noDcbTag'             "@ref: @noDcbTag field attr stripped"

echo ""
echo "=== Test: @dcbTag(\"key\") payload form — scalar and array<string> ==="
JS="$DCB/src/SkuRemap.res.mjs"
assert_js_contains "$JS" 'stringForKey' "@dcbTag(key): stringForKey constructor emitted"
assert_js_contains "$JS" '"productSku"'  "@dcbTag(key): scalar override key 'productSku' present"
assert_js_contains "$JS" '"productId"'   "@dcbTag(key): array override key 'productId' present"
assert_js_not_contains "$JS" 'dcbTag'    "@dcbTag(key): field attr stripped"

echo ""
echo "=== Test: slice folder — slice-layer suffix View still stripped ==="
JS="$PLUGIN/src/StateView/ProductsView.res.mjs"
assert_js_contains "$JS" 'let name = "Products"'  "View suffix still stripped inside slice folder"

echo ""
echo "=== Test: @subId on ReadModel → subIdConfig with direct accessor ==="
JS="$PLUGIN/src/ReadModel/VersionedReadModel.res.mjs"
assert_js_contains "$JS" 'subIdConfig'             "@subId: subIdConfig generated"
assert_js_contains "$JS" 'subIdField'              "@subId: subIdField present in config"
assert_js_contains "$JS" '"version"'               "@subId: field name 'version' in config"
assert_js_contains "$JS" 'getSubId'                "@subId: getSubId accessor generated"
assert_js_not_contains "$JS" '@subId'               "@subId: annotation stripped from output"
assert_js_contains "$JS" 'stateAnnotationsId'      "@subId: stateAnnotations metadata emitted"
assert_js_contains "$JS" 'subIds: \["version"\]'   "@subId: 'version' recorded in subIds array"

echo ""
echo "=== Test: @compositeSubId → subIdConfig with composite accessor ==="
JS="$PLUGIN/src/ReadModel/CompositeReadModel.res.mjs"
assert_js_contains "$JS" 'subIdConfig'             "@compositeSubId: subIdConfig generated"
assert_js_contains "$JS" '"_subId"'                "@compositeSubId: subIdField = '_subId'"
assert_js_contains "$JS" 'getSubId'                "@compositeSubId: getSubId accessor generated"
assert_js_not_contains "$JS" '@compositeSubId'     "@compositeSubId: annotation stripped from output"
assert_js_contains "$JS" 'stateAnnotationsId'      "@compositeSubId: stateAnnotations metadata emitted"
assert_js_contains "$JS" 'compositeSubIds:'        "@compositeSubId: compositeSubIds key present in metadata"

echo ""
echo "=== Test: @compositeSubId with custom sep ==="
JS="$PLUGIN/src/ReadModel/CustomSepReadModel.res.mjs"
assert_js_contains "$JS" 'subIdConfig'             "@compositeSubId(sep): subIdConfig generated"
assert_js_contains "$JS" '"_subId"'                "@compositeSubId(sep): subIdField = '_subId'"
assert_js_contains "$JS" '":"'                     "@compositeSubId(sep): custom separator ':' in output"

echo ""
echo "=== Test: no sub-ID annotation → subIdConfig = None ==="
JS="$PLUGIN/src/ReadModel/ProductsReadModel.res.mjs"
assert_js_not_contains "$JS" 'getSubId'            "no annotation: no getSubId"
# subIdConfig should be undefined (None compiles to undefined)
assert_js_contains "$JS" 'subIdConfig'             "no annotation: subIdConfig still defined"

echo ""
echo "=== Test: StateViewSlice with @subId ==="
JS="$PLUGIN/src/StateViewSlice/TimelineView.res.mjs"
assert_js_contains "$JS" 'subIdConfig'             "SV @subId: subIdConfig generated"
assert_js_contains "$JS" '"timestamp"'             "SV @subId: field name 'timestamp' in config"
assert_js_contains "$JS" 'getSubId'                "SV @subId: getSubId accessor generated"
assert_js_contains "$JS" 'let name = "Timeline"'   "SV @subId: View suffix stripped"
assert_js_not_contains "$JS" 'config()'            "SV @subId: no ReadModel config injected"
assert_js_not_contains "$JS" 'Reventless_Projection' "SV @subId: Projection auto-opened, no qualified refs"

echo ""
echo "=== Test: StateViewSlice without @subId → subIdConfig = None ==="
JS="$PLUGIN/src/StateViewSlice/SimpleView.res.mjs"
assert_js_contains "$JS" 'subIdConfig'             "SV no annotation: subIdConfig defined"
assert_js_not_contains "$JS" 'getSubId'            "SV no annotation: no getSubId"
assert_js_contains "$JS" 'let name = "Simple"'     "SV no annotation: View suffix stripped"
assert_js_not_contains "$JS" 'config()'            "SV no annotation: no ReadModel config injected"
assert_js_not_contains "$JS" 'Reventless_Projection' "SV no annotation: Projection auto-opened, no qualified refs"

echo ""
echo "=== Test: standalone @index → standalone index entry ==="
JS="$PLUGIN/src/ReadModel/IndexedReadModel.res.mjs"
assert_js_contains "$JS" 'config'                  "@index: config generated"
assert_js_contains "$JS" '"category"'              "@index: field name as index name"
assert_js_contains "$JS" '"S"'                     "@index: type_ inferred as S for string"
assert_js_contains "$JS" '"ALL"'                   "@index: projectionType ALL"
assert_js_not_contains "$JS" 'Reventless_ReadModel.index' "@index: not a field access (annotation stripped)"
assert_js_contains "$JS" 'stateAnnotationsId'      "@index: stateAnnotations metadata emitted"
assert_js_contains "$JS" 'indexes:'                "@index: indexes key present in metadata"

echo ""
echo "=== Test: named @index + @indexSubId → index with pk + sk ==="
JS="$PLUGIN/src/ReadModel/OwnerReadModel.res.mjs"
assert_js_contains "$JS" '"byOwner"'               "@index(name): index name in config"
assert_js_contains "$JS" '"ownerId"'               "@index(name): idField = ownerId"
assert_js_contains "$JS" '"createdAt"'             "@indexSubId: subIdField = createdAt"
assert_js_not_contains "$JS" 'indexSubId'          "@indexSubId: annotation stripped"
assert_js_contains "$JS" 'indexes:'                "@index(name): indexes key present in metadata"

echo ""
echo "=== Test: no @index → config() with no indexes ==="
JS="$PLUGIN/src/ReadModel/ProductsReadModel.res.mjs"
assert_js_contains "$JS" 'config'                  "no @index: config still generated"
assert_js_not_contains "$JS" 'stateAnnotationsId'  "no annotations: stateAnnotations metadata absent"

echo ""
echo "=== Test: @id on ReadModel → makeId with direct accessor ==="
JS="$PLUGIN/src/ReadModel/EntityReadModel.res.mjs"
assert_js_contains "$JS" 'makeId'                    "@id: makeId generated"
assert_js_contains "$JS" 'entityId'                  "@id: field name in accessor"
assert_js_not_contains "$JS" '@id'                    "@id: annotation stripped from output"
assert_js_contains "$JS" 'stateAnnotationsId'        "@id: stateAnnotations metadata emitted"
assert_js_contains "$JS" 'ids: \["entityId"\]'       "@id: 'entityId' recorded in ids array"
assert_js_contains "$JS" 'compositeIds: \[\]'        "@id: empty compositeIds array"

echo ""
echo "=== Test: @compositeId on ReadModel → makeId with composite accessor ==="
JS="$PLUGIN/src/ReadModel/CompositeKeyReadModel.res.mjs"
assert_js_contains "$JS" 'makeId'                    "@compositeId: makeId generated"
assert_js_contains "$JS" 'environment'               "@compositeId: first field in accessor"
assert_js_contains "$JS" 'platformName'              "@compositeId: second field in accessor"
assert_js_not_contains "$JS" '@compositeId'           "@compositeId: annotation stripped from output"
assert_js_contains "$JS" 'stateAnnotationsId'        "@compositeId: stateAnnotations metadata emitted"
assert_js_contains "$JS" 'compositeIds:'             "@compositeId: compositeIds key present in metadata"

echo ""
echo "=== Test: @compositeId with custom sep ==="
JS="$PLUGIN/src/ReadModel/CustomIdSepReadModel.res.mjs"
assert_js_contains "$JS" 'makeId'                    "@compositeId(sep): makeId generated"
assert_js_contains "$JS" '":"'                       "@compositeId(sep): custom separator ':' in output"

echo ""
echo "=== Test: composite @index pk → synthetic _name_pk + pkFields ==="
JS="$PLUGIN/src/ReadModel/CompositePkIndexReadModel.res.mjs"
assert_js_contains "$JS" '"_byRegion_pk"'             "@index composite pk: synthetic idField name"
assert_js_contains "$JS" '"countryId"'                "@index composite pk: first source field in pkFields"
assert_js_contains "$JS" '"regionId"'                 "@index composite pk: second source field in pkFields"

echo ""
echo "=== Test: composite @indexSubId sk → synthetic _name_sk + skFields ==="
JS="$PLUGIN/src/ReadModel/CompositeSkIndexReadModel.res.mjs"
assert_js_contains "$JS" '"_byDate_sk"'               "@indexSubId composite sk: synthetic subIdField name"
assert_js_contains "$JS" '"year"'                     "@indexSubId composite sk: first source field in skFields"
assert_js_contains "$JS" '"month"'                    "@indexSubId composite sk: second source field in skFields"

echo ""
echo "=== Test: @index with KEYS_ONLY projection ==="
JS="$PLUGIN/src/ReadModel/KeysOnlyIndexReadModel.res.mjs"
assert_js_contains "$JS" '"byCategory"'              "@index(KEYS_ONLY): index name in config"
assert_js_contains "$JS" '"KEYS_ONLY"'               "@index(KEYS_ONLY): KEYS_ONLY value in output"
assert_js_not_contains "$JS" '"ALL"'                 "@index(KEYS_ONLY): ALL not present"

echo ""
echo "=== Test: @index with authorization (group + authTable) ==="
JS="$PLUGIN/src/ReadModel/AuthIndexReadModel.res.mjs"
assert_js_contains "$JS" '"byOwner"'                 "@index(auth): index name in config"
assert_js_contains "$JS" '"Admins"'                  "@index(auth): group in authorization"
assert_js_contains "$JS" '"AuthTable"'               "@index(auth): tableName in authorization"

echo ""
echo "=== Test: @index with INCLUDE projection ==="
JS="$PLUGIN/src/ReadModel/IncludeIndexReadModel.res.mjs"
assert_js_contains "$JS" '"byTag"'                   "@index(INCLUDE): index name in config"
assert_js_contains "$JS" '"id"'                      "@index(INCLUDE): first included field"
assert_js_contains "$JS" '"name"'                    "@index(INCLUDE): second included field"

echo ""
echo "=== Test: @resolves → idResolverConfig generated ==="
JS="$PLUGIN/src/ReadModel/ResolvedReadModel.res.mjs"
assert_js_contains "$JS" '"Orders"'                  "@resolves: tableName in config"
assert_js_contains "$JS" '"order"'                   "@resolves: resolvedField in config"
assert_js_contains "$JS" '"orderId"'                 "@resolves: idField in source config"
assert_js_not_contains "$JS" 'resolves'              "@resolves: annotation stripped"

echo ""
echo "=== Test: @resolves with ~via → Index target ==="
JS="$PLUGIN/src/ReadModel/IndexResolvedReadModel.res.mjs"
assert_js_contains "$JS" '"byOwner"'                 "@resolves via: index name in target"
assert_js_contains "$JS" '"Products"'                "@resolves via: tableName in config"
assert_js_contains "$JS" '"productId"'               "@resolves via: idField in source config"

echo ""
echo "=== Test: @resolvesMany → idsResolverConfig generated ==="
JS="$PLUGIN/src/ReadModel/MultiResolvedReadModel.res.mjs"
assert_js_contains "$JS" '"Tags"'                    "@resolvesMany: tableName in config"
assert_js_contains "$JS" '"tags"'                    "@resolvesMany: resolvedField in config"
assert_js_contains "$JS" '"tagIds"'                  "@resolvesMany: idsField in source config"
assert_js_not_contains "$JS" 'resolvesMany'          "@resolvesMany: annotation stripped"

echo ""
echo "=== Test: @compositeId + @resolves on same type → both outputs independent ==="
JS="$PLUGIN/src/ReadModel/CompositeKeyResolvedReadModel.res.mjs"
assert_js_contains "$JS" 'tenantId'                  "@compositeId+@resolves: tenantId in makeId"
assert_js_contains "$JS" 'productId'                 "@compositeId+@resolves: productId in makeId"
assert_js_contains "$JS" '"Orders"'                  "@compositeId+@resolves: tableName in resolver config"
assert_js_contains "$JS" '"orderId"'                 "@compositeId+@resolves: idField in resolver source"
assert_js_not_contains "$JS" '@compositeId'          "@compositeId+@resolves: @compositeId annotation stripped"
assert_js_not_contains "$JS" '@resolves'             "@compositeId+@resolves: @resolves annotation stripped"

echo ""
echo "=== Test: @hidden + @summary → metadata fields populated ==="
JS="$PLUGIN/src/ReadModel/VisibilityReadModel.res.mjs"
assert_js_contains "$JS" 'stateAnnotationsId'      "@hidden/@summary: stateAnnotations metadata emitted"
assert_js_contains "$JS" 'hidden: \["deploymentId"\]' "@hidden: 'deploymentId' recorded in hidden array"
assert_js_contains "$JS" 'summary: \["pluginName"\]'  "@summary: 'pluginName' recorded in summary array"
assert_js_not_contains "$JS" '@hidden'              "@hidden: annotation stripped from output"
assert_js_not_contains "$JS" '@summary'             "@summary: annotation stripped from output"

echo ""
echo "=== Test: @scan + @scanSort → metadata fields populated ==="
JS="$PLUGIN/src/ReadModel/ScanReadModel.res.mjs"
assert_js_contains "$JS" 'stateAnnotationsId'        "@scan/@scanSort: stateAnnotations metadata emitted"
assert_js_contains "$JS" 'scan: \["status"\]'        "@scan: 'status' recorded in scan array"
assert_js_contains "$JS" 'scanSort: \["name"\]'      "@scanSort: 'name' recorded in scanSort array"
assert_js_not_contains "$JS" '@scan'                 "@scan: annotation stripped from output"
assert_js_not_contains "$JS" '@scanSort'             "@scanSort: annotation stripped from output"

echo ""
echo "=== Test: @drillTarget + @collapsed → metadata fields populated ==="
JS="$PLUGIN/src/ReadModel/DrillReadModel.res.mjs"
assert_js_contains "$JS" 'stateAnnotationsId'              "@drillTarget/@collapsed: stateAnnotations metadata emitted"
assert_js_contains "$JS" 'drillTargets:'                   "@drillTarget: drillTargets key present in metadata"
assert_js_contains "$JS" 'drillTargetKeys:'                "@drillTarget: drillTargetKeys key present in metadata"
assert_js_contains "$JS" '"components"'                    "@drillTarget short form: 'components' field name recorded"
assert_js_contains "$JS" '"componentsByKey"'               "@drillTarget record form: 'componentsByKey' field name recorded"
assert_js_contains "$JS" '"ResourceInventory"'             "@drillTarget: slice name 'ResourceInventory' recorded"
assert_js_contains "$JS" '"kind/name"'                     "@drillTarget(key): 'kind/name' key path recorded"
assert_js_contains "$JS" 'collapsed: \["primaryResource"\]' "@collapsed: 'primaryResource' recorded in collapsed array"
assert_js_not_contains "$JS" '@drillTarget'                "@drillTarget: annotation stripped from output"
assert_js_not_contains "$JS" '@collapsed'                  "@collapsed: annotation stripped from output"

echo ""
echo "=== Test: @@reventless.projection (split-form StateViewSlice) ==="
JS="$PLUGIN/src/StateViewSlice/SplitView_Projection.res.mjs"
assert_js_contains "$JS" 'StateViewSlice/SplitView_Projection.res.mjs' "projection moduleUrl"
# open Spec + module Spec are compile-time only — successful compile proves
# they were injected (the project body references `consumedEvent` and `Set`
# which are only in scope after `open SplitView` and `open Reventless.Projection`)
pass "projection compiles (open Spec + module Spec injected; _Projection suffix stripped from filename)"

echo ""
echo "=== Test: @@reventless.projection(Spec) explicit name ==="
JS="$PLUGIN/src/StateViewSlice/AltProjection.res.mjs"
assert_js_contains "$JS" 'StateViewSlice/AltProjection.res.mjs' "explicit-spec projection moduleUrl"
pass "projection with explicit Spec module name compiles"

echo ""
echo "=== Test: @@reventless.automation (split-form AutomationSlice) ==="
JS="$PLUGIN/src/AutomationSlice/Sweep_Automation.res.mjs"
assert_js_contains "$JS" 'AutomationSlice/Sweep_Automation.res.mjs' "automation moduleUrl"
pass "automation compiles (open Spec + module Spec injected; _Automation suffix stripped)"

echo ""
echo "=== Test: @@reventless.translation (split-form InboundTranslationSlice) ==="
JS="$PLUGIN/src/InboundTranslationSlice/Hook_Translation.res.mjs"
assert_js_contains "$JS" 'InboundTranslationSlice/Hook_Translation.res.mjs' "inbound translation moduleUrl"
pass "inbound translation compiles (sync translate function)"

echo ""
echo "=== Test: @@reventless.translation (split-form OutboundTranslationSlice) ==="
JS="$PLUGIN/src/OutboundTranslationSlice/Notify_Translation.res.mjs"
assert_js_contains "$JS" 'OutboundTranslationSlice/Notify_Translation.res.mjs' "outbound translation moduleUrl"
pass "outbound translation compiles (sync collect + async translate)"

echo ""
echo "=== Test: @@reventless.mappings (ReadModel/<Stem>_Projections.res) ==="
JS="$PLUGIN/src/ReadModel/MirrorReadModel_Projections.res.mjs"
assert_js_contains "$JS" 'ReadModel/MirrorReadModel_Projections.res.mjs' "mappings (RM): moduleUrl injected"
pass "mappings (RM): file compiles — open Reventless.Projection + module Target/M/Mapping injected"

echo ""
echo "=== Test: @@reventless.mappings (Aggregate/<Stem>_Mappings.res) ==="
JS="$PLUGIN/src/Aggregate/Echo_Mappings.res.mjs"
assert_js_contains "$JS" 'Aggregate/Echo_Mappings.res.mjs' "mappings (Aggr): moduleUrl injected"
pass "mappings (Aggr): file compiles — open Reventless.EventMapping + module Target/M/Mapping + counter=None injected"

echo ""
echo "=== Test: @@reventless.mappings — DCB Source module scan injects module Id + dcbTags ==="
JS="$PLUGIN/src/ReadModel/SourceScanReadModel_Projections.res.mjs"
assert_js_contains "$JS" 'DcbTag' "Source scan: DcbTag referenced in inner Source module"

echo ""
echo "=== Test: @@reventless.automation (merged form — Mappings.Make wrapper auto-injected) ==="
JS="$PLUGIN/src/AutomationSlice/MergedAutomation_Automation.res.mjs"
assert_js_contains "$JS" 'AutomationSlice/MergedAutomation_Automation.res.mjs' "merged automation: moduleUrl injected"
assert_js_contains "$JS" 'DcbTag' "merged automation: inner DCB Source got dcbTags"
pass "merged automation: file compiles with one Mapping.Make + let mappings + process (Mappings.Make wrapper auto-injected)"

echo ""
echo "=== Test: @@reventless.extension (Extension/<Name>_Extension.res — Delegate auto-transformed) ==="
JS="$DCB/src/Extension/Demo_Extension.res.mjs"
assert_js_contains "$JS" 'Extension/Demo_Extension.res.mjs' "extension: moduleUrl injected"
assert_js_contains "$JS" 'DcbTag' "extension: inner Mapping.Delegate got dcbTags + module Id"
assert_js_contains "$JS" 'delegateModuleUrl' "extension: Mapping.delegateModuleUrl injected (lets the runtime dynamic-import the Delegate spec)"

echo ""
echo "=== Test: @@reventless.task (Task/<Name>.res — name + open + moduleUrl) ==="
JS="$PLUGIN/src/Task/CleanupJob.res.mjs"
assert_js_contains "$JS" 'let name = "CleanupJob"' "task: name derived from filename"
assert_js_contains "$JS" 'Task/CleanupJob.res.mjs' "task: moduleUrl injected"

# ─── Fixture: error package (expected to fail compilation) ──────────

ERROR="$TMPDIR/error-pkg"
mkdir -p "$ERROR/src/ReadModel"

cat > "$ERROR/package.json" <<'EOF'
{ "name": "@test/error-pkg" }
EOF

cat > "$ERROR/rescript.json" <<EOF
{
  "name": "@test/error-pkg",
  "namespace": "TestError",
  "ppx-flags": ["$PPX_BIN", "sury-ppx/bin"],
  "package-specs": { "module": "esmodule", "in-source": true },
  "suffix": ".res.mjs",
  "sources": [{ "dir": "src", "subdirs": true }],
  "dependencies": ["sury", "@reventlessdev/reventless-spec"]
}
EOF

ln -s "$REPO_ROOT/node_modules" "$ERROR/node_modules"

echo ""
echo "=== Test: PPX error — @subId + @compositeSubId on same type ==="

cat > "$ERROR/src/ReadModel/ConflictModel.res" <<'EOF'
@@reventless.spec

@schema
type state = { id: string, @subId version: string, @compositeSubId region: string }
EOF

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "@subId + @compositeSubId conflict" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "@subId and @compositeSubId cannot both appear"; then
    pass "@subId + @compositeSubId on same type → correct compile error"
  else
    fail "@subId + @compositeSubId conflict" "unexpected error output: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/ReadModel/ConflictModel.res"

echo ""
echo "=== Test: PPX error — @subId on non-string field ==="

cat > "$ERROR/src/ReadModel/NonStringModel.res" <<'EOF'
@@reventless.spec

@schema
type state = { id: string, @subId count: int }
EOF

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "@subId on non-string field" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "@subId can only be used on string fields"; then
    pass "@subId on non-string field → correct compile error"
  else
    fail "@subId on non-string field" "unexpected error output: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/ReadModel/NonStringModel.res"

echo ""
echo "=== Test: PPX error — @id + @compositeId on same type ==="

cat > "$ERROR/src/ReadModel/IdConflict.res" <<'EOF'
@@reventless.spec

@schema
type state = { @id entityId: string, @compositeId region: string }
EOF

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "@id + @compositeId conflict" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "@id and @compositeId cannot both appear"; then
    pass "@id + @compositeId on same type → correct compile error"
  else
    fail "@id + @compositeId conflict" "unexpected error output: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/ReadModel/IdConflict.res"

echo ""
echo "=== Test: PPX error — @id on non-string field ==="

cat > "$ERROR/src/ReadModel/NonStringId.res" <<'EOF'
@@reventless.spec

@schema
type state = { @id count: int, name: string }
EOF

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "@id on non-string field" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "@id can only be used on string fields"; then
    pass "@id on non-string field → correct compile error"
  else
    fail "@id on non-string field" "unexpected error output: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/ReadModel/NonStringId.res"

echo ""
echo "=== Test: PPX error — @indexSubId without matching @index ==="

cat > "$ERROR/src/ReadModel/OrphanSkReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = { id: string, @indexSubId("byOwner") createdAt: string, name: string }
EOF

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "@indexSubId without @index" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "@indexSubId.*has no matching @index"; then
    pass "@indexSubId without matching @index → correct compile error"
  else
    fail "@indexSubId without @index" "unexpected error output: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/ReadModel/OrphanSkReadModel.res"

echo ""
echo "=== Test: @@reventless.visibility default (no attr) → Public ==="
JS="$PLUGIN/src/ReadModel/VisibilityDefaultReadModel.res.mjs"
assert_js_contains "$JS" 'let visibility = "Public"' "default visibility binding is Public"

echo ""
echo "=== Test: @@reventless.visibility(Internal) on ReadModel → Internal ==="
JS="$PLUGIN/src/ReadModel/VisibilityInternalReadModel.res.mjs"
assert_js_contains "$JS" 'let visibility = "Internal"' "Internal visibility binding emitted"
assert_js_not_contains "$JS" 'reventless.visibility' "@@reventless.visibility attribute stripped"

echo ""
echo "=== Test: @@reventless.visibility(Internal) on StateViewSlice → Internal ==="
JS="$PLUGIN/src/StateViewSlice/VisibilityInternalView.res.mjs"
assert_js_contains "$JS" 'let visibility = "Internal"' "Internal visibility binding emitted on StateViewSlice"

echo ""
echo "=== Test: @@reventless.visibility(Internal) → stateAnnotations metadata carries visibility ==="
JS="$PLUGIN/src/ReadModel/VisibilityInternalReadModel.res.mjs"
assert_js_contains "$JS" 'stateAnnotationsId' "stateAnnotations binding emitted on Internal ReadModel"
assert_js_contains "$JS" 'visibility: "Internal"' "Internal visibility recorded in stateAnnotations metadata"

echo ""
echo "=== Test: default visibility → metadata omits visibility (kept compact) ==="
JS="$PLUGIN/src/ReadModel/VisibilityDefaultReadModel.res.mjs"
assert_js_contains "$JS" 'stateAnnotationsId' "stateAnnotations binding present from @id annotation"
assert_js_not_contains "$JS" 'visibility: "Public"' "Public visibility omitted from metadata (kept compact)"
assert_js_not_contains "$JS" 'visibility: "Internal"' "Internal visibility absent from default-visibility ReadModel"

echo ""
echo "=== Test: PPX error — @hidden + @summary on same field ==="

cat > "$ERROR/src/ReadModel/HiddenSummaryConflictReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = {
  id: string,
  @hidden
  @summary
  deploymentId: string,
}
EOF

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "@hidden + @summary conflict" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "@hidden and @summary cannot both appear"; then
    pass "@hidden + @summary on same field → correct compile error"
  else
    fail "@hidden + @summary conflict" "unexpected error output: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/ReadModel/HiddenSummaryConflictReadModel.res"

echo ""
echo "=== Test: PPX error — @@reventless.visibility on an Aggregate ==="

mkdir -p "$ERROR/src/Aggregate"
cat > "$ERROR/src/Aggregate/VisibilityOnAggregate.res" <<'EOF'
@@reventless.spec
@@reventless.visibility(Internal)

@schema
type command = Create
@schema
type event = Created
@schema
type error = unit
EOF

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "@@reventless.visibility on Aggregate" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "@@reventless.visibility is only supported on ReadModel and StateViewSlice"; then
    pass "@@reventless.visibility on Aggregate → correct compile error"
  else
    fail "@@reventless.visibility on Aggregate" "unexpected error output: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/Aggregate/VisibilityOnAggregate.res"

echo ""
echo "=== Test: PPX error — @@reventless.consistency on an Aggregate ==="

mkdir -p "$ERROR/src/Aggregate"
cat > "$ERROR/src/Aggregate/ConsistencyOnAggregate.res" <<'EOF'
@@reventless.spec
@@reventless.consistency(AlwaysStrong)

@schema
type command = Create
@schema
type event = Created
@schema
type error = unit
EOF

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "@@reventless.consistency on Aggregate" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "@@reventless.consistency is only supported on StateChangeSlice"; then
    pass "@@reventless.consistency on Aggregate → correct compile error"
  else
    fail "@@reventless.consistency on Aggregate" "unexpected error output: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/Aggregate/ConsistencyOnAggregate.res"

echo ""
echo "=== Test: PPX error — @noTag (old name) produces deprecation error ==="

cat > "$ERROR/src/ReadModel/OldNoTag.res" <<'EOF'
@@reventless.spec
@@reventless.dcbTags

@schema
type event = OrderPlaced({orderId: string, @noTag customerId: string})
@schema
type command = unit
@schema
type error = unit
EOF

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "@noTag deprecation" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "@noTag was renamed to @noDcbTag"; then
    pass "@noTag (old name) → correct deprecation error"
  else
    fail "@noTag deprecation" "unexpected error output: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/ReadModel/OldNoTag.res"

echo ""
echo "─────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
