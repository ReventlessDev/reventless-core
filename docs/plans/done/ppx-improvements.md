# PPX Improvements

Planned improvements to `reventless-ppx`.

---

## 1. `@partitionTag` field annotation

**Status:** Pending

**Problem:** When a DCB event variant has multiple `*Id: string` fields (e.g. `productId` and `orderId`), the auto-tagging pass marks both as `DcbTag.string`. The runtime then throws because it can't determine the partition key. The current workaround is the verbose `@s.matches(Reventless.DcbTag.partition)` on the type expression.

**Solution:** Add a `@partitionTag` field-level attribute as shorthand. The PPX transforms it to `@s.matches(Reventless.DcbTag.partition)` on the type and strips the original attribute.

**Usage:**
```rescript
@schema
type event =
  | ProductDemandRecorded({
      @partitionTag productId: string,
      orderId: string,  // auto-tagged as DcbTag.string in slice folders
    })
```

**Implementation in `packages/reventless-ppx/src/ppx/`:**

### `DcbTagInference.ml`

1. Refactor `dcb_tag_attr` into a shared helper `s_matches_attr ~loc ident` that builds any `@s.matches(ident)` attribute, then re-express `dcb_tag_attr` and the new `dcb_partition_attr` using it:

```ocaml
let s_matches_attr ~loc ident =
  let payload =
    PStr [{ pstr_desc =
              Pstr_eval (
                { pexp_desc = Pexp_ident { txt = ident; loc };
                  pexp_loc = loc;
                  pexp_loc_stack = [];
                  pexp_attributes = [] },
                []);
            pstr_loc = loc }]
  in
  { attr_name = { txt = "s.matches"; loc };
    attr_payload = payload;
    attr_loc = loc }

let dcb_tag_attr ~loc =
  s_matches_attr ~loc (Ldot (Ldot (Lident "Reventless", "DcbTag"), "string"))

let dcb_partition_attr ~loc =
  s_matches_attr ~loc (Ldot (Ldot (Lident "Reventless", "DcbTag"), "partition"))
```

2. Add helpers for detecting and stripping `@partitionTag` on field attributes (`pld_attributes`):

```ocaml
let has_partition_tag_field_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "partitionTag"
  ) attrs

let strip_partition_tag_field_attr (attrs : attributes) =
  List.filter (fun (attr : attribute) ->
    not (String.equal attr.attr_name.txt "partitionTag")
  ) attrs
```

3. In `transform_label_decl`, skip fields that have `@partitionTag` so the auto-tag pass doesn't apply `DcbTag.string` to them first:

```ocaml
let transform_label_decl ~loc (ld : label_declaration) =
  (* Skip fields marked with @partitionTag — handled by transform_partition_tags *)
  if has_partition_tag_field_attr ld.pld_attributes then ld
  else if Util.ends_with_id ...   (* existing logic unchanged *)
```

4. Add a new `transform_partition_tags` pass (mirrors the structure of `transform_structure` but runs unconditionally):

```ocaml
let transform_partition_tag_label_decl ~loc (ld : label_declaration) =
  if has_partition_tag_field_attr ld.pld_attributes
     && is_string_type ld.pld_type
     && not (has_s_matches_attr ld.pld_type.ptyp_attributes) then
    let attr = dcb_partition_attr ~loc in
    let new_type = { ld.pld_type with
                     ptyp_attributes = attr :: ld.pld_type.ptyp_attributes } in
    let new_attrs = strip_partition_tag_field_attr ld.pld_attributes in
    { ld with pld_type = new_type; pld_attributes = new_attrs }
  else
    ld

let transform_partition_tag_constructor ~loc (cd : constructor_declaration) =
  match cd.pcd_args with
  | Pcstr_record fields ->
    let new_fields = List.map (transform_partition_tag_label_decl ~loc) fields in
    { cd with pcd_args = Pcstr_record new_fields }
  | _ -> cd

let transform_partition_tag_type_decl ~loc (td : type_declaration) =
  if not (Util.has_attr "schema" td.ptype_attributes) then td
  else
    match td.ptype_kind with
    | Ptype_variant constructors ->
      let new_ctors = List.map (transform_partition_tag_constructor ~loc) constructors in
      { td with ptype_kind = Ptype_variant new_ctors }
    | _ -> td

let transform_partition_tags ~loc (str : structure) : structure =
  List.map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (rf, decls) ->
      let new_decls = List.map (transform_partition_tag_type_decl ~loc) decls in
      { item with pstr_desc = Pstr_type (rf, new_decls) }
    | _ -> item
  ) str
```

### `ReventlessPpx.ml`

Apply `transform_partition_tags` unconditionally after the dcbTags pass (line ~299), so it works in all `@@reventless.spec` / `@@reventless.behavior` files regardless of whether dcbTags is enabled:

