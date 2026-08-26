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
PPX_DIR="$(pwd)"
# Binary the fixtures compile through. Defaults to the launcher (which resolves
# the installed per-platform package or a local build). Override with
# REVENTLESS_PPX_BIN to pin a specific binary — publish-ppx.yml's drift guard sets
# it to the just-published binary to prove it produces the same output as source.
PPX_BIN="${REVENTLESS_PPX_BIN:-$PPX_DIR/bin}"
REPO_ROOT="$(cd ../.. && pwd)"

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1: $2"; FAIL=$((FAIL + 1)); }

# ─── node_modules for the temp packages (linker-agnostic) ───────────
#
# The temp ReScript packages resolve their dependencies through a node_modules that we link
# into each one. The healthy layout is pnpm's *hoisted* linker (.npmrc → node-linker=hoisted),
# where every dep — including `sury` — sits in $REPO_ROOT/node_modules, so a single symlink to
# it is enough. But when `pnpm install` runs without NPM_TOKEN (e.g. a fork PR, where the
# project .npmrc that references ${NPM_TOKEN} is discarded), pnpm falls back to the *isolated*
# linker and `sury` is NOT hoisted to the root — rescript's upward traversal then fails with
# "did not find 'sury'". To stay correct under either linker we detect that case and build a
# real node_modules that mirrors the root and adds the un-hoisted deps individually.

# Deps the fixtures declare (or reach via ppx-flags like "sury-ppx/bin"). Extra entries are
# harmless: a temp package only builds what its own rescript.json lists.
REQUIRED_DEPS=(sury sury-ppx @reventlessdev/reventless-spec @reventlessdev/reventless-infra)

# Print a package's directory, resolved under either linker. Workspace @reventlessdev/* live at
# known repo paths; external deps go through node's resolver, anchored at dirs that can see them
# (the root and the workspace packages that depend on sury).
resolve_dep_dir() {
  local dep="$1"
  case "$dep" in
    @reventlessdev/*)
      local short="${dep#@reventlessdev/}"
      for cand in "$REPO_ROOT/reventless/$short" "$REPO_ROOT/packages/$short"; do
        [ -f "$cand/package.json" ] && { echo "$cand"; return 0; }
      done
      ;;
  esac
  node -e 'try { console.log(require("path").dirname(require.resolve(process.argv[1] + "/package.json", { paths: process.argv.slice(2) }))); } catch { process.exit(1); }' \
    "$dep" "$REPO_ROOT" "$REPO_ROOT/reventless/spec" "$REPO_ROOT/reventless/infra" "$PPX_DIR"
}

# Give $1/node_modules a layout where every REQUIRED_DEP resolves.
link_node_modules() {
  local target="$1" nm="$1/node_modules"
  # Fast path (unchanged): hoisted root already contains sury → one symlink covers everything.
  if [ -e "$REPO_ROOT/node_modules/sury" ]; then
    ln -s "$REPO_ROOT/node_modules" "$nm"
    return
  fi
  # Fallback (isolated linker): mirror the root node_modules so rescript + @rescript/* + the
  # workspace packages still resolve, then symlink the deps the root is missing (sury, …).
  echo "  (note: 'sury' not hoisted in \$REPO_ROOT/node_modules — linking deps individually)"
  mkdir -p "$nm"
  for entry in "$REPO_ROOT"/node_modules/*; do
    local base; base="$(basename "$entry")"
    if [[ "$base" == @* ]]; then
      mkdir -p "$nm/$base"
      for scoped in "$entry"/*; do
        [ -e "$scoped" ] && ln -sfn "$scoped" "$nm/$base/$(basename "$scoped")"
      done
    else
      ln -sfn "$entry" "$nm/$base"
    fi
  done
  for dep in "${REQUIRED_DEPS[@]}"; do
    [ -e "$nm/$dep" ] && continue
    local dir; dir="$(resolve_dep_dir "$dep")" || { echo "  ✗ could not resolve dependency '$dep'"; exit 1; }
    [[ "$dep" == @*/* ]] && mkdir -p "$nm/${dep%/*}"
    ln -sfn "$dir" "$nm/$dep"
  done
}

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
  "dependencies": [
    "sury",
    "@reventlessdev/reventless-spec",
    "@reventlessdev/reventless-infra"
  ]
}
EOF

link_node_modules "$PLUGIN"

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

# Snapshot-enabled behavior — @@reventless.snapshots(N) injects
# Some({interval: N, stateSchema}); needs @schema type state for sury.
cat > "$PLUGIN/src/Aggregate/Snapped.res" <<'EOF'
@@reventless.spec

type command = Create
type event = Created
type error = unit
EOF

cat > "$PLUGIN/src/Aggregate/SnappedBehavior.res" <<'EOF'
@@reventless.behavior
@@reventless.snapshots(25)

@schema
type state = {count: int}
let initialState = {count: 0}
let evolve = (s, _e: event) => {count: s.count + 1}
let decide = (_s, _c: command) => Ok([Created])
EOF

# ReadModel — strips "ReadModel" suffix, auto-injects ReadModel defaults
cat > "$PLUGIN/src/ReadModel/ProductsReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = { productName: string }
EOF

# @owner on a read-model state — the explicitly-`option`-typed form, which needs
# a whole-field schema (Owner.optionString) because @s.matches on an
# `option<X>` field replaces the wrapper too. Outside a slice folder, so nothing
# else claims the field and the bare constructor is what should land.
cat > "$PLUGIN/src/ReadModel/OwnedRowsReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = { @id rowId: string, @owner customerId: option<string> }
EOF

# The index @owner derives. Four shapes, because each answers a different
# question about which read the list door ends up making:
#   OwnedRows…      → no @subId, so `id` is the sort key (a total order)
#   OwnedVersioned… → the record's own @subId orders the caller's rows
#   OwnedSmall…     → @owner({index: false}) declines it
#   OwnedIndexed…   → the author's own @index on the field wins; one config, not two
cat > "$PLUGIN/src/ReadModel/OwnedVersionedReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = { @owner tenantId: string, @subId version: string, data: string }
EOF

cat > "$PLUGIN/src/ReadModel/OwnedSmallReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = { id: string, @owner({index: false}) customerId: string }
EOF

cat > "$PLUGIN/src/ReadModel/OwnedIndexedReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = { id: string, @index @owner customerId: string, name: string }
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

# @offload shorthand — rewrites the field type X -> Reventless.Offload.payload<X>
# and emits the matching untagged codec, deriving the inner schema by sury
# convention (blob -> blobSchema). Optional field -> optionSchema; non-optional ->
# forStore. Resolves Reventless.Offload because reventless-spec's namespace IS
# Reventless (same mechanism as @storageRef's Reventless.StorageRef).
cat > "$PLUGIN/src/OffloadHost.res" <<'EOF'
@@reventless.spec

@schema
type blob = { data: string, size: int }

@schema
type command = Store({ @offload({store: "blobs", threshold: 4096}) payload: option<blob> })

@schema
type event = Stored({ @offload("blobs") raw: blob })

@schema
type error = unit
EOF

# Uploadable semantic types — the store is the field's name pluralised, so the
# type takes no store argument. The explicit `@storageRef` on a typed field is
# the documented override and must keep the type's semantic rather than
# downgrading the field to a bare storage ref.
cat > "$PLUGIN/src/UploadHost.res" <<'EOF'
@@reventless.spec

@schema
type command =
  | Upload({
      productImage: Reventless.UploadableImage.t,
      categoryImage?: Reventless.UploadableImage.t,
      datasheets: array<Reventless.UploadableFile.t>,
      @storageRef("branding.logos") logo: Reventless.UploadableImage.t,
      plain: string,
    })

