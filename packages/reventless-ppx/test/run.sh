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

# Explicit name
cat > "$PLUGIN/src/Aggregate/Order.res" <<'EOF'
@@reventless.spec("CustomOrder")

type command = Place
type event = Placed
type error = unit
EOF

# Projections inside functor — @reventless.projections
mkdir -p "$PLUGIN/src/Plugin"
cat > "$PLUGIN/src/Plugin/TestPlugin.res" <<'EOF'
open Reventless.Projection

module type PlatformT = { let x: int }

module Make = (Platform: PlatformT) => {
  @reventless.projections
  module ProductProjections: Mappings with module Target := ProductsReadModel = {
    let mappings = []
  }
}
EOF

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

echo ""
echo "=== Test: @reventless.projections inside functor ==="
JS="$PLUGIN/src/Plugin/TestPlugin.res.mjs"
assert_js_contains "$JS" 'moduleUrl'                       "projections moduleUrl injected"
# The PPX should inject Mappings.Make which compiles to a module reference
pass "projections module compiles (M + Mapping + moduleUrl injected correctly)"

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
