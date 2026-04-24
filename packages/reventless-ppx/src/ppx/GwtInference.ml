open Ppxlib

(** @@reventless.gwt — file-level annotation that eliminates the
    [include ReventlessGwt.<Kind>_GWT.Make(<Spec>)] line at the top of every
    GWT test file.

    Payload forms:
    {ul
      {- [@@reventless.gwt] — Kind inferred from filename/folder;
         Spec inferred as the first top-level module if present, otherwise
         derived from the filename stem (stripping [_GWT] / [GwtTest] / [Gwt]).}
      {- [@@reventless.gwt(SpecModule)] — Kind inferred; Spec explicit.
         [SpecModule] is treated as a module reference the compiler will
         resolve; it does NOT need to be a local binding in this file.}
      {- [@@reventless.gwt(SpecModule, BehaviorModule)] — for the Behavior DSL,
         which takes two functor arguments.}}

    Supported DSL kinds (canonical tokens, shared with [@@reventless.spec]
    via [Util.derive_gwt_kind]):
    {ul
      {- [AutomationSlice]}
      {- [InboundTranslationSlice]}
      {- [OutboundTranslationSlice]}
      {- [StateChangeSlice]}
      {- [StateViewSlice]}
      {- [Projection]}
      {- [Behavior]}}

    Folder segments match on the short base form ("StateChange"), the long
    form ("StateChangeSlice"), or the plural form ("StateChangeSlices"), as
    well as any filename substring that contains a kind token. When several
    path segments match, the closest-to-file segment wins.

    The PPX strips the attribute and inserts the generated
    [open <Spec>; include <Kind>_GWT.Make(<Spec>)] pair. When the Spec is a
    local top-level module the pair is inserted directly after that module
    (or after the Behavior module, for Behavior DSLs). When the Spec is
    external (explicit payload, or no local module in the file), the pair is
    prepended to the top of the structure. *)

let attr_name = "reventless.gwt"

type payload =
  | Empty
  | One of string
  | Two of string * string

let derive_kind fname : string option = Util.derive_gwt_kind fname

let find_gwt_attr (str : structure) : (attribute * Location.t) option =
  let rec scan = function
    | [] -> None
    | item :: rest ->
      (match item.pstr_desc with
       | Pstr_attribute attr when String.equal attr.attr_name.txt attr_name ->
         Some (attr, attr.attr_loc)
       | _ -> scan rest)
  in
  scan str

let ident_name_of_expr (expr : expression) : string option =
  match expr.pexp_desc with
  | Pexp_construct ({ txt = Lident n; _ }, None) -> Some n
  | Pexp_ident { txt = Lident n; _ } -> Some n
  | _ -> None

let parse_payload (attr : attribute) : payload =
  match attr.attr_payload with
  | PStr [] -> Empty
  | PStr [{ pstr_desc = Pstr_eval (expr, _); _ }] ->
    (match expr.pexp_desc with
     | Pexp_tuple [a; b] ->
       (match ident_name_of_expr a, ident_name_of_expr b with
        | Some na, Some nb -> Two (na, nb)
        | _ -> Empty)
     | _ ->
       (match ident_name_of_expr expr with
        | Some n -> One n
        | None -> Empty))
  | _ -> Empty

let strip_gwt_attr (str : structure) : structure =
  List.filter (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_attribute attr -> not (String.equal attr.attr_name.txt attr_name)
    | _ -> true
  ) str

(** Returns the index of the first structure item whose [Pstr_module] binds
    the named module, or [None] if absent. *)
let find_module_index (name : string) (str : structure) : int option =
  let rec scan i = function
    | [] -> None
    | item :: rest ->
      (match item.pstr_desc with
       | Pstr_module mb when
           (match mb.pmb_name.txt with
            | Some n -> String.equal n name
            | None -> false) ->
         Some i
       | _ -> scan (i + 1) rest)
  in
  scan 0 str

(** Returns the first [n] top-level module names in the structure (in order).
    Modules nested inside other modules are ignored. *)