@schema
type event = Uploaded({productImage: Reventless.UploadableImage.t})

@schema
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

link_node_modules "$SPEC"

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

link_node_modules "$DCB"

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
  @schema
  type event =
    | ItemPublished({itemId: string})
    | ItemWithdrawn({itemId: string})
    | ItemReplenished({itemId: string})
  @schema type directive = unit
}

module Delegate = {
  let name = "ItemCatalog"
  @schema
  type event =
    | ItemAdded({itemId: string, name: string})
    | ItemArchived({itemId: string})
    | ItemDiscontinued({itemId: string})
    | ItemRenamed({itemId: string, name: string})
    | ItemsBatched({itemIds: array<string>})
    | ItemRestocked({itemId: string, count: int})
}

let mapIncomingCommand = (_id, _command, _meta) => []

let mapOutgoingEvent = Some((_id, event, _meta, _queryEngine) =>
  switch event {
  | Delegate.ItemAdded({itemId, name: _}) => [
      PublishEvent(itemId, ExtensionPoint.ItemPublished({itemId: itemId})),
    ]
  // Two internal events, one published fact.
  | Delegate.ItemArchived({itemId}) => [
      PublishEvent(itemId, ExtensionPoint.ItemWithdrawn({itemId: itemId})),
    ]
  | Delegate.ItemDiscontinued({itemId}) => [
      PublishEvent(itemId, ExtensionPoint.ItemWithdrawn({itemId: itemId})),
    ]
  // Fans out through a lambda, and stops at the port.
  | Delegate.ItemsBatched({itemIds}) =>
    itemIds->Array.map(id => PublishEvent(id, ExtensionPoint.ItemPublished({itemId: id})))
  // Builds part of its result under a name and merges it in.
  | Delegate.ItemRestocked({itemId, count}) =>
    let alsoPublish = if count > 0 {
      [PublishEvent(itemId, ExtensionPoint.ItemReplenished({itemId: itemId}))]
    } else {
      []
    }
    Array.concat(
      [PublishEvent(itemId, ExtensionPoint.ItemPublished({itemId: itemId}))],
      alsoPublish,
    )
  | Delegate.ItemRenamed(_) => []
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

# @owner: names the field that ties a row or command to its caller. Runs after
# every DCB-tag pass and *composes* rather than replaces, so each field below
# checks a different thing the marker must not subtract:
# - customerId  → auto-*Id tag survives      (Owner.mark(DcbTag.string))
# - orderId     → @partitionTag survives     (Owner.mark(DcbTag.partition))
# - sellerId    → @ref survives              (Owner.mark(Reference.to_(...)))
# - agentId     → @noDcbTag leaves it bare   (Owner.string)
# - onBehalfOf? → optional field             (S.option(Owner.string))
cat > "$DCB/src/StateChangeSlice/OwnedOrder.res" <<'EOF'
@@reventless.spec

@schema
type command =
  | Place({@partitionTag orderId: string, @owner customerId: string})
  | Import({@partitionTag orderId: string, @noDcbTag @owner agentId: string})
  | Quote({@partitionTag orderId: string, @ref("Seller") @owner sellerId: string})

@schema
type event = Placed({@partitionTag orderId: string, @owner onBehalfOf?: string})

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

# ─── Fixture: @transition (lifecycle edge, all three forms) ────────────

# Every form on one command type. `Ship` moves the row and declares the arrow;
# `Rename` guards only — its absence from the targetState metadata is what tells
# a consumer the command moves nothing, so the test asserts on that absence too;
# `Open` creates the row and declares a target with an empty from-set, so it must
# reach markTargetState and NOT markAllowedStates.
cat > "$PLUGIN/src/Aggregate/TransitionOrder.res" <<'EOF'
@@reventless.spec

type lifecycle = Placed | Shipped | Cancelled

@schema
type state = { @id orderId: string, note: string }

let initialState = { orderId: "", note: "" }

@schema
type command =
  | @transition(([Placed]) => Shipped) Ship({orderId: string})
  | @transition(([Placed, Shipped]) => Cancelled) Cancel({orderId: string})
  | @transition([Placed]) Rename({orderId: string, note: string})
  | @transition(() => Placed) Open({orderId: string})
  | Place({orderId: string})

@schema
type event = Shipped2({orderId: string})

@schema
type error = NotFound

let decide = (_state, _command): result<array<event>, error> => Ok([])
let evolve = (state, _event) => state
EOF

# ─── Fixture: @live on the state declaration (live-updates hint) ──

# @live(false) on a ReadModel state declaration
cat > "$PLUGIN/src/ReadModel/LiveOffReadModel.res" <<'EOF'
@@reventless.spec

@live(false)
@schema
type state = { @id id: string, name: string }
EOF

# @live(true) on a StateViewSlice state declaration (no field annotations —
# the metadata binding must be emitted from @live alone)
cat > "$PLUGIN/src/StateViewSlice/LiveOnView.res" <<'EOF'
@@reventless.spec

@live(true)
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

# ─── Fixture: @groupBy (list-view section key) ────────────────────

cat > "$PLUGIN/src/ReadModel/GroupByReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = {
  @id id: string,
  @groupBy kind: string,
  name: string,
}
EOF

# ─── Fixture: a tagged union as a state field ─────────────────────
#
# The union has to carry its own name: the SDL emitter reaches a field through a
# path and the write-time `__typename` stamp has only the schema, so the name
# both must agree on lives on the schema. The enum beside it is the control —
# an enum is a different emission and must stay untouched.

cat > "$PLUGIN/src/ReadModel/UnionReadModel.res" <<'EOF'
@@reventless.spec

@schema
type geolocation =
  | Pending({requestedFor: string})
  | Located({lat: float, lng: float})
  | Unresolvable({reason: string})

@schema
type accountStatus =
  | Active
  | Deactivated

@schema
type state = {
  @id customerId: string,
  geolocation: geolocation,
  @lifecycle accountStatus: accountStatus,
}
EOF

# ─── Fixture: an optional union and an array of them ──────────────

cat > "$PLUGIN/src/ReadModel/UnionWrappedReadModel.res" <<'EOF'
@@reventless.spec

@schema
type outcome =
  | Settled({amount: float})
  | Refunded({reason: string})

@schema
type state = {
  @id orderId: string,
  outcome: option<outcome>,
  attempts: array<outcome>,
}
EOF

# ─── Fixture: @retired on a lifecycle state, named from the field ─
#
# The form that survives for an enum this per-file PPX cannot reach to annotate.
# `accountStatus` is declared here, so the name IS checked — see the error
# package for the misspelling that check catches.

cat > "$PLUGIN/src/ReadModel/RetiredStateReadModel.res" <<'EOF'
@@reventless.spec

@schema
type accountStatus =
  | Active
  | Deactivated

@schema
type state = {
  @id customerId: string,
  @retired(Deactivated) @lifecycle accountStatus: accountStatus,
}
EOF

# ─── Fixture: @retired on the constructors, one state ─────────────
#
# The marker's home. One retired state must be the ordinary case rather than a
# special one, so it is asserted beside the two-state fixture below.

cat > "$PLUGIN/src/ReadModel/RetiredCtorReadModel.res" <<'EOF'
@@reventless.spec

@schema
type accountStatus =
  | Active
  | @retired Deactivated

@schema
type state = {
  @id customerId: string,
  @lifecycle accountStatus: accountStatus,
}
EOF

# ─── Fixture: two retired states on one lifecycle ─────────────────
#
# A lifecycle may end in more than one way. Both withdraw the row identically;
# what differs is the way back, which `@allowedStates` reads elsewhere.

cat > "$PLUGIN/src/ReadModel/RetiredStatesReadModel.res" <<'EOF'
@@reventless.spec

@schema
type shelfStatus =
  | Listed
  | @retired Archived
  | @retired Discontinued

@schema
type state = {
  @id productId: string,
  @lifecycle shelfStatus: shelfStatus,
}
EOF

# ─── Fixture: @namedWhenRetired (a retired row keeps its name) ────
#
# On the record, not on a state: `Archived` and `Discontinued` do not get to
# disagree about whether the product has a public name.

cat > "$PLUGIN/src/ReadModel/NamedWhenRetiredReadModel.res" <<'EOF'
@@reventless.spec

@schema
type shelfStatus =
  | Listed
  | @retired Archived

@schema
@namedWhenRetired
type state = {
  @id productId: string,
  name: string,
  @lifecycle shelfStatus: shelfStatus,
}
EOF

# ─── Fixture: @lifecycle (the enum commands branch on) ────────────

cat > "$PLUGIN/src/ReadModel/LifecycleReadModel.res" <<'EOF'
@@reventless.spec

@schema
type phase =
  | Open
  | Closed

@schema
type state = {
  @id id: string,
  @lifecycle phase: phase,
  name: string,
}
EOF

# ─── Fixture: @retired (row withdrawn from ordinary reads) ────────

cat > "$PLUGIN/src/ReadModel/RetiredReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = {
  @id id: string,
  name: string,
  @retired deactivated: bool,
}
EOF

