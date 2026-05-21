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
         resolve; it does NOT need to be a local binding in this file. The
         payload may be a qualified path (e.g.
         [Categories_Projections.CategoryMapping]) — used by the
         MultiSourceProjection DSL to point at one mapping inside a
         [_Projections] file. When the payload is qualified the [open]
         injection is suppressed (qualified references are kept explicit
         in the test body).}
      {- [@@reventless.gwt(SpecModule, BehaviorModule)] — for the Behavior /
         Projection DSLs, which take two functor arguments.}}

    Supported DSL kinds (canonical tokens, shared with [@@reventless.spec]
    via [Util.derive_gwt_kind]):
    {ul
      {- [Automation]                 (was [AutomationSlice], Plan 01)}
      {- [InboundTranslation]         (was [InboundTranslationSlice], Plan 01)}
      {- [OutboundTranslation]        (was [OutboundTranslationSlice], Plan 01)}
      {- [Behavior]                   (Aggregate folder uses
                                       [MakeFromAggregate]; StateChangeSlice
                                       folder uses [Make])}
      {- [Projection]                 (StateViewSlice, Plan 02 Phase 3b)}
      {- [MultiSourceProjection]      (Aggregate-pattern ReadModel folder.
                                       Requires an explicit Mapping payload —
                                       e.g.
                                       [@@reventless.gwt(Foo_Projections.BarMapping)]
                                       — because the bare filename stem
                                       resolves to the ReadModel spec, not
                                       the mapping module the DSL needs.)}
      {- [Flow]                       (cross-slice / cross-plugin flow. The
                                       [Flow/] folder or a [*Flow] stem injects
                                       only [open ReventlessGwt.Flow_GWT] — no
                                       [include], no Spec: the author builds the
                                       chain from the per-step functors.)}
      {- [Delegate]                   (ExtensionPoint / Extension boundary.
                                       [ExtensionPoint/] folder or a
                                       [*ExtensionPointMapping] stem →
                                       [Delegate_GWT.FromExtensionPoint(<Stem>)];
                                       [Extension/] folder or a [*_Extension]
                                       stem → [Delegate_GWT.FromExtension(
                                       <Stem>.Mapping)], applied to the
                                       extension file's inner [Mapping].)}}

    Folder segments match on the short base form ("StateChange"), the long
    form ("StateChangeSlice"), or the plural form ("StateChangeSlices"), as
    well as any filename substring that contains a kind token. When several
    path segments match, the closest-to-file segment wins. The
    Aggregate-pattern architectural folders [Aggregate] / [ReadModel] (and
    their plurals) are also recognised.

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

(** Render a Longident as a dotted string. Returns [None] on functor
    application nodes ([Lapply]) since they have no GWT meaning. *)
let rec longident_to_dotted (lid : Longident.t) : string option =
  match lid with
  | Lident n -> Some n
  | Ldot (parent, n) ->
    (match longident_to_dotted parent with
     | Some p -> Some (p ^ "." ^ n)
     | None -> None)
  | Lapply _ -> None

(** Extract a module path (plain or qualified) from an expression node. The
    GWT attribute payload sees module references parsed as either an
    [Pexp_ident] (lowercase final segment) or [Pexp_construct] (uppercase
    final segment). Both wrap the same [Longident.t]. *)
let qualified_name_of_expr (expr : expression) : string option =
  match expr.pexp_desc with
  | Pexp_construct ({ txt; _ }, None) -> longident_to_dotted txt
  | Pexp_ident { txt; _ } -> longident_to_dotted txt
  | _ -> None

let parse_payload (attr : attribute) : payload =
  match attr.attr_payload with
  | PStr [] -> Empty
  | PStr [{ pstr_desc = Pstr_eval (expr, _); _ }] ->
    (match expr.pexp_desc with
     | Pexp_tuple [a; b] ->
       (match qualified_name_of_expr a, qualified_name_of_expr b with
        | Some na, Some nb -> Two (na, nb)
        | _ -> Empty)
     | _ ->
       (match qualified_name_of_expr expr with
        | Some n -> One n
        | None -> Empty))
  | _ -> Empty

let is_qualified_name (s : string) : bool = String.contains s '.'

(** Build a [Longident.t] from a dotted path string. ["A.B.C"] becomes
    [Ldot(Ldot(Lident "A", "B"), "C")]. Empty input is invalid. *)
let lident_of_dotted (s : string) : Longident.t =
  match String.split_on_char '.' s with
  | [] -> failwith "lident_of_dotted: empty"
  | hd :: tl ->
    List.fold_left (fun acc seg -> Longident.Ldot (acc, seg)) (Lident hd) tl

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
    [<DSL>_GWT.<functor_name>]; for downstream callers, keep the full
    [ReventlessGwt.<DSL>_GWT.<functor_name>] path. The functor name is
    parameterised so the Aggregate-folder variant can emit
    [Behavior_GWT.MakeFromAggregate] alongside the default
    [<Kind>_GWT.Make]. *)
let make_functor_lid ~loc ~dsl_module ~functor_name =
  if is_in_gwt_package loc then
    Ldot (Lident dsl_module, functor_name)
  else
    Ldot (Ldot (Lident "ReventlessGwt", dsl_module), functor_name)

let gen_include_one ~loc ~kind ~functor_name ~spec_module : structure_item =
  let make_lid = make_functor_lid ~loc ~dsl_module:(kind ^ "_GWT") ~functor_name in
  let make_mod =
    { pmod_desc = Pmod_ident { txt = make_lid; loc };
      pmod_loc = loc;
      pmod_attributes = [] }
  in
  let spec_mod =
    { pmod_desc = Pmod_ident { txt = lident_of_dotted spec_module; loc };
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

let gen_include_two ~loc ~kind ~functor_name ~spec_module ~impl_module : structure_item =
  let make_lid = make_functor_lid ~loc ~dsl_module:(kind ^ "_GWT") ~functor_name in
  let make_mod =
    { pmod_desc = Pmod_ident { txt = make_lid; loc };
      pmod_loc = loc;
      pmod_attributes = [] }
  in
  let spec_mod =
    { pmod_desc = Pmod_ident { txt = lident_of_dotted spec_module; loc };
      pmod_loc = loc;
      pmod_attributes = [] }
  in
  let impl_mod =
    { pmod_desc = Pmod_ident { txt = lident_of_dotted impl_module; loc };
      pmod_loc = loc;
      pmod_attributes = [] }
  in
  let applied_once =
    { pmod_desc = Pmod_apply (make_mod, spec_mod);
      pmod_loc = loc;
      pmod_attributes = [] }
  in
  let applied_twice =
    { pmod_desc = Pmod_apply (applied_once, impl_mod);
      pmod_loc = loc;
      pmod_attributes = [] }
  in
  { pstr_desc = Pstr_include {
      pincl_mod = applied_twice;
      pincl_loc = loc;
      pincl_attributes = [];
    };
    pstr_loc = loc }

(* Plan 02 Phase 3b: Behavior and Projection DSLs are both two-functor. The
   shared check is used in payload validation and in default Empty-payload
   resolution. MultiSourceProjection (Aggregate-pattern ReadModel) is a
   one-functor DSL even though it lives next to Projection. *)
let is_two_arg_kind = function
  | "Behavior" | "Projection" -> true
  | _ -> false

(** Is this GWT file testing an ExtensionPoint mapping (rather than an
    Extension delegate)? True for files inside an [ExtensionPoint/] folder or
    whose stem contains [ExtensionPointMapping]. *)
let is_extensionpoint_file fname =
  Util.is_in_folder fname "ExtensionPoint" || Util.is_extensionpointmapping_filename fname

(** Pick the GWT functor entry-point name for a given (kind, file-context).
    Default is [Make]. Two kinds need a context-dependent functor:
    - [Behavior] in an Aggregate folder → [Behavior_GWT.MakeFromAggregate]
      (the Aggregate.Spec / Behavior.T surface differs from the slice form).
    - [Delegate] → [Delegate_GWT.FromExtensionPoint] for an ExtensionPoint
      mapping, else [Delegate_GWT.FromExtension] for an Extension delegate. *)
let functor_name_for ~kind ~fname =
  if kind = "Behavior" && Util.is_in_aggregate_folder fname then
    "MakeFromAggregate"
  else if kind = "Delegate" then
    (if is_extensionpoint_file fname then "FromExtensionPoint" else "FromExtension")
  else
    "Make"

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
   InboundTranslation / OutboundTranslation (short, plural, or with \
   `Slice` / `Slices` suffix — e.g. Automation, Automations, \
   AutomationSlice, AutomationSlices); the Aggregate-pattern folders \
   Aggregate / ReadModel (plural also accepted); the cross-plugin boundary \
   folders ExtensionPoint / Extension (Delegate kind); the cross-slice Flow \
   folder (Flow kind); or a filename / folder containing `Projection`, \
   `Behavior`, `ExtensionPoint`, `Extension`, or `Flow`"

(** Detect a companion [<Stem>_Fixtures.res] next to the GWT file.
    Returns the module name if the sibling file exists, else [None].
    Resolves [fname] to an absolute path so the lookup works regardless of
    the cwd the compiler runs the PPX under. *)
let companion_fixtures_module (fname : string) : string option =
  match Util.spec_name_from_gwt_filename fname with
  | None -> None
  | Some stem ->
    let abs =
      if Filename.is_relative fname then Filename.concat (Sys.getcwd ()) fname
      else fname
    in
    let dir = Filename.dirname abs in
    let candidate_module = stem ^ "_Fixtures" in
    let candidate_file = Filename.concat dir (candidate_module ^ ".res") in
    if Sys.file_exists candidate_file then Some candidate_module else None

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
    if String.equal kind "Flow" then begin
      (* The Flow kind is functor-less: a flow references several slice modules
         and has no single Spec, so there is nothing to apply a `Make` to. The
         author instantiates the per-step functors (CommandStep / AutomationStep
         / ViewStep / OutboundStep) themselves, so the PPX only needs to bring
         the Flow_GWT module into scope. No `include`, no Spec resolution. *)
      let loc = attr_loc in
      let flow_lid =
        if is_in_gwt_package loc then Lident "Flow_GWT"
        else Ldot (Lident "ReventlessGwt", "Flow_GWT")
      in
      let open_item =
        { pstr_desc = Pstr_open {
            popen_expr = { pmod_desc = Pmod_ident { txt = flow_lid; loc };
                           pmod_loc = loc; pmod_attributes = [] };
            popen_override = Fresh; popen_loc = loc; popen_attributes = [] };
          pstr_loc = loc }
      in
      let fixtures_open =
        match companion_fixtures_module fname with
        | Some name when not (Util.has_open name body) -> [gen_open ~loc name]
        | _ -> []
      in
      (open_item :: fixtures_open) @ body
    end
    else
    let functor_name = functor_name_for ~kind ~fname in
    (* Resolution order:
       1. Two-arg payload: Behavior / Projection DSL only, two-module form.
       2. One-arg payload: external Spec, no local binding required. May be
          a qualified path (e.g. [Foo_Projections.BarMapping]) for the
          MultiSourceProjection DSL.
       3. Empty + two-arg kind: two local modules (Spec, Behavior/Projection).
       4. Empty + one-arg kind: one local module if present, else derive
          Spec from the filename stem (external Spec). MultiSourceProjection
          rejects this branch — the filename stem maps to the ReadModel
          spec, not the Mapping module the DSL needs. *)
    let two_arg = is_two_arg_kind kind in
    let (spec_name, impl_name_opt, spec_is_external) =
      match payload, two_arg with
      | Two (spec, impl), true ->
        (* Qualified components can never be top-level modules in the file,
           so a qualified payload forces external-spec injection mode. *)
        let external_ = is_qualified_name spec || is_qualified_name impl in
        (spec, Some impl, external_)
      | Two _, false ->
        Location.raise_errorf ~loc:attr_loc
          "@@reventless.gwt: a two-module payload is only valid for the \
           Behavior or Projection DSL. Got kind %s." kind
      | One spec, true ->
        Location.raise_errorf ~loc:attr_loc
          "@@reventless.gwt: the %s DSL needs a (Spec, %s) pair. \
           Use @@reventless.gwt(%s, <%s>)." kind kind spec kind
      | One spec, false -> (spec, None, true)
      | Empty, true ->
        (match find_first_top_modules 2 body with
         | [spec; impl] -> (spec, Some impl, false)
         | _ ->
           (* Try external Spec derivation: filename stem with GWT suffix
              stripped, paired with a derived impl module name (e.g.
              [<Stem>_Behavior] / [<Stem>_Projection]). *)
           (match Util.spec_name_from_gwt_filename fname with
            | Some stem ->
              let impl = stem ^ "_" ^ kind in
              (stem, Some impl, true)
            | None ->
              Location.raise_errorf ~loc:attr_loc
                "@@reventless.gwt: %s DSL needs two top-level modules \
                 (Spec followed by %s). Found fewer. Either declare both \
                 or use @@reventless.gwt(Spec, %s)." kind kind kind))
      | Empty, false when kind = "MultiSourceProjection" ->
        Location.raise_errorf ~loc:attr_loc
          "@@reventless.gwt: the MultiSourceProjection DSL needs an \
           explicit Mapping payload, e.g. \
           @@reventless.gwt(<Spec>_Projections.<Source>Mapping). The \
           bare form has no way to pick which mapping inside the \
           Projections file to test."
      | Empty, false ->
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
    let spec_is_qualified = is_qualified_name spec_name in
    (* The Delegate kind's Extension flavour applies the functor to the inner
       [Mapping] module of the extension file (the convention is
       [Extension/<Name>_Extension.res] with a [module Mapping]), so the functor
       argument is [<Stem>.Mapping]. The [open <Stem>] injection still uses the
       bare file module so [Mapping] (and its [ExtensionPoint] / [Delegate]) read
       unqualified in the test body. Every other kind applies the functor to the
       spec module directly. *)
    let functor_arg =
      if kind = "Delegate" && String.equal functor_name "FromExtension" then
        spec_name ^ ".Mapping"
      else
        spec_name
    in
    let include_item =
      match impl_name_opt with
      | Some impl_name ->
        gen_include_two ~loc:attr_loc ~kind ~functor_name
          ~spec_module:spec_name ~impl_module:impl_name
      | None ->
        gen_include_one ~loc:attr_loc ~kind ~functor_name
          ~spec_module:functor_arg
    in
    let fixtures_open =
      match companion_fixtures_module fname with
      | Some name when not (Util.has_open name body) ->
        [gen_open ~loc:attr_loc name]
      | _ -> []
    in
    (* Skip the [open <Spec>] injection when the Spec is referenced via a
       qualified path. [open Foo.Bar.Baz] would import the leaf module's
       contents into the test scope, which is rarely what the test author
       wants — the convention is to keep qualified references explicit. *)
    let spec_open_items =
      if spec_is_qualified then []
      else if Util.has_open spec_name body then []
      else [gen_open ~loc:attr_loc spec_name]
    in
    let injection_items =
      spec_open_items
      @ fixtures_open
      @ [include_item]
    in
    if spec_is_external then
      (* No local module anchor — prepend at the top of the structure.
         The attribute conventionally lives at file top, so this matches the
         attribute's original position. *)
      injection_items @ body
    else
      let inject_after_idx =
        match impl_name_opt with
        | Some iname ->
          (match find_module_index iname body with
           | Some i -> i
           | None ->
             Location.raise_errorf ~loc:attr_loc
               "@@reventless.gwt: implementation module %s not found at top level." iname)
        | None ->
          (match find_module_index spec_name body with
           | Some i -> i
           | None ->
             Location.raise_errorf ~loc:attr_loc
               "@@reventless.gwt: spec module %s not found at top level." spec_name)
      in
      insert_after_many body inject_after_idx injection_items