let find_first_top_modules (n : int) (str : structure) : string list =
  let rec scan acc count = function
    | _ when count >= n -> List.rev acc
    | [] -> List.rev acc
    | item :: rest ->
      (match item.pstr_desc with
       | Pstr_module mb ->
         (match mb.pmb_name.txt with
          | Some name -> scan (name :: acc) (count + 1) rest
          | None -> scan acc count rest)
       | _ -> scan acc count rest)
  in
  scan [] 0 str

(** When the file being processed lives inside the reventless-gwt package
    itself, emit unqualified module references. In-package references don't
    go through the synthesised namespace module, and prefixing with
    [ReventlessGwt.] creates a missing-alias error because the namespace
    module is assembled from every source file (tests included) and cannot
    be referenced from within the same package. *)
let is_in_gwt_package loc =
  match ModuleUrl.find_package_for loc with
  | Some pkg -> String.equal pkg.name "@reventlessdev/reventless-gwt"
  | None -> false

(** Build the functor module Longident. For in-package callers, drop the
    [ReventlessGwt] namespace prefix so the reference becomes
    [<DSL>_GWT.Make]; for downstream callers, keep the full
    [ReventlessGwt.<DSL>_GWT.Make] path. *)
let make_functor_lid ~loc ~dsl_module =
  if is_in_gwt_package loc then
    Ldot (Lident dsl_module, "Make")
  else
    Ldot (Ldot (Lident "ReventlessGwt", dsl_module), "Make")

let gen_include_one ~loc ~kind ~spec_module : structure_item =
  let make_lid = make_functor_lid ~loc ~dsl_module:(kind ^ "_GWT") in
  let make_mod =
    { pmod_desc = Pmod_ident { txt = make_lid; loc };
      pmod_loc = loc;
      pmod_attributes = [] }
  in
  let spec_mod =
    { pmod_desc = Pmod_ident { txt = Lident spec_module; loc };
      pmod_loc = loc;
      pmod_attributes = [] }
  in
  let include_expr =
    { pmod_desc = Pmod_apply (make_mod, spec_mod);
      pmod_loc = loc;
      pmod_attributes = [] }
  in
  { pstr_desc = Pstr_include {
      pincl_mod = include_expr;
      pincl_loc = loc;
      pincl_attributes = [];
    };
    pstr_loc = loc }

let gen_include_two ~loc ~spec_module ~behavior_module : structure_item =
  let make_lid = make_functor_lid ~loc ~dsl_module:"Behavior_GWT" in
  let make_mod =
    { pmod_desc = Pmod_ident { txt = make_lid; loc };
      pmod_loc = loc;
      pmod_attributes = [] }
  in
  let spec_mod =
    { pmod_desc = Pmod_ident { txt = Lident spec_module; loc };
      pmod_loc = loc;
      pmod_attributes = [] }
  in
  let behavior_mod =
    { pmod_desc = Pmod_ident { txt = Lident behavior_module; loc };
      pmod_loc = loc;
      pmod_attributes = [] }
  in
  let applied_once =
    { pmod_desc = Pmod_apply (make_mod, spec_mod);
      pmod_loc = loc;
      pmod_attributes = [] }
  in
  let applied_twice =
    { pmod_desc = Pmod_apply (applied_once, behavior_mod);
      pmod_loc = loc;
      pmod_attributes = [] }
  in
  { pstr_desc = Pstr_include {
      pincl_mod = applied_twice;
      pincl_loc = loc;
      pincl_attributes = [];
    };
    pstr_loc = loc }

(** Emit [open <name>] at [loc]. *)
let gen_open ~loc name : structure_item =
  { pstr_desc = Pstr_open {
      popen_expr = { pmod_desc = Pmod_ident { txt = Lident name; loc };
                     pmod_loc = loc;
                     pmod_attributes = [] };
      popen_override = Fresh;
      popen_loc = loc;
      popen_attributes = [];
    };
    pstr_loc = loc }

(** Insert [items] into [lst] directly after index [idx] (0-based). *)
let insert_after_many (lst : 'a list) (idx : int) (items : 'a list) : 'a list =
  let rec loop i = function
    | [] -> items  (* append at end if idx past list length *)
    | x :: rest when i = idx -> x :: items @ rest
    | x :: rest -> x :: loop (i + 1) rest
  in
  loop 0 lst