# The record payload form, on an option<bool> field — both variations at once,
# since they are independent of each other and of the bare form above.
cat > "$PLUGIN/src/ReadModel/RetiredLabelledReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = {
  @id id: string,
  name: string,
  @retired({label: "Archived", showWhenFalse: true}) archived: option<bool>,
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
  module ExtensionPoint = {
    let name = "Test.Demo"
    let moduleUrl = "test"
    @schema type command = unit
    @schema
    type event =
      | DemoPublished({demoId: string})
      | DemoWithdrawn({demoId: string})
    @schema type directive = unit
  }

  // Inner Delegate — should get dcbTags + module Id injected by the PPX
  // (the same auto-transform spec files apply to a `module Delegate`).
  module Delegate = {
    let name = "DemoDelegate"
    @schema
    type command =
      | SyncDemo({demoId: string})
      | DropDemo({demoId: string})
    @schema
    type event = | DemoEvent({demoId: string})
  }

  let mapIncomingEvent = (_id, event: ExtensionPoint.event, _meta, _pluginDef, _queryEngine) =>
    switch event {
    | DemoPublished({demoId}) => [
        ReventlessInfra.ExtensionMapping.PublishStateChangeSliceCommand(
          Delegate.SyncDemo({demoId: demoId}),
        ),
      ]
    | DemoWithdrawn({demoId}) => [
        ReventlessInfra.ExtensionMapping.PublishStateChangeSliceCommand(
          Delegate.DropDemo({demoId: demoId}),
        ),
      ]
    }

  let mapOutgoingEvent = None
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

# Self-test that the source still compiles. Skipped when exercising an
# externally supplied binary (REVENTLESS_PPX_SKIP_SELF_BUILD=1) — e.g. the drift
# guard, which runs the just-published binary and needs no OCaml toolchain.
if [ -z "${REVENTLESS_PPX_SKIP_SELF_BUILD:-}" ]; then
  echo "Building PPX..."
  # Bare `dune`, on purpose: the caller supplies the switch. CI runs
  # `opam exec -- npm test`; run this script the same way by hand. Without it
  # dune resolves outside the switch and fails on a ppxlib/OCaml version
  # mismatch, which reads like a source error and is not one.
  (cd src && dune build 2>&1) || {
    echo "PPX build failed — if the error mentions ppxlib or 'not a compiled interface',"
    echo "you are outside the opam switch: re-run as 'opam exec -- ./test/run.sh'."
    exit 1
  }
fi

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
# Default snapshot injection: `let snapshot = None` (None compiles to an
# undefined binding, exported by name)
assert_js_contains "$JS" 'snapshot'                        "behavior: default let snapshot = None injected"

echo ""
echo "=== Test: @@reventless.snapshots(N) (Some config injection) ==="
JS="$PLUGIN/src/Aggregate/SnappedBehavior.res.mjs"
assert_js_contains "$JS" 'interval: 25'                    "snapshots: interval from attribute payload"
assert_js_contains "$JS" 'stateSchema'                     "snapshots: references generated stateSchema"

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

echo ""
echo "=== Test: @offload shorthand (type rewrite + Offload codec, marker stripped) ==="
JS="$PLUGIN/src/OffloadHost.res.mjs"
# The optional field compiles to Reventless.Offload.optionSchema(~store, blobSchema);
# the non-optional field to Reventless.Offload.forStore(~store, blobSchema).
assert_js_contains "$JS" 'optionSchema'                   "@offload: optional field emits Offload.optionSchema"
assert_js_contains "$JS" 'forStore'                       "@offload: non-optional field emits Offload.forStore"
assert_js_contains "$JS" 'blobSchema'                     "@offload: inner schema derived (blob -> blobSchema)"
assert_js_contains "$JS" '"blobs"'                        "@offload: store name threaded into codec"
assert_js_contains "$JS" '4096'                           "@offload: per-field threshold threaded into codec"

echo ""
echo "=== Test: @owner on a read-model state (option<string> form) ==="
JS="$PLUGIN/src/ReadModel/OwnedRowsReadModel.res.mjs"
assert_js_contains "$JS" 'customerId: s.m(Owner$Reventless.optionString)' \
  "@owner: option<string> field emits Owner.optionString"
# The unannotated sibling must stay bare — a pass that marked every field would
# scope correctly on this fixture and wrongly on every real one.
assert_js_contains "$JS" 'rowId: s.m(Sury.string)' \
  "@owner: unmarked sibling field left untouched"

echo ""
echo "=== Test: @owner derives the index its scoped read is served from ==="
JS="$PLUGIN/src/ReadModel/OwnedRowsReadModel.res.mjs"
assert_js_contains "$JS" 'index: "_owner"'          "@owner index: named _owner"
assert_js_contains "$JS" 'idField: "customerId"'    "@owner index: partitioned by the owner field"
assert_js_contains "$JS" 'subIdField: "id"'         "@owner index: sorts on id when no @subId"
assert_js_contains "$JS" 'projectionType: "ALL"'    "@owner index: projects every attribute"
assert_js_contains "$JS" 'derived: true'            "@owner index: marked derived (carries no SDL door)"

JS="$PLUGIN/src/ReadModel/OwnedVersionedReadModel.res.mjs"
assert_js_contains "$JS" 'idField: "tenantId"'      "@owner + @subId: partitioned by the owner field"
assert_js_contains "$JS" 'subIdField: "version"'    "@owner + @subId: the record's own sub-id orders it"

JS="$PLUGIN/src/ReadModel/OwnedSmallReadModel.res.mjs"
assert_js_not_contains "$JS" '_owner'               "@owner({index: false}): no index derived"
assert_js_not_contains "$JS" 'derived'              "@owner({index: false}): nothing marked derived"
assert_js_contains "$JS" 'Owner$Reventless.string'  "@owner({index: false}): still marks the field"

# An author who indexed the field already gets ONE index, not two: the derived
# one would be a second write per projection write on the same key.
JS="$PLUGIN/src/ReadModel/OwnedIndexedReadModel.res.mjs"
assert_js_contains "$JS" 'index: "customerId"'      "@index + @owner: the author's index is emitted"
assert_js_not_contains "$JS" '_owner'               "@index + @owner: no second index on the same key"
assert_js_not_contains "$JS" 'derived'              "@index + @owner: nothing marked derived"

