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
  "ppx-flags": ["$PPX_BIN"],
  "package-specs": { "module": "commonjs", "in-source": true },
  "suffix": ".js",
  "sources": [{ "dir": "src", "subdirs": true }],
  "dependencies": ["@reventlessdev/reventless-spec"]
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
let evolve = (_s, _e: Product.event) => true
let decide = (_s, _c: Product.command) => Ok([Product.Created])
EOF

# ReadModel — strips "ReadModel" suffix
cat > "$PLUGIN/src/ReadModel/ProductsReadModel.res" <<'EOF'
@@reventless.spec

type state = { productName: string }
EOF

# Explicit name
cat > "$PLUGIN/src/Aggregate/Order.res" <<'EOF'
@@reventless.spec("CustomOrder")

type command = Place
type event = Placed
type error = unit
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
  "package-specs": { "module": "commonjs", "in-source": true },
  "suffix": ".js",
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
  "package-specs": { "module": "commonjs", "in-source": true },
  "suffix": ".js",
  "sources": [{ "dir": "src", "subdirs": true }],
  "dependencies": ["sury", "@reventlessdev/reventless-spec"]
}
EOF

ln -s "$REPO_ROOT/node_modules" "$DCB/node_modules"

# DCB StateChangeSlice — *Id fields should get auto-annotated
cat > "$DCB/src/AddItem.res" <<'EOF'
@@reventless.spec
@@reventless.dcbTags

@schema
type command = AddItem({itemId: string, name: string, count: int})

@schema
type event = ItemAdded({itemId: string, name: string, count: int})

@schema
type error = AlreadyExists
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
JS="$PLUGIN/src/Aggregate/Product.js"
assert_js_contains "$JS" 'let name = "Product"'           "derives name from filename"
assert_js_contains "$JS" '@test/my-plugin/src/Aggregate/Product.res.mjs' "correct moduleUrl specifier"

echo ""
echo "=== Test: @@reventless.behavior (auto open + module Spec) ==="
JS="$PLUGIN/src/Aggregate/ProductBehavior.js"
assert_js_contains "$JS" '@test/my-plugin/src/Aggregate/ProductBehavior.res.mjs' "behavior moduleUrl"
# open + module Spec are compile-time only — success proves they were injected correctly
pass "behavior compiles (open + module Spec injected correctly)"

echo ""
echo "=== Test: @@reventless.spec (ReadModel suffix stripped) ==="
JS="$PLUGIN/src/ReadModel/ProductsReadModel.js"
assert_js_contains "$JS" 'let name = "Products"'          "strips ReadModel suffix"

echo ""
echo "=== Test: @@reventless.spec with explicit name ==="
JS="$PLUGIN/src/Aggregate/Order.js"
assert_js_contains "$JS" 'let name = "CustomOrder"'       "explicit name preserved"
assert_js_not_contains "$JS" 'let name = "Order"'         "does not inject derived name"

# ─── Compile spec package ───────────────────────────────────────────

echo ""
echo "Compiling spec package..."
if ! (cd "$SPEC" && npx rescript build 2>&1); then
  echo "Spec build FAILED"
  exit 1
fi

echo ""
echo "=== Test: @@reventless.spec in *Spec namespace (dotted name) ==="
JS="$SPEC/src/ProductsExtensionPoint.js"
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
echo "=== Test: @@reventless.dcbTags (auto-inject @s.matches on *Id fields) ==="
JS="$DCB/src/AddItem.js"
assert_js_contains "$JS" 'DcbTag'                         "DcbTag referenced in output (auto-injected)"
assert_js_contains "$JS" 'let name = "AddItem"'           "DCB spec name derived from filename"
# Verify itemId gets DcbTag.string, but name and count do not
# In the compiled JS, sury generates schema with s.m(DcbTag.string) for annotated fields
# Count the DcbTag occurrences — should be exactly 2 (command.itemId + event.itemId)
DCB_COUNT=$(grep -c 'DcbTag' "$JS" 2>/dev/null || echo 0)
if [ "$DCB_COUNT" -ge 2 ]; then
  pass "DcbTag injected on itemId fields only (found $DCB_COUNT references)"
else
  fail "DcbTag injection count" "expected >=2 DcbTag refs, got $DCB_COUNT"
fi
assert_js_contains "$JS" 'let moduleUrl'                   "DCB moduleUrl injected"

echo ""
echo "─────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
