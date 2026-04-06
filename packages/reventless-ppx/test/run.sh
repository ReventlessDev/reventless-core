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
      @noTag orderId: string,
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
assert_js_not_contains "$JS" 'noTag'     "@noTag: field attr stripped"
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
echo "=== Test: @dcbTag injects DcbTag.string on non-*Id field ==="
JS="$DCB/src/SkuCatalog.res.mjs"
assert_js_contains    "$JS" 'DcbTag'    "@dcbTag: DcbTag referenced for non-*Id field"
assert_js_not_contains "$JS" 'dcbTag'   "@dcbTag: field attr stripped"

echo ""
echo "=== Test: slice folder — slice-layer suffix View still stripped ==="
JS="$PLUGIN/src/StateView/ProductsView.res.mjs"
assert_js_contains "$JS" 'let name = "Products"'  "View suffix still stripped inside slice folder"

echo ""
echo "─────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