let kinds_list_for_error () =
  "folder base names StateChange / StateView / Automation / \
   InboundTranslation / OutboundTranslation (with optional `Slice` or \
   `Slices` suffix), or a filename / folder containing `Projection` \
   or `Behavior`"

let transform (str : structure) : structure =
  match find_gwt_attr str with
  | None -> str
  | Some (attr, attr_loc) ->
    let fname = attr_loc.loc_start.pos_fname in
    let kind =
      match derive_kind fname with
      | Some k -> k
      | None ->
        Location.raise_errorf ~loc:attr_loc
          "@@reventless.gwt: cannot infer DSL kind from filename or folder. \
           Expected %s."
          (kinds_list_for_error ())
    in
    let payload = parse_payload attr in
    let body = strip_gwt_attr str in
    (* Resolution order:
       1. Two-arg payload: Behavior DSL only, two-module form.
       2. One-arg payload: external Spec, no local binding required.
       3. Empty + Behavior kind: two local modules (Spec, Behavior).
       4. Empty + other kind: one local module if present, else derive Spec
          from the filename stem (external Spec).  *)
    let (spec_name, behavior_name_opt, spec_is_external) =
      match payload, kind with
      | Two (spec, behavior), "Behavior" -> (spec, Some behavior, false)
      | Two _, _ ->
        Location.raise_errorf ~loc:attr_loc
          "@@reventless.gwt: a two-module payload is only valid for the \
           Behavior DSL. Got kind %s." kind
      | One spec, "Behavior" ->
        Location.raise_errorf ~loc:attr_loc
          "@@reventless.gwt: the Behavior DSL needs a (Spec, Behavior) pair. \
           Use @@reventless.gwt(%s, <Behavior>)." spec
      | One spec, _ -> (spec, None, true)
      | Empty, "Behavior" ->
        (match find_first_top_modules 2 body with
         | [spec; behavior] -> (spec, Some behavior, false)
         | _ ->
           Location.raise_errorf ~loc:attr_loc
             "@@reventless.gwt: Behavior DSL needs two top-level modules \
              (Spec followed by Behavior). Found fewer. Either declare both \
              or use @@reventless.gwt(Spec, Behavior).")
      | Empty, _ ->
        (match find_first_top_modules 1 body with
         | [name] -> (name, None, false)
         | _ ->
           (match Util.spec_name_from_gwt_filename fname with
            | Some name -> (name, None, true)
            | None ->
              Location.raise_errorf ~loc:attr_loc
                "@@reventless.gwt: no top-level module found and cannot \
                 derive a Spec module name from the filename. Expected the \
                 file stem to end in one of: _GWT, GwtTest, Gwt. Either \
                 rename the file, declare a module, or use \
                 @@reventless.gwt(SpecModule)."))
    in
    let open_item = gen_open ~loc:attr_loc spec_name in
    let include_item =
      match behavior_name_opt with
      | Some bname ->
        gen_include_two ~loc:attr_loc ~spec_module:spec_name ~behavior_module:bname
      | None ->
        gen_include_one ~loc:attr_loc ~kind ~spec_module:spec_name
    in
    let injection_items =
      (if Util.has_open spec_name body then [] else [open_item])
      @ [include_item]
    in
    if spec_is_external then
      (* No local module anchor — prepend at the top of the structure.
         The attribute conventionally lives at file top, so this matches the
         attribute's original position. *)
      injection_items @ body
    else
      let inject_after_idx =
        match behavior_name_opt with
        | Some bname ->
          (match find_module_index bname body with
           | Some i -> i
           | None ->
             Location.raise_errorf ~loc:attr_loc
               "@@reventless.gwt: behavior module %s not found at top level." bname)
        | None ->
          (match find_module_index spec_name body with
           | Some i -> i
           | None ->
             Location.raise_errorf ~loc:attr_loc
               "@@reventless.gwt: spec module %s not found at top level." spec_name)
      in
      insert_after_many body inject_after_idx injection_items