echo ""
echo "=== Test: uploadable types (store derived from the field name) ==="
JS="$PLUGIN/src/UploadHost.res.mjs"
assert_js_contains "$JS" 'productImage: s.m(UploadableImage$Reventless.forField(undefined, "productImages"))' \
  "uploadable: store derived as the field name pluralised"
assert_js_contains "$JS" 'categoryImage: s.m(Sury.$option(UploadableImage$Reventless.forField(undefined, "categoryImages")))' \
  "uploadable: optional field derives through the option wrapper"
# The array marker goes on the ELEMENT: attached to the array itself it collects
# nothing, which is the same silence as never declaring a store.
assert_js_contains "$JS" 'datasheets: s.m(Sury.array(UploadableFile$Reventless.forField(undefined, "datasheets")))' \
  "uploadable: array field marks its element, store already plural"
assert_js_contains "$JS" 'logo: s.m(UploadableImage$Reventless.forField("branding", "logos"))' \
  "uploadable: explicit @storageRef overrides the derived store"
# The override must not fall through to StorageRefInference, which would emit
# StorageRef.forStore and lose the field's image semantic.
assert_js_not_contains "$JS" 'StorageRef$Reventless' \
  "uploadable: an overridden field keeps its own semantic"
assert_js_contains "$JS" 'plain: s.m(Sury.string)' \
  "uploadable: an untyped sibling field is left untouched"
assert_js_contains "$JS" 'productImage: s.m(UploadableImage$Reventless.forField(undefined, "productImages"))' \
  "uploadable: the event field derives the same store as the command field"

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
# The translation table is read off the arms — no author-written strings.
assert_js_contains "$JS" 'publishedEvents'                "EP mapping: publishedEvents derived"
TABLE=$(node -e '
  const m = require("fs").readFileSync(process.argv[1], "utf8");
  const i = m.indexOf("let publishedEvents = [");
  process.stdout.write(i < 0 ? "" : m.slice(i, m.indexOf("];", i)));
' "$JS")
# Two internal retirements collapsing into one published fact is exactly what a
# consumer joining the two name lists by hand gets wrong.
case "$TABLE" in
  *ItemArchived*ItemDiscontinued*)
    pass "EP mapping: many-to-one arms collapse into one published event" ;;
  *) fail "EP mapping many-to-one" "ItemWithdrawn did not carry both source events" ;;
esac
case "$TABLE" in
  *ItemsBatched*) pass "EP mapping: a fan-out through Array.map is read" ;;
  *) fail "EP mapping fan-out" "ItemsBatched missing from the derived table" ;;
esac
case "$TABLE" in
  *ItemRenamed*) fail "EP mapping swallowed arm" "ItemRenamed should not appear in the table" ;;
  *) pass "EP mapping: an arm that publishes nothing adds no row" ;;
esac
# An edge reachable only through a let-bound name merged in with Array.concat.
# Passed over as data, it would be lost in silence — the one shape where "no
# edge" and "did not look" could read alike.
case "$TABLE" in
  *ItemReplenished*) pass "EP mapping: a let-bound action array merged in is followed" ;;
  *) fail "EP mapping let-bound arm" "ItemReplenished missing — the merged branch was dropped" ;;
esac

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
echo "=== Test: @owner composes with the DCB passes instead of replacing them ==="
JS="$DCB/src/StateChangeSlice/OwnedOrder.res.mjs"
# The whole point of running last: an owner field keeps whatever schema it would
# otherwise have had. If this pass ran early, the auto-*Id tagger would skip the
# field (it skips anything already carrying @s.matches) and customerId would
# lose its tag silently — a decision read that misses events, reported by nobody.
assert_js_contains "$JS" 'Owner$Reventless.mark(DcbTag$Reventless.string)' \
  "@owner + auto-*Id: DCB tag survives the marker"
assert_js_contains "$JS" 'DcbTag$Reventless.partition' \
  "@owner sibling: @partitionTag unaffected"
assert_js_contains "$JS" 'Owner$Reventless.mark(Reference$Reventless.to_' \
  "@owner + @ref: reference survives the marker"
assert_js_contains "$JS" '"Seller"' \
  "@owner + @ref: reference target still reaches the codec"
# agentId is @noDcbTag + @owner: nothing else claimed the field, so the bare
# constructor lands rather than a wrap of something.
assert_js_contains "$JS" 'agentId: s.m(Owner$Reventless.string)' \
  "@owner + @noDcbTag: bare Owner.string emitted"
# The optional form needs no separate constructor — sury wraps the annotated
# inner schema itself, and Owner.isFieldOwner looks through that wrapper.
assert_js_contains "$JS" 'onBehalfOf: s.m(Sury.$option(Owner$Reventless.string))' \
  "@owner on f?: string — marker lands inside the option wrapper"
assert_js_not_contains "$JS" 'noDcbTag' "@owner: @noDcbTag field attr stripped"

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
echo "=== Test: @groupBy → metadata field populated ==="
JS="$PLUGIN/src/ReadModel/GroupByReadModel.res.mjs"
assert_js_contains "$JS" 'stateAnnotationsId'        "@groupBy: stateAnnotations metadata emitted"
assert_js_contains "$JS" 'groupBy: "kind"'           "@groupBy: 'kind' recorded in groupBy field"
assert_js_not_contains "$JS" '@groupBy'              "@groupBy: annotation stripped from output"

echo ""
echo "=== Test: a union state field is named on its schema ==="
JS="$PLUGIN/src/ReadModel/UnionReadModel.res.mjs"
# `Test` from the namespace, `Union` from the filename minus its `ReadModel`
# suffix — the same spec name every other injection here is derived from.
assert_js_contains "$JS" 'TaggedUnion.*named("Test_UnionGeolocation"' \
  "union: schema shadowed with <Plugin>_<Spec><Type>"
# The shadow has to be what `type state` closes over — a binding emitted after
# the state record would name a union nothing is using.
assert_js_contains "$JS" 'geolocation: s.m(geolocationSchema\$1)' \
  "union: the state field uses the named schema"
assert_js_not_contains "$JS" 'accountStatusSchema\$1' \
  "union: the enum beside it is left alone"

echo ""
echo "=== Test: an optional union and an array of them are named too ==="
JS="$PLUGIN/src/ReadModel/UnionWrappedReadModel.res.mjs"
assert_js_contains "$JS" 'TaggedUnion.*named("Test_UnionWrappedOutcome"' \
  "union: named through option<> and array<>"
assert_js_contains "$JS" 'outcome: s.m(Sury.\$option(outcomeSchema\$1))' \
  "union: option field uses the named schema"
assert_js_contains "$JS" 'attempts: s.m(Sury.array(outcomeSchema\$1))' \
  "union: array field uses the named schema"

echo ""
echo "=== Test: @lifecycle → metadata field populated ==="
JS="$PLUGIN/src/ReadModel/LifecycleReadModel.res.mjs"
assert_js_contains "$JS" 'stateAnnotationsId'        "@lifecycle: stateAnnotations metadata emitted"
assert_js_contains "$JS" 'lifecycle: "phase"'        "@lifecycle: 'phase' recorded in lifecycle field"
assert_js_not_contains "$JS" '@lifecycle'            "@lifecycle: annotation stripped from output"

