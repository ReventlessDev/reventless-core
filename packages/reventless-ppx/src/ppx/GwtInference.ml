open Ppxlib

(** @@reventless.gwt — file-level annotation that eliminates the
    [include ReventlessGwt.<Kind>_GWT.Make(<Spec>)] line at the top of every
    GWT test file.

    Payload forms:
    {ul
      {- [@@reventless.gwt] — Kind inferred from filename/folder;
         Spec inferred as the first top-level module.}
      {- [@@reventless.gwt(SpecModule)] — Kind inferred; Spec explicit.}
      {- [@@reventless.gwt(SpecModule, BehaviorModule)] — for the Behavior DSL,
         which takes two functor arguments.}}

    Supported DSL kinds (canonical tokens, recognised as substrings of the
    filename or any folder-path segment):
    {ul
      {- [AutomationSlice]}
      {- [InboundTranslationSlice]}
      {- [OutboundTranslationSlice]}
      {- [StateChangeSlice]}
      {- [StateViewSlice]}
      {- [Projection]}
      {- [Behavior]}}

    The PPX strips the attribute and inserts the generated [include] directly
    after the spec module's definition in the structure (or after the behavior
    module, for Behavior DSLs). *)

let attr_name = "reventless.gwt"

(** Canonical Kind tokens, longest-first so substring matches prefer the most
    specific label (e.g. [StateViewSlice] wins over [Slice] alone). *)
let kinds_longest_first = [
  "OutboundTranslationSlice";
  "InboundTranslationSlice";
  "StateChangeSlice";
  "AutomationSlice";
  "StateViewSlice";
  "Projection";
  "Behavior";
]

type payload =
  | Empty
  | One of string
  | Two of string * string

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

let basename_without_ext fname =
  let base = Filename.basename fname in
  match String.index_opt base '.' with
  | Some i -> String.sub base 0 i
  | None -> base

let derive_kind fname : string option =
  let file_stem = basename_without_ext fname in
  let dir = Filename.dirname fname in
  let parts = String.split_on_char '/' dir in
  let first_match haystack =
    List.find_opt (fun k -> contains_substring haystack k) kinds_longest_first
  in
  match first_match file_stem with
  | Some k -> Some k
  | None ->
    let rec scan = function
      | [] -> None
      | part :: rest ->
        (match first_match part with
         | Some k -> Some k
         | None -> scan rest)
    in
    scan parts

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

(** Insert [item] into [lst] directly after index [idx] (0-based). *)
let insert_after (lst : 'a list) (idx : int) (item : 'a) : 'a list =
  let rec loop i = function
    | [] -> [item]  (* append at end if idx past list length *)
    | x :: rest when i = idx -> x :: item :: rest
    | x :: rest -> x :: loop (i + 1) rest
  in
  loop 0 lst

let kinds_list_for_error () =
  String.concat ", " (List.sort compare kinds_longest_first)

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
           The filename or some folder segment must contain one of: %s."
          (kinds_list_for_error ())
    in
    let payload = parse_payload attr in
    let body = strip_gwt_attr str in
    let (spec_name, behavior_name_opt) =
      match payload, kind with
      | Two (spec, behavior), "Behavior" -> (spec, Some behavior)
      | Two _, _ ->
        Location.raise_errorf ~loc:attr_loc
          "@@reventless.gwt: a two-module payload is only valid for the \
           Behavior DSL. Got kind %s." kind
      | One spec, "Behavior" ->
        Location.raise_errorf ~loc:attr_loc
          "@@reventless.gwt: the Behavior DSL needs a (Spec, Behavior) pair. \
           Use @@reventless.gwt(%s, <Behavior>)." spec
      | One spec, _ -> (spec, None)
      | Empty, "Behavior" ->
        (match find_first_top_modules 2 body with
         | [spec; behavior] -> (spec, Some behavior)
         | _ ->
           Location.raise_errorf ~loc:attr_loc
             "@@reventless.gwt: Behavior DSL needs two top-level modules \
              (Spec followed by Behavior). Found fewer. Either declare both \
              or use @@reventless.gwt(Spec, Behavior).")
      | Empty, _ ->
        (match find_first_top_modules 1 body with
         | [name] -> (name, None)
         | _ ->
           Location.raise_errorf ~loc:attr_loc
             "@@reventless.gwt: no top-level module found to use as the Spec. \
              Either declare a module FooSpec = { ... } block or use \
              @@reventless.gwt(SpecModule).")
    in
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
    let include_item =
      match behavior_name_opt with
      | Some bname ->
        gen_include_two ~loc:attr_loc ~spec_module:spec_name ~behavior_module:bname
      | None ->
        gen_include_one ~loc:attr_loc ~kind ~spec_module:spec_name
    in
    insert_after body inject_after_idx include_item
