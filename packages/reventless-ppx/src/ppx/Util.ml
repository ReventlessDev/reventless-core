open Ppxlib

let has_attr name attrs =
  List.exists (fun (attr : attribute) -> String.equal attr.attr_name.txt name) attrs

let find_attr name attrs =
  List.find_opt (fun (attr : attribute) -> String.equal attr.attr_name.txt name) attrs

let get_string_payload (attr : attribute) =
  match attr.attr_payload with
  | PStr [{ pstr_desc = Pstr_eval ({ pexp_desc = Pexp_constant (Pconst_string (s, _, _)); _ }, _); _ }] ->
    Some s
  | _ -> None

let get_ident_payload (attr : attribute) =
  match attr.attr_payload with
  | PStr [{ pstr_desc = Pstr_eval (expr, _); _ }] ->
    (match expr.pexp_desc with
     | Pexp_construct ({ txt = Lident name; _ }, None) -> Some name
     | Pexp_ident { txt = Lident name; _ } -> Some name
     | _ -> None)
  | _ -> None

let has_let_binding name structure =
  List.exists (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_value (_, bindings) ->
      List.exists (fun (vb : value_binding) ->
        match vb.pvb_pat.ppat_desc with
        | Ppat_var { txt; _ } -> String.equal txt name
        | Ppat_constraint ({ ppat_desc = Ppat_var { txt; _ }; _ }, _) ->
          String.equal txt name
        | _ -> false
      ) bindings
    | _ -> false
  ) structure

let has_module_binding name structure =
  List.exists (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_module mb ->
      (match mb.pmb_name.txt with
       | Some n -> String.equal n name
       | None -> false)
    | _ -> false
  ) structure

let has_modtype_binding name structure =
  List.exists (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_modtype mtd -> String.equal mtd.pmtd_name.txt name
    | _ -> false
  ) structure

let has_open name structure =
  List.exists (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_open od ->
      (match od.popen_expr.pmod_desc with
       | Pmod_ident { txt = Lident n; _ } -> String.equal n name
       | _ -> false)
    | _ -> false
  ) structure

let has_open_dotted outer inner structure =
  List.exists (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_open od ->
      (match od.popen_expr.pmod_desc with
       | Pmod_ident { txt = Ldot (Lident n1, n2); _ } ->
         String.equal n1 outer && String.equal n2 inner
       | _ -> false)
    | _ -> false
  ) structure

let ends_with_id name =
  let len = String.length name in
  len >= 3
  && name.[len - 1] = 'd'
  && name.[len - 2] = 'I'
  && (len = 2 || name.[len - 3] <> 'I')

let strip_suffix s suffix =
  let slen = String.length s in
  let suflen = String.length suffix in
  if slen > suflen && String.sub s (slen - suflen) suflen = suffix then
    String.sub s 0 (slen - suflen)
  else
    s

(* Slice-layer suffixes: describe the category of a slice.
   Stripped everywhere, including inside slice folders. *)
let slice_layer_suffixes = [
  "View"; "Slice"; "Spec"
]

(* Framework component suffixes: describe top-level architectural types.
   Only stripped when the file is NOT inside a slice folder.
   Inside a slice folder these can be part of the entity name (e.g. SyncPlugin).

   The underscored variants are tried first so post-Phase-3-rename files
   like [Products_ExtensionPoint.res] strip cleanly to ["Products"] instead
   of leaving a trailing underscore. *)
let top_level_only_suffixes = [
  "_ExtensionPointMapping";
  "_ExtensionPoint";
  "_ReadModel";
  "_Extension";
  "_Aggregate";
  "_Plugin";
  "ExtensionPointMapping";
  "ExtensionPoint";
  "ReadModel";
  "Behavior";
  "Projections";
  "Projection";
  "Aggregate";
  "Plugin";
]

(* Slice bases that have been migrated to short DSL kind names. Each base
   maps a folder/filename segment to the implementation-kind name emitted as
   [<Kind>_GWT.Make]. Plan 01 unified Automation/InboundTranslation/
   OutboundTranslation onto short forms; Plan 02 (Phase 3b) added the
   StateChange → Behavior and StateView → Projection redirects so all five
   slice families are uniform. Folder/filename segments still match on the
   short, plural, or [Slice]-suffixed forms for backwards compatibility. *)
let slice_base_to_kind = [
  ("Automation",          "Automation");
  ("InboundTranslation",  "InboundTranslation");
  ("OutboundTranslation", "OutboundTranslation");
  ("StateChange",         "Behavior");
  ("StateView",           "Projection");
]