echo ""
echo "=== Test: @retired on a state → the set in the metadata ==="
JS="$PLUGIN/src/ReadModel/RetiredStateReadModel.res.mjs"
assert_js_contains "$JS" 'stateAnnotationsId'         "@retired(state): metadata emitted"
assert_js_contains "$JS" 'field: "accountStatus"'     "@retired(state): field recorded"
assert_js_contains "$JS" 'values: \["Deactivated"\]'  "@retired(state): named state recorded as a one-element set"
assert_js_contains "$JS" 'lifecycle: "accountStatus"' "@retired(state): pairs with @lifecycle"
assert_js_not_contains "$JS" '@retired'               "@retired(state): annotation stripped"

echo ""
echo "=== Test: @retired on a constructor → the field that holds it ==="
# The marker is on a type and the schema entry is on a field; the correlation
# pass is what joins them, with no annotation on the field at all.
JS="$PLUGIN/src/ReadModel/RetiredCtorReadModel.res.mjs"
assert_js_contains "$JS" 'field: "accountStatus"'     "@retired ctor: correlated to the field holding the enum"
assert_js_contains "$JS" 'values: \["Deactivated"\]'  "@retired ctor: one retired state recorded"
assert_js_contains "$JS" 'lifecycle: "accountStatus"' "@retired ctor: pairs with @lifecycle"
assert_js_not_contains "$JS" '@retired'               "@retired ctor: attribute stripped from the constructor"

echo ""
echo "=== Test: two @retired constructors → both states ==="
JS="$PLUGIN/src/ReadModel/RetiredStatesReadModel.res.mjs"
assert_js_contains "$JS" 'field: "shelfStatus"'  "@retired ×2: field recorded"
# A multi-element array is emitted one entry per line, so the members are matched
# individually rather than as one bracketed literal (which is how the one-state
# case above can be, and is).
assert_js_contains "$JS" '"Archived"'            "@retired ×2: first state recorded"
assert_js_contains "$JS" '"Discontinued"'        "@retired ×2: second state recorded"
assert_js_not_contains "$JS" '@retired'          "@retired ×2: attributes stripped"

echo ""
echo "=== Test: @retired → metadata field populated ==="
JS="$PLUGIN/src/ReadModel/RetiredReadModel.res.mjs"
assert_js_contains "$JS" 'stateAnnotationsId'        "@retired: stateAnnotations metadata emitted"
assert_js_contains "$JS" 'field: "deactivated"'      "@retired: 'deactivated' recorded as the retired field"
assert_js_contains "$JS" 'showWhenFalse: false'      "@retired: showWhenFalse defaults to false"
assert_js_not_contains "$JS" '@retired'              "@retired: annotation stripped from output"

JS="$PLUGIN/src/ReadModel/RetiredLabelledReadModel.res.mjs"
assert_js_contains "$JS" 'field: "archived"'         "@retired: record payload names the field"
assert_js_contains "$JS" 'label: "Archived"'         "@retired: record payload carries the label"
assert_js_contains "$JS" 'showWhenFalse: true'       "@retired: record payload carries showWhenFalse"

echo ""
echo "=== Test: @namedWhenRetired → carried on the retirement it is about ==="
JS="$PLUGIN/src/ReadModel/NamedWhenRetiredReadModel.res.mjs"
assert_js_contains "$JS" 'namedWhenRetired: true'  "@namedWhenRetired: recorded on the retirement"
assert_js_contains "$JS" 'field: "shelfStatus"'    "@namedWhenRetired: rides the record's own retirement"
assert_js_not_contains "$JS" '@namedWhenRetired'   "@namedWhenRetired: attribute stripped from output"

# The default every record said before the opt-in existed, and still says.
JS="$PLUGIN/src/ReadModel/RetiredReadModel.res.mjs"
assert_js_contains "$JS" 'namedWhenRetired: false' "@retired without the opt-in: the archive stays shut"

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
# The subscriber's half of the table, read off `mapIncomingEvent`'s arms.
assert_js_contains "$JS" 'handledEvents' "extension: handledEvents derived"
HANDLED=$(node -e '
  const m = require("fs").readFileSync(process.argv[1], "utf8");
  const i = m.indexOf("let handledEvents = [");
  process.stdout.write(i < 0 ? "" : m.slice(i, m.indexOf("];", i)));
' "$JS")
case "$HANDLED" in
  *DemoPublished*SyncDemo*DemoWithdrawn*DropDemo*)
    pass "extension: each published event carries the command it routes to" ;;
  *) fail "extension handledEvents" "unexpected derived table: $HANDLED" ;;
esac

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
  "dependencies": ["sury", "@reventlessdev/reventless-spec", "@reventlessdev/reventless-infra"]
}
EOF

link_node_modules "$ERROR"

echo ""
echo "=== Test: PPX error — a mapping arm the translation table cannot be read from ==="

# An arm that hands its actions to a helper. The table must not silently omit it:
# "no edge" and "did not look" are different facts, so the derivation stops and
# names the arm rather than guessing.
mkdir -p "$ERROR/src/ExtensionPoint"
EPM_DIR="$ERROR/src/ExtensionPoint"
cat > "$EPM_DIR/Opaque_ExtensionPointMapping.res" <<'RES'
@@reventless.spec

module ExtensionPoint = {
  let name = "Test.Opaque"
  let moduleUrl = "test"
  @schema type command = unit
  @schema type event = | Published({itemId: string})
  @schema type directive = unit
}

module Delegate = {
  let name = "OpaqueDelegate"
  @schema type event = | Added({itemId: string})
}

let mapIncomingCommand = (_id, _command, _meta) => []

let actionsFor = _itemId => []

let mapOutgoingEvent = Some((_id, event, _meta, _queryEngine) =>
  switch event {
  | Delegate.Added({itemId}) => actionsFor(itemId)
  }
)
RES

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "unreadable mapping arm" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "cannot read publishedEvents"; then
    pass "unreadable mapping arm → correct compile error naming the escape hatch"
  else
    fail "unreadable mapping arm" "unexpected error output: $OUTPUT"
  fi
fi

echo ""
echo "=== Test: PPX error — an arm merging in a name bound to an opaque call ==="

# The same refusal one level in. `extra` reaches the result, so passing over it
# would drop an edge silently; the walk cannot tell a call's result from data, so
# it refuses rather than guessing either way.
cat > "$EPM_DIR/Opaque_ExtensionPointMapping.res" <<'RES'
@@reventless.spec

module ExtensionPoint = {
  let name = "Test.Opaque"
  let moduleUrl = "test"
  @schema type command = unit
  @schema type event = | Published({itemId: string})
  @schema type directive = unit
}

module Delegate = {
  let name = "OpaqueDelegate"
  @schema type event = | Added({itemId: string})
}

let mapIncomingCommand = (_id, _command, _meta) => []

let actionsFor = _itemId => []

let mapOutgoingEvent = Some((_id, event, _meta, _queryEngine) =>
  switch event {
  | Delegate.Added({itemId}) =>
    let extra = actionsFor(itemId)
    Array.concat([PublishEvent(itemId, ExtensionPoint.Published({itemId: itemId}))], extra)
  }
)
RES

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "opaque let-bound merge" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "cannot read publishedEvents"; then
    pass "opaque let-bound merge → refused rather than silently dropped"
  else
    fail "opaque let-bound merge" "unexpected error output: $OUTPUT"
  fi
fi

echo ""
echo "=== Test: a hand-written table where the arms cannot be read ==="

# The escape hatch: the author states the table and the derivation steps aside.
cat > "$EPM_DIR/Opaque_ExtensionPointMapping.res" <<'RES'
@@reventless.spec

module ExtensionPoint = {
  let name = "Test.Opaque"
  let moduleUrl = "test"
  @schema type command = unit
  @schema type event = | Published({itemId: string})
  @schema type directive = unit
}