```ocaml
let body = if dcb_tags then DcbTagInference.transform_structure ~loc body else body in
let body = DcbTagInference.transform_partition_tags ~loc body in
```

**Follow-up:** Update `RecordProductDemand.res` in the online-shop-hybrid example to use `@partitionTag productId` instead of `@s.matches(Reventless.DcbTag.partition)`.

**Tests:** Add a PPX test case in `packages/reventless-ppx/test/` covering:
- `@partitionTag` in a slice folder (alongside auto-tagged `*Id` fields)
- `@partitionTag` outside a slice folder (standalone, no auto-tagging)

---

## 2. `@noTag` field annotation

**Status:** Pending

**Problem:** When a `*Id: string` field should NOT be a DCB key (e.g. `orderId` in `ProductDemandRecorded` where `productId` is the real key), the current workaround is `@s.matches(S.string)` on the type expression. This is non-obvious — it reads as re-stating the schema type rather than opting out of DCB tagging.

**Solution:** Add a `@noTag` field-level attribute that suppresses auto-tagging. The PPX strips the attribute and leaves the type expression untouched. Semantically the opposite of `@dcbTag` (item 3).

**Usage:**
```rescript
@schema
type event =
  | ProductDemandRecorded({
      productId: string,        // auto-tagged as DcbTag.string
      @noTag orderId: string,   // suppressed — plain string
    })
```

**Implementation in `DcbTagInference.ml`:**

1. Add helpers for detecting/stripping `@noTag` on `pld_attributes`.
2. In `transform_label_decl`, skip fields that have `@noTag` (no `DcbTag.string` injected), and strip the attribute so the compiler doesn't warn about an unknown attribute.

The stripping must happen regardless of dcbTags mode — if `@noTag` is written in a non-slice file it should still be consumed cleanly. Add a `strip_no_tag_attrs` pass analogous to `transform_partition_tags` that runs unconditionally in `ReventlessPpx.ml`.

**Tests:**
- `@noTag` on a `*Id` field in a slice folder — field stays as plain `string`
- `@noTag` outside a slice folder — attribute is stripped cleanly, no compiler warning

---

## 3. `@dcbTag` field annotation

**Status:** Pending

**Problem:** Only fields named `*Id: string` or `*Ids: array<string>` are auto-tagged. Fields with domain names that don't follow this convention (e.g. `sku: string`, `slug: string`, `reference: string`) cannot be DCB filter keys without writing `@s.matches(DcbTag.string)` manually.

**Solution:** Add a `@dcbTag` field-level attribute as explicit opt-in for any field name. The PPX injects `@s.matches(Reventless.DcbTag.string)` on the type expression and strips the attribute.

**Usage:**
```rescript
@schema
type event =
  | ProductAdded({
      @dcbTag sku: string,   // non-*Id field, explicitly tagged
      name: string,
    })
```

**Implementation in `DcbTagInference.ml`:**

1. Add `has_dcb_tag_field_attr` / `strip_dcb_tag_field_attr` helpers detecting `@dcbTag` on `pld_attributes`.
2. Add a `transform_explicit_dcb_tags` pass (runs unconditionally like `transform_partition_tags`) that:
   - Detects `@dcbTag` on any `string` field
   - Injects `@s.matches(Reventless.DcbTag.string)` on the type
   - Strips the `@dcbTag` field attribute
3. In `transform_label_decl` (auto-tag pass), skip fields that already have `@dcbTag` to avoid double-tagging (the unconditional pass will handle them).

**`ReventlessPpx.ml`:** Apply all three unconditional passes in order after the dcbTags pass:
```ocaml
let body = if dcb_tags then DcbTagInference.transform_structure ~loc body else body in
let body = DcbTagInference.transform_partition_tags ~loc body in
let body = DcbTagInference.transform_explicit_dcb_tags ~loc body in
let body = DcbTagInference.strip_no_tag_attrs ~loc body in
```

**Tests:**
- `@dcbTag` on a non-`*Id` field — injects `DcbTag.string`
- `@dcbTag` on a `*Id` field — only tagged once (no duplication)
- `@dcbTag` outside a slice folder — works without `@@reventless.dcbTags`

---

## 4. Documentation updates

**Status:** Pending

Update all guides that mention DCB tagging to document the three new annotations:

- `CLAUDE.md` — PPX Annotations section: add `@partitionTag`, `@noTag`, `@dcbTag` with one-line descriptions alongside the existing `@@reventless.dcbTags` entry
- `packages/doc/docs/inner-workings/` (serialization or relevant doc) — if DCB tagging is documented there
- `packages/doc/docs/` — any guide covering DCB slice authoring or the `@@reventless.dcbTags` opt-in
- Update the online-shop-hybrid example: replace `@s.matches(Reventless.DcbTag.partition)` in `RecordProductDemand.res` with `@partitionTag`