let known_slice_bases = List.map fst slice_base_to_kind

let ends_with_slice part =
  let len = String.length part in
  len >= 5 && String.sub part (len - 5) 5 = "Slice"

let ends_with_slices part =
  let len = String.length part in
  len >= 6 && String.sub part (len - 6) 6 = "Slices"

let is_slice_folder_segment part =
  ends_with_slice part || List.mem part known_slice_bases

(* Shared substring check — also used by GwtInference. *)
let contains_substring haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  if hlen < nlen then false
  else
    let rec check i =
      if i > hlen - nlen then false
      else if String.sub haystack i nlen = needle then true
      else check (i + 1)
    in
    check 0

(* Map a slice base to its emitted DSL kind name. Looks up the [base] in
   [slice_base_to_kind]; falls back to [base ^ "Slice"] for any future base
   that hasn't been registered yet (preserves the previous default). *)
let kind_for_base base =
  match List.assoc_opt base slice_base_to_kind with
  | Some k -> k
  | None -> base ^ "Slice"

(* Kind name for a given folder segment or filename stem, or None if the
   segment doesn't correspond to any DSL kind.

   Recognises four spellings of every known slice base:
     "Foo", "Foos", "FooSlice", "FooSlices"
   The [slice_base_to_kind] table maps each base to its emitted kind name.

   Also recognises the Aggregate-pattern architectural folders [Aggregate]
   and [ReadModel] (and their plurals) — they aren't slice bases but they
   are valid `tests/<Entity>/Aggregate|ReadModel/<Spec>_GWT.res` host
   folders, mapped to [Behavior] (with the Aggregate-side functor) and
   [MultiSourceProjection] respectively. The functor-name selection that
   distinguishes [Make] from [MakeFromAggregate] happens later in
   [GwtInference] based on [is_in_aggregate_folder].

   Falls back to substring matching for non-slice kinds (Projection,
   Behavior) and for filenames like "AutomationGwtTest" or
   "StateChangeSliceGwtTest" that bundle the kind with a test suffix.
   StateChange* / StateView* substrings map to Behavior / Projection per
   Plan 02 Phase 3b. *)
let dsl_kind_of_segment part : string option =
  if part = "Aggregate" || part = "Aggregates" then Some "Behavior"
  else if part = "ReadModel" || part = "ReadModels" then Some "MultiSourceProjection"
  else
  let try_base base =
    if part = base
       || part = base ^ "s"
       || part = base ^ "Slice"
       || part = base ^ "Slices"
    then Some (kind_for_base base)
    else None
  in
  let rec try_bases = function
    | [] -> None
    | b :: rest ->
      (match try_base b with
       | Some _ as k -> k
       | None -> try_bases rest)
  in
  match try_bases known_slice_bases with
  | Some _ as k -> k
  | None ->
    (* Substring fallback. Order matters: longer/more specific prefixes
       first so "OutboundTranslationSliceGwtTest" doesn't match the
       shorter "Translation" / "Automation" patterns. *)
    if contains_substring part "OutboundTranslation" then Some "OutboundTranslation"
    else if contains_substring part "InboundTranslation" then Some "InboundTranslation"
    else if contains_substring part "Automation" then Some "Automation"
    else if contains_substring part "StateChangeSlice" then Some "Behavior"
    else if contains_substring part "StateViewSlice" then Some "Projection"
    else if contains_substring part "Projection" then Some "Projection"
    else if contains_substring part "Behavior" then Some "Behavior"
    else None

(* Derive the DSL Kind for a @@reventless.gwt file from its path.
   Scans folder segments innermost-first (closest-to-file wins) so a path
   like [tests/StateChange/Migrations/StateView/X_GWT.res] classifies as
   StateView rather than StateChange — the immediate folder is a better
   signal of a test's subject than an outer organisational ancestor.
   Falls back to the filename stem if no folder segment matches. *)
let derive_gwt_kind fname : string option =
  let dir_parts = String.split_on_char '/' (Filename.dirname fname) in
  let stem =
    let base = Filename.basename fname in
    match String.index_opt base '.' with
    | Some i -> String.sub base 0 i
    | None -> base
  in
  let from_folder =
    List.find_map dsl_kind_of_segment (List.rev dir_parts)
  in
  match from_folder with
  | Some _ as k -> k
  | None -> dsl_kind_of_segment stem

(* GWT test filename suffixes — stripped to derive the external Spec module
   name from files with no local Spec binding. Order matters: longest match
   wins so "GwtTest" is tried before "Gwt". *)
let gwt_test_suffixes = ["_GWT"; "GwtTest"; "Gwt"]

(* Strip one of the GWT-test suffixes from the filename stem.
   Returns the Spec module name (the remainder), or None if the filename
   doesn't end in a recognised GWT suffix. *)
let spec_name_from_gwt_filename fname : string option =
  let stem =
    let base = Filename.basename fname in
    match String.index_opt base '.' with
    | Some i -> String.sub base 0 i
    | None -> base
  in
  let rec try_suffixes = function
    | [] -> None
    | s :: rest ->
      let stripped = strip_suffix stem s in
      if not (String.equal stripped stem) && String.length stripped > 0 then
        Some stripped
      else
        try_suffixes rest
  in
  try_suffixes gwt_test_suffixes

let is_in_slice_folder fname =
  let dir = Filename.dirname fname in
  let parts = String.split_on_char '/' dir in
  List.exists is_slice_folder_segment parts

(* Generic "is the file inside a folder named [segment]?" check used by the
   file-level Mappings/Extension/Task PPX kinds to disambiguate the target
   domain (Aggregate vs ReadModel) and the kind itself (Extension vs Task). *)
let is_in_folder fname segment =
  let dir_parts = String.split_on_char '/' (Filename.dirname fname) in
  List.exists (String.equal segment) dir_parts

let is_in_aggregate_folder fname = is_in_folder fname "Aggregate"
let is_in_readmodel_folder fname = is_in_folder fname "ReadModel"
let is_in_extension_folder fname = is_in_folder fname "Extension"
let is_in_task_folder fname = is_in_folder fname "Task"
let is_in_automationslice_folder fname =
  let dir_parts = String.split_on_char '/' (Filename.dirname fname) in
  List.exists (fun part ->
    String.equal part "AutomationSlice" || String.equal part "AutomationSlices"
  ) dir_parts

let filename_to_name fname =
  let base = Filename.basename fname in
  let without_ext = match String.index_opt base '.' with
    | Some i -> String.sub base 0 i
    | None -> base
  in
  let suffixes =
    if is_in_slice_folder fname then slice_layer_suffixes
    else slice_layer_suffixes @ top_level_only_suffixes
  in
  let rec try_suffixes name = function
    | [] -> name
    | suffix :: rest ->
      let stripped = strip_suffix name suffix in
      if not (String.equal stripped name) then stripped
      else try_suffixes name rest
  in
  try_suffixes without_ext suffixes

let is_extensionpointmapping_filename fname =
  let base = Filename.basename fname in
  let without_ext = match String.index_opt base '.' with
    | Some i -> String.sub base 0 i
    | None -> base
  in
  let sub = "ExtensionPointMapping" in
  let slen = String.length without_ext in
  let sublen = String.length sub in
  let rec check i =
    if i > slen - sublen then false
    else if String.sub without_ext i sublen = sub then true
    else check (i + 1)
  in
  slen >= sublen && check 0

(* True if the file is a ReadModel spec — either by filename (legacy
   `<Plural>ReadModel.res`) or by parent folder (post-Phase-3-3 layout
   `ReadModel/<Plural>.res`, where the spec drops the ReadModel suffix). *)
let is_readmodel_filename fname =
  let base = Filename.basename fname in
  let without_ext = match String.index_opt base '.' with
    | Some i -> String.sub base 0 i
    | None -> base
  in
  let sub = "ReadModel" in
  let slen = String.length without_ext in
  let sublen = String.length sub in
  let rec check i =
    if i > slen - sublen then false
    else if String.sub without_ext i sublen = sub then true
    else check (i + 1)
  in
  let in_filename = slen >= sublen && check 0 in
  let in_folder = is_in_folder fname "ReadModel" in
  in_filename || in_folder

let is_stateview_filename fname =
  let dir = Filename.dirname fname in
  let parts = String.split_on_char '/' dir in
  List.exists (fun part ->
    let len = String.length part in
    len >= 9 && String.sub part 0 9 = "StateView"
  ) parts

let has_type_binding name (str : structure) =
  List.exists (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (_, type_decls) ->
      List.exists (fun (td : type_declaration) ->
        String.equal td.ptype_name.txt name
      ) type_decls
    | _ -> false
  ) str

let has_schema_state_type (str : structure) =
  List.exists (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (_, type_decls) ->
      List.exists (fun (td : type_declaration) ->
        String.equal td.ptype_name.txt "state"
        && has_attr "schema" td.ptype_attributes
      ) type_decls
    | _ -> false
  ) str