module Delegate = {
  let name = "OpaqueDelegate"
  @schema type event = | Added({itemId: string})
}

let mapIncomingCommand = (_id, _command, _meta) => []

let actionsFor = _itemId => []

let publishedEvents: array<publishedEvent> = [
  {name: "Published", fromEventTypes: ["Added"]},
]

let mapOutgoingEvent = Some((_id, event, _meta, _queryEngine) =>
  switch event {
  | Delegate.Added({itemId}) => actionsFor(itemId)
  }
)
RES

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  pass "a hand-written publishedEvents compiles where the arms cannot be read"
else
  fail "hand-written publishedEvents" "expected it to compile: $OUTPUT"
fi
rm -f "$EPM_DIR/Opaque_ExtensionPointMapping.res"

echo ""
echo "=== Test: PPX error — two @owner fields in one record ==="

# Two owners is not a stricter rule than one, it is an unanswered question: every
# reader downstream takes the first marked field, so the second would be inert
# and the view would scope on whatever declaration order happened to put first.
cat > "$ERROR/src/ReadModel/TwoOwners.res" <<'EOF'
@@reventless.spec

@schema
type state = { @id rowId: string, @owner customerId: string, @owner buyerId: string }
EOF

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "two @owner fields" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "@owner appears twice"; then
    pass "two @owner fields in one record → correct compile error"
  else
    fail "two @owner fields" "unexpected error output: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/ReadModel/TwoOwners.res"

echo ""
echo "=== Test: PPX error — @owner on an array field ==="

# Owner.isFieldOwner follows the optional wrapper but deliberately not array
# elements, so an annotated array would mark a schema no reader ever asks about
# and scope nothing. Refusing is the difference between a compile error and a
# view that silently serves everybody's rows.
cat > "$ERROR/src/ReadModel/ArrayOwner.res" <<'EOF'
@@reventless.spec

@schema
type state = { @id rowId: string, @owner customerIds: array<string> }
EOF

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "@owner on array field" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "@owner only supports string and option<string> fields"; then
    pass "@owner on array<string> → correct compile error"
  else
    fail "@owner on array field" "unexpected error output: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/ReadModel/ArrayOwner.res"

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
echo "=== Test: @transition arrow form → both from-set and target lowered ==="
JS="$PLUGIN/src/Aggregate/TransitionOrder.res.mjs"
assert_js_contains "$JS" 'markAllowedStates' "markAllowedStates binding emitted from @transition"
assert_js_contains "$JS" 'markTargetState' "markTargetState binding emitted from @transition"
assert_js_contains "$JS" '"Ship"' "moving command present in the metadata"
assert_js_contains "$JS" '"Shipped"' "arrow target lowered to the metadata"

echo ""
echo "=== Test: @transition multi-state from-set keeps every state ==="
assert_js_contains "$JS" '"Cancelled"' "second command's target lowered"

# The guard-only claim is carried by an ABSENCE — `Rename` must appear in the
# from-set metadata and NOT in the target metadata. Asserted by slicing the
# markTargetState call out of the generated module and grepping inside it, so a
# `Rename` mentioned elsewhere in the file cannot satisfy the check.
echo ""
echo "=== Test: @transition one-sided form declares no target ==="
if grep -q '"Rename"' "$JS"; then
  pass "guard-only command reaches the from-set metadata"
else
  fail "guard-only from-set" "Rename missing from generated metadata"
fi
TARGET_BLOCK=$(sed -n '/markTargetState/,/]);/p' "$JS")
if echo "$TARGET_BLOCK" | grep -q '"Rename"'; then
  fail "guard-only target" "Rename must not appear in markTargetState — its absence is the claim"
else
  pass "guard-only command absent from markTargetState (declares no target)"
fi
# `Place` carries no annotation at all: it must reach neither binding.
if echo "$TARGET_BLOCK" | grep -q '"Place"'; then
  fail "unannotated command" "Place must not appear in markTargetState"
else
  pass "unannotated command absent from the transition metadata"
fi

# The creating form's claim is the mirror image of the guard-only one: a target
# and NO from-set. An entry in markAllowedStates would be `allowedStates: Some([])`
# — legal in no state — and would hide the command that brings the row into being.
echo ""
echo "=== Test: @transition creating form declares a target and no from-set ==="
if echo "$TARGET_BLOCK" | grep -q '"Open"'; then
  pass "creating command reaches markTargetState"
else
  fail "creating target" "Open missing from markTargetState"
fi
ALLOWED_BLOCK=$(sed -n '/markAllowedStates/,/]);/p' "$JS")
if echo "$ALLOWED_BLOCK" | grep -q '"Open"'; then
  fail "creating from-set" "Open must not appear in markAllowedStates — the empty from-set is the claim"
else
  pass "creating command absent from markAllowedStates"
fi

echo ""
echo "=== Test: an empty bracketed from-set is refused, naming () ==="
mkdir -p "$ERROR/src/Aggregate"
cat > "$ERROR/src/Aggregate/EmptyBracketed.res" <<'EOF'
@@reventless.spec

type lifecycle = Placed

@schema
type state = { @id orderId: string }

@schema
type command = @transition(([]) => Placed) Open({orderId: string})
EOF
if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "empty bracketed from-set" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "()"; then
    pass "empty bracketed from-set fails the build and names the () spelling"
  else
    fail "empty bracketed from-set" "error did not name the () spelling: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/Aggregate/EmptyBracketed.res"

echo ""
echo "=== Test: the removed @allowedStates raises, naming @transition ==="
mkdir -p "$ERROR/src/Aggregate"
cat > "$ERROR/src/Aggregate/LegacyAllowed.res" <<'EOF'
@@reventless.spec

type lifecycle = Placed | Shipped

@schema
type state = { @id orderId: string }

@schema
type command = @allowedStates([Placed]) Ship({orderId: string})
EOF
if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "removed @allowedStates" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "@transition"; then
    pass "leftover @allowedStates fails the build and names @transition"
  else
    fail "removed @allowedStates" "error did not name the replacement: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/Aggregate/LegacyAllowed.res"

echo ""
echo "=== Test: the removed @targetState raises, naming @transition ==="
cat > "$ERROR/src/Aggregate/LegacyTarget.res" <<'EOF'
@@reventless.spec

type lifecycle = Placed | Shipped

@schema
type state = { @id orderId: string }

@schema
type command = @targetState(Shipped) Ship({orderId: string})
EOF
if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "removed @targetState" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "@transition"; then
    pass "leftover @targetState fails the build and names @transition"
  else
    fail "removed @targetState" "error did not name the replacement: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/Aggregate/LegacyTarget.res"

echo ""
echo "=== Test: a string state name is refused ==="
cat > "$ERROR/src/Aggregate/StringState.res" <<'EOF'
@@reventless.spec

type lifecycle = Placed | Shipped

@schema
type state = { @id orderId: string }

@schema
type command = @transition((["Placed"]) => Shipped) Ship({orderId: string})
EOF
if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "string state name" "expected compilation to fail but it succeeded"
else
  pass "a string state name is refused rather than silently accepted"
fi
rm -f "$ERROR/src/Aggregate/StringState.res"

echo ""
echo "=== Test: @live(false) on ReadModel state → metadata carries live: false ==="
JS="$PLUGIN/src/ReadModel/LiveOffReadModel.res.mjs"
assert_js_contains "$JS" 'stateAnnotationsId' "stateAnnotations binding emitted on @live ReadModel"
assert_js_contains "$JS" 'live: false' "live: false recorded in stateAnnotations metadata"

echo ""
echo "=== Test: @live(true) on StateViewSlice state → metadata from @live alone ==="
JS="$PLUGIN/src/StateViewSlice/LiveOnView.res.mjs"
assert_js_contains "$JS" 'stateAnnotationsId' "stateAnnotations binding emitted from @live alone"
assert_js_contains "$JS" 'live: true' "live: true recorded in stateAnnotations metadata"

echo ""
echo "=== Test: unannotated state → metadata omits live ==="
JS="$PLUGIN/src/ReadModel/VisibilityDefaultReadModel.res.mjs"
assert_js_not_contains "$JS" 'live: true' "live: true absent without @live"
assert_js_not_contains "$JS" 'live: false' "live: false absent without @live"

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

# ── @internal: a field that is not on the GraphQL surface ───────────────────
#
# @hidden says "do not show this" — the field is on the API and any client may
# ask for it. @internal says "this is not on the API at all", so codegen drops it
# from the generated SDL type and from the published state schema.
#
# Every marker that KEYS A DOOR is therefore rejected beside it: each makes some
# generated surface name the field, and a surface cannot name a field the SDL
# does not have. Two of the list are checked here — one structural, one an
# enforcement marker — because they reach the check by different predicates.

echo ""
echo "=== Test: @internal lowers to the annotation spec ==="

cat > "$PLUGIN/src/ReadModel/InternalFieldsReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = {
  @id itemId: string,
  name: string,
  @internal eventCollector: string,
  @internal extensionNames: array<string>,
}
EOF

if OUTPUT=$(cd "$PLUGIN" && npx rescript build 2>&1); then
  JS="$PLUGIN/src/ReadModel/InternalFieldsReadModel.res.mjs"
  assert_js_contains "$JS" 'internal:' "internal list emitted into the annotation spec"
  assert_js_contains "$JS" '"eventCollector"' "annotated field named in the spec"
  # The field stays in the record: @internal removes it from the API, not from
  # storage. If the type lost it, projection and every reader would lose it too.
  assert_js_contains "$JS" 'eventCollector: ' "the field survives in the schema itself"
else
  fail "@internal lowering" "expected compilation to succeed: $OUTPUT"
fi

echo ""
echo "=== Test: PPX error — @internal + @id on same field ==="

cat > "$ERROR/src/ReadModel/InternalIdConflictReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = {
  @internal @id itemId: string,
  name: string,
}
EOF

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "@internal + @id conflict" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "@internal cannot appear with @id"; then
    pass "@internal + @id on same field → correct compile error"
  else
    fail "@internal + @id conflict" "unexpected error output: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/ReadModel/InternalIdConflictReadModel.res"

echo ""
echo "=== Test: PPX error — @internal + @owner on same field ==="

cat > "$ERROR/src/ReadModel/InternalOwnerConflictReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = {
  @id itemId: string,
  @internal @owner customerId: string,
}
EOF

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "@internal + @owner conflict" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "@internal cannot appear with @owner"; then
    pass "@internal + @owner on same field → correct compile error"
  else
    fail "@internal + @owner conflict" "unexpected error output: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/ReadModel/InternalOwnerConflictReadModel.res"

# The error has to point somewhere useful: @hidden is the annotation an author
# reaching for @internal on a queryable field actually wants.
echo ""
echo "=== Test: the @internal conflict error names @hidden as the alternative ==="

cat > "$ERROR/src/ReadModel/InternalHintReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = {
  @internal @id itemId: string,
}
EOF

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "@internal hint" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "use @hidden instead"; then
    pass "@internal conflict error names @hidden"
  else
    fail "@internal hint" "error did not name @hidden: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/ReadModel/InternalHintReadModel.res"

echo ""
echo "=== Test: PPX error — duplicate @groupBy on same record ==="

cat > "$ERROR/src/ReadModel/GroupByConflictReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = {
  @id id: string,
  @groupBy kind: string,
  @groupBy category: string,
}
EOF

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "duplicate @groupBy" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "duplicate @groupBy annotation"; then
    pass "duplicate @groupBy on same record → correct compile error"
  else
    fail "duplicate @groupBy" "unexpected error output: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/ReadModel/GroupByConflictReadModel.res"

echo ""
echo "=== Test: PPX error — union arms that GraphQL cannot express ==="

# Three shapes, one rule, and every one of them compiles and round-trips through
# sury. What refuses them is the SDL: a union member must be an object type with
# at least one field, and a field it names must be one the author named.
union_arm_case() {
  local label="$1" arm="$2" needle="$3"
  cat > "$ERROR/src/ReadModel/UnionArmReadModel.res" <<EOF
@@reventless.spec

@schema
type verdict =
  | $arm
  | Rejected({reason: string})

@schema
type state = {@id caseId: string, verdict: verdict}
EOF
  if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
    fail "$label" "expected compilation to fail but it succeeded"
  else
    if echo "$OUTPUT" | grep -q "$needle"; then
      pass "$label → correct compile error"
    else
      fail "$label" "unexpected error output: $OUTPUT"
    fi
  fi
  rm -f "$ERROR/src/ReadModel/UnionArmReadModel.res"
}

union_arm_case "payload-less union arm"   "Approved"          'carries no payload'
union_arm_case "empty inline record arm"  "Approved({})"      'carries an empty inline record'
union_arm_case "positional payload arm"   "Approved(string)"  'carries a positional payload'

echo ""
echo "=== Test: PPX error — key/filter annotations on a union field ==="

# `deriveServerCapability` is annotation-driven: it would emit `<field>Eq: String`
# against a value that is an object, and the filter would never match. The
# annotation is refused rather than ignored, because a filter input that exists
# and cannot match is worse than one that is absent.
union_annotation_case() {
  local annotation="$1" needle="$2"
  cat > "$ERROR/src/ReadModel/UnionAnnotationReadModel.res" <<EOF
@@reventless.spec

@schema
type verdict =
  | Approved({by: string})
  | Rejected({reason: string})

@schema
type state = {@id caseId: string, $annotation verdict: verdict}
EOF
  if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
    fail "$annotation on a union field" "expected compilation to fail but it succeeded"
  else
    if echo "$OUTPUT" | grep -q "$needle"; then
      pass "$annotation on a union field → correct compile error"
    else
      fail "$annotation on a union field" "unexpected error output: $OUTPUT"
    fi
  fi
  rm -f "$ERROR/src/ReadModel/UnionAnnotationReadModel.res"
}

union_annotation_case "@index"     '@index cannot be used on "verdict"'
union_annotation_case "@scan"      '@scan cannot be used on "verdict"'
union_annotation_case "@groupBy"   '@groupBy cannot be used on "verdict"'
union_annotation_case "@lifecycle" '@lifecycle cannot be used on "verdict"'

echo ""
echo "=== Test: PPX error — @retired on an arm of a union state field ==="

# The constructor form of `@retired` is read by comparing the stored field to a
# state name. A union field stores a record, so the predicate never fires and
# every row stays visible — a retirement that silently retires nothing.
cat > "$ERROR/src/ReadModel/UnionRetiredReadModel.res" <<'EOF'
@@reventless.spec

@schema
type verdict =
  | Approved({by: string})
  | @retired Rejected({reason: string})

@schema
type state = {@id caseId: string, verdict: verdict}
EOF

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "@retired on a union arm" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "@retired on arm .Rejected."; then
    pass "@retired on an arm of a union state field → correct compile error"
  else
    fail "@retired on a union arm" "unexpected error output: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/ReadModel/UnionRetiredReadModel.res"

echo ""
echo "=== Test: PPX error — duplicate @lifecycle on same record ==="

cat > "$ERROR/src/ReadModel/LifecycleConflictReadModel.res" <<'EOF'
@@reventless.spec

@schema
type phase = Open | Closed

@schema
type state = {
  @id id: string,
  @lifecycle phase: phase,
  @lifecycle otherPhase: phase,
}
EOF

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "duplicate @lifecycle" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "duplicate @lifecycle annotation"; then
    pass "duplicate @lifecycle on same record → correct compile error"
  else
    fail "duplicate @lifecycle" "unexpected error output: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/ReadModel/LifecycleConflictReadModel.res"

echo ""
echo "=== Test: PPX error — @status (old name) names @lifecycle ==="

cat > "$ERROR/src/ReadModel/LegacyStatusReadModel.res" <<'EOF'
@@reventless.spec

@schema
type phase = Open | Closed

@schema
type state = {
  @id id: string,
  @status phase: phase,
}
EOF

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "@status (old name)" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "@status was renamed to @lifecycle"; then
    pass "@status (old name) → correct rename error"
  else
    fail "@status (old name)" "unexpected error output: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/ReadModel/LegacyStatusReadModel.res"

echo ""
echo "=== Test: PPX error — duplicate @retired on same record ==="

cat > "$ERROR/src/ReadModel/RetiredConflictReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = {
  @id id: string,
  @retired deactivated: bool,
  @retired archived: bool,
}
EOF

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "duplicate @retired" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "duplicate @retired annotation"; then
    pass "duplicate @retired on same record → correct compile error"
  else
    fail "duplicate @retired" "unexpected error output: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/ReadModel/RetiredConflictReadModel.res"

echo ""
echo "=== Test: PPX error — @retired(state) on a boolean field ==="

cat > "$ERROR/src/ReadModel/RetiredStateOnBoolReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = {
  @id id: string,
  @retired(Deactivated) archived: bool,
}
EOF

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "@retired(state) on bool" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "names a state, so the field must hold the enum"; then
    pass "@retired(state) on a boolean field → correct compile error"
  else
    fail "@retired(state) on bool" "unexpected error output: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/ReadModel/RetiredStateOnBoolReadModel.res"

echo ""
echo "=== Test: PPX error — @retired on a non-boolean field ==="

cat > "$ERROR/src/ReadModel/RetiredTypeReadModel.res" <<'EOF'
@@reventless.spec

@schema
type state = {
  @id id: string,
  @retired status: string,
}
EOF

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "@retired on non-bool" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "@retired only supports bool"; then
    pass "@retired on a non-boolean field → correct compile error"
  else
    fail "@retired on non-bool" "unexpected error output: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/ReadModel/RetiredTypeReadModel.res"

echo ""
echo "=== Test: PPX error — @retired names a state the enum does not declare ==="

# The hole the constructor form exists to close. `@retired(Archivd)` compiled
# clean before this check and put "Archivd" on the schema, so every row was
# compared against a state nothing is in and stayed visible to everyone — while
# the annotation sat there looking like enforcement.
cat > "$ERROR/src/ReadModel/RetiredTypoReadModel.res" <<'EOF'
@@reventless.spec

@schema
type shelfStatus =
  | Listed
  | Archived

@schema
type state = {
  @id id: string,
  @retired(Archivd) @lifecycle shelfStatus: shelfStatus,
}
EOF

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "@retired misspelled state" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "declares no constructor Archivd"; then
    pass "@retired naming a state the enum lacks → correct compile error"
  else
    fail "@retired misspelled state" "unexpected error output: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/ReadModel/RetiredTypoReadModel.res"

echo ""
echo "=== Test: PPX error — @retired constructor no field holds ==="

# An annotated state that narrows no read is the same silent failure in a new
# place: the author marked a retirement and got no enforcement.
cat > "$ERROR/src/ReadModel/RetiredOrphanReadModel.res" <<'EOF'
@@reventless.spec

@schema
type shelfStatus =
  | Listed
  | @retired Archived

@schema
type state = {
  @id id: string,
  name: string,
}
EOF

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "@retired ctor with no holder" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "no field of .type state. holds"; then
    pass "@retired constructor no field holds → correct compile error"
  else
    fail "@retired ctor with no holder" "unexpected error output: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/ReadModel/RetiredOrphanReadModel.res"

echo ""
echo "=== Test: PPX error — two fields hold the same annotated enum ==="

cat > "$ERROR/src/ReadModel/RetiredTwoHoldersReadModel.res" <<'EOF'
@@reventless.spec

@schema
type shelfStatus =
  | Listed
  | @retired Archived

@schema
type state = {
  @id id: string,
  shelfStatus: shelfStatus,
  previousStatus: shelfStatus,
}
EOF

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "two holders of an annotated enum" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "two fields hold"; then
    pass "two fields holding one annotated enum → correct compile error"
  else
    fail "two holders of an annotated enum" "unexpected error output: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/ReadModel/RetiredTwoHoldersReadModel.res"

echo ""
echo "=== Test: PPX error — both @retired forms on one field ==="

# Two places to look for one answer is how they come to disagree.
cat > "$ERROR/src/ReadModel/RetiredBothFormsReadModel.res" <<'EOF'
@@reventless.spec

@schema
type shelfStatus =
  | Listed
  | @retired Archived

@schema
type state = {
  @id id: string,
  @retired(Archived) @lifecycle shelfStatus: shelfStatus,
}
EOF

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "both @retired forms" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "whose constructors carry it"; then
    pass "both @retired forms on one field → correct compile error"
  else
    fail "both @retired forms" "unexpected error output: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/ReadModel/RetiredBothFormsReadModel.res"

echo ""
echo "=== Test: PPX error — @retired constructor with a payload ==="

cat > "$ERROR/src/ReadModel/RetiredCtorPayloadReadModel.res" <<'EOF'
@@reventless.spec

@schema
type shelfStatus =
  | Listed
  | @retired("Withdrawn") Archived

@schema
type state = {
  @id id: string,
  @lifecycle shelfStatus: shelfStatus,
}
EOF

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "@retired ctor payload" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "on a constructor takes no payload"; then
    pass "@retired constructor with a payload → correct compile error"
  else
    fail "@retired ctor payload" "unexpected error output: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/ReadModel/RetiredCtorPayloadReadModel.res"

echo ""
echo "=== Test: PPX error — @live with a non-bool payload ==="

cat > "$ERROR/src/ReadModel/LiveArityReadModel.res" <<'EOF'
@@reventless.spec

@live("yes")
@schema
type state = { @id id: string, name: string }
EOF

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "@live non-bool payload" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "@live expects exactly one bool payload"; then
    pass "@live with non-bool payload → correct compile error"
  else
    fail "@live non-bool payload" "unexpected error output: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/ReadModel/LiveArityReadModel.res"

echo ""
echo "=== Test: PPX error — @live on an Aggregate state declaration ==="

mkdir -p "$ERROR/src/Aggregate"
cat > "$ERROR/src/Aggregate/LiveOnAggregate.res" <<'EOF'
@@reventless.spec

@schema
type command = Create
@schema
type event = Created
@schema
type error = unit

@live(true)
@schema
type state = { id: string }
EOF

if OUTPUT=$(cd "$ERROR" && npx rescript build 2>&1); then
  fail "@live on Aggregate state" "expected compilation to fail but it succeeded"
else
  if echo "$OUTPUT" | grep -q "@live is only supported on the @schema type state declaration"; then
    pass "@live on Aggregate state → correct compile error"
  else
    fail "@live on Aggregate state" "unexpected error output: $OUTPUT"
  fi
fi
rm -f "$ERROR/src/Aggregate/LiveOnAggregate.res"

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
