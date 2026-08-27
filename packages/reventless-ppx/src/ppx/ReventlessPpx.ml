open Ppxlib

(* Implementation kinds — the second half of the Spec/Implementation split.
   Each kind has a corresponding [@@reventless.<kind>] attribute that
   auto-injects [open <Spec>; module Spec = <Spec>; let moduleUrl = ...].
   The Spec module name is derived from the filename: a [_<Kind>] or
   [<Kind>] suffix is stripped. *)
type impl_kind =
  | Behavior      (* StateChangeSlice + Aggregate *)
  | Projection    (* StateViewSlice *)
  | Automation    (* AutomationSlice *)
  | Translation   (* InboundTranslationSlice + OutboundTranslationSlice *)
  | Mappings      (* multi-source Aggregate _Mappings.res + ReadModel _Projections.res *)
  | Extension     (* Extension/<Name>_Extension.res *)
  | Task          (* Task/<Name>.res *)

let impl_kind_name = function
  | Behavior -> "Behavior"
  | Projection -> "Projection"
  | Automation -> "Automation"
  | Translation -> "Translation"
  | Mappings -> "Mappings"
  | Extension -> "Extension"
  | Task -> "Task"

let impl_kind_attr_name = function
  | Behavior -> "reventless.behavior"
  | Projection -> "reventless.projection"
  | Automation -> "reventless.automation"
  | Translation -> "reventless.translation"
  | Mappings -> "reventless.mappings"
  | Extension -> "reventless.extension"
  | Task -> "reventless.task"

(* Kinds that follow the "open <Spec>; module Spec = <Spec>; let moduleUrl"
   classic implementation shape. The new Mappings/Extension/Task kinds have
   bespoke generation logic. *)
let classic_impl_kinds = [Behavior; Projection; Automation; Translation]

let all_impl_kinds = [Behavior; Projection; Automation; Translation; Mappings; Extension; Task]

type mode =
  | Spec of string option
  | Implementation of impl_kind * string option

let detect_mode (str : structure) =
  let rec scan = function
    | [] -> None
    | item :: rest ->
      (match item.pstr_desc with
       | Pstr_attribute attr ->
         if String.equal attr.attr_name.txt "reventless.spec" then
           let name = Util.get_string_payload attr in
           Some (Spec name, attr.attr_loc)
         else
           let matched_kind =
             List.find_opt (fun k ->
               String.equal attr.attr_name.txt (impl_kind_attr_name k)
             ) all_impl_kinds
           in
           (match matched_kind with
            | Some k ->
              let spec_name =
                match Util.get_string_payload attr with
                | Some s -> Some s
                | None -> Util.get_ident_payload attr
              in
              Some (Implementation (k, spec_name), attr.attr_loc)
            | None -> scan rest)
       | _ -> scan rest)
  in
  scan str

let has_dcb_tags_attr (str : structure) =
  List.exists (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_attribute attr -> String.equal attr.attr_name.txt "reventless.dcbTags"
    | _ -> false
  ) str

let strip_ppx_attrs (str : structure) : structure =
  let impl_attr_names = List.map impl_kind_attr_name all_impl_kinds in
  let is_ppx_attr name =
    String.equal name "reventless.spec"
    || String.equal name "reventless.dcbTags"
    (* [@@reventless.async] marks an Aggregate or StateChangeSlice spec for
       async command dispatch (CommandPending response). The PPX consumes
       the attribute so it doesn't reach the compiler; the plugin generator
       reads the raw .res source to flip the emitted Make → MakeAsync. *)
    || String.equal name "reventless.async"
    (* [@@reventless.systemCallable] marks a StateChangeSlice / StateViewSlice
       spec whose GraphQL fields a deploy-time IAM (SigV4) system caller must
       invoke. Like reventless.async it is generator-read (raw source →
       ~systemCallableComponents on Plugin.make); stripped here for hygiene —
       the compiler also tolerates it unconsumed, so older published PPX
       binaries keep working. *)
    || String.equal name "reventless.systemCallable"
    || List.exists (String.equal name) impl_attr_names
  in
  List.filter (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_attribute attr -> not (is_ppx_attr attr.attr_name.txt)
    | _ -> true
  ) str

let gen_open ~loc name =
  let lid = { txt = Lident name; loc } in
  { pstr_desc = Pstr_open {
      popen_expr = { pmod_desc = Pmod_ident lid; pmod_loc = loc; pmod_attributes = [] };
      popen_override = Fresh;
      popen_loc = loc;
      popen_attributes = [];
    };
    pstr_loc = loc }

let gen_name ~loc value =
  [%stri let name = [%e Ast_builder.Default.estring ~loc value]]

let gen_module_id ~loc =
  let lid = { txt = Ldot (Ldot (Lident "Reventless", "Id"), "String"); loc } in
  { pstr_desc = Pstr_module {
      pmb_name = { txt = Some "Id"; loc };
      pmb_expr = { pmod_desc = Pmod_ident lid; pmod_loc = loc; pmod_attributes = [] };
      pmb_attributes = [];
      pmb_loc = loc;
    };
    pstr_loc = loc }

let gen_module_alias ~loc ~alias_name ~target_name =
  let lid = { txt = Lident target_name; loc } in
  { pstr_desc = Pstr_module {
      pmb_name = { txt = Some alias_name; loc };
      pmb_expr = { pmod_desc = Pmod_ident lid; pmod_loc = loc; pmod_attributes = [] };
      pmb_attributes = [];
      pmb_loc = loc;
    };
    pstr_loc = loc }

let derive_spec_name ~loc name_opt =
  match name_opt with
  | Some n -> n
  | None ->
    let entity = Util.filename_to_name loc.loc_start.pos_fname in
    match ModuleUrl.find_package_for loc with
    | Some pkg when ModuleUrl.is_spec_namespace pkg ->
      let plugin = ModuleUrl.plugin_name_from_namespace pkg in
      plugin ^ "." ^ entity
    | _ -> entity

(* Derive the Spec module name for an implementation file from its filename.
   Recognises two conventions:
   - [X_<Kind>.res] (slice convention, e.g. [ArchiveCategory_Behavior.res] → [ArchiveCategory]).
   - [X<Kind>.res] (Aggregate convention, e.g. [ProductBehavior.res] → [Product]).
   Falls back to the bare filename stem if neither suffix is present. *)
let derive_impl_spec_name ~kind fname =
  let stem =
    let base = Filename.basename fname in
    match String.index_opt base '.' with
    | Some i -> String.sub base 0 i
    | None -> base
  in
  let kind_name = impl_kind_name kind in
  let underscored = "_" ^ kind_name in
  let stripped_under = Util.strip_suffix stem underscored in
  if not (String.equal stripped_under stem) && String.length stripped_under > 0 then
    stripped_under
  else
    let stripped_bare = Util.strip_suffix stem kind_name in
    if not (String.equal stripped_bare stem) && String.length stripped_bare > 0 then
      stripped_bare
    else
      stem

(* --- Phase 6.2: ReadModel auto-defaults --- *)

let gen_open_ep_mapping ~loc =
  let lid = { txt = Ldot (Lident "ReventlessInfra", "ExtensionPointMapping"); loc } in
  { pstr_desc = Pstr_open {
      popen_expr = { pmod_desc = Pmod_ident lid; pmod_loc = loc; pmod_attributes = [] };
      popen_override = Fresh;
      popen_loc = loc;
      popen_attributes = [];
    };
    pstr_loc = loc }

let gen_open_readmodel ~loc =
  let lid = { txt = Ldot (Lident "Reventless", "ReadModel"); loc } in
  { pstr_desc = Pstr_open {
      popen_expr = { pmod_desc = Pmod_ident lid; pmod_loc = loc; pmod_attributes = [] };
      popen_override = Fresh;
      popen_loc = loc;
      popen_attributes = [];
    };
    pstr_loc = loc }

let gen_open_projection ~loc =
  let lid = { txt = Ldot (Lident "Reventless", "Projection"); loc } in
  { pstr_desc = Pstr_open {
      popen_expr = { pmod_desc = Pmod_ident lid; pmod_loc = loc; pmod_attributes = [] };
      popen_override = Fresh;
      popen_loc = loc;
      popen_attributes = [];
    };
    pstr_loc = loc }

let gen_config_let ~loc ?owner_index body =
  StateAnnotations.generate_config ~loc ?owner_index body

let gen_sub_id_config ~loc body =
  StateAnnotations.generate_sub_id_config ~loc body

let gen_make_id ~loc body =
  StateAnnotations.generate_make_id ~loc body

(* --- Phase 6.1: @reventless.delegate inside Delegate modules --- *)

let gen_schema_unit_type ~loc name =
  let schema_attr = { attr_name = { txt = "schema"; loc };
                      attr_payload = PStr [];
                      attr_loc = loc } in
  let unit_lid = { txt = Lident "unit"; loc } in
  let unit_type = { ptyp_desc = Ptyp_constr (unit_lid, []);
                    ptyp_loc = loc;
                    ptyp_loc_stack = [];
                    ptyp_attributes = [] } in
  let type_decl = { ptype_name = { txt = name; loc };
                    ptype_params = [];
                    ptype_cstrs = [];
                    ptype_kind = Ptype_abstract;
                    ptype_private = Public;
                    ptype_manifest = Some unit_type;
                    ptype_attributes = [schema_attr];
                    ptype_loc = loc } in
  { pstr_desc = Pstr_type (Nonrecursive, [type_decl]);
    pstr_loc = loc }

let transform_delegate_module ~loc ~specifier (mb : module_binding) : module_binding =
  let attrs = List.filter (fun (a : attribute) ->
    not (String.equal a.attr_name.txt "reventless.delegate")
  ) mb.pmb_attributes in
  match mb.pmb_expr.pmod_desc with
  | Pmod_structure body ->
    let body = DcbTagInference.transform_structure ~loc body in
    let prefix =
      (if not (Util.has_module_binding "Id" body) then [gen_module_id ~loc] else [])
      @ (if not (Util.has_type_binding "command" body) then [gen_schema_unit_type ~loc "command"] else [])
    in
    let auth_suffix =
      if Util.has_let_binding "commandAuthorization" body then []
      else [AuthorizationInjection.gen_command_authorization ~loc (AuthorizationInjection.default_rule_expr ~loc)]
    in
    let suffix =
      (if not (Util.has_type_binding "error" body) then [gen_schema_unit_type ~loc "error"] else [])
      @ (if not (Util.has_let_binding "moduleUrl" body) then [ModuleUrl.gen_module_url ~loc specifier] else [])
      @ auth_suffix
    in
    let new_body = { mb.pmb_expr with pmod_desc = Pmod_structure (prefix @ body @ suffix) } in
    { mb with pmb_expr = new_body; pmb_attributes = attrs }
  | _ -> { mb with pmb_attributes = attrs }

(* --- Retired: @reventless.projections (use @@reventless.mappings instead) --- *)

let raise_projections_retired ~loc =
  Location.raise_errorf ~loc
    "[reventless-ppx] @reventless.projections has been removed. Move the per-source `Mapping.Make` modules and the `let mappings: array<module(Mapping)> = [...]` line into the slice-local `_Projections.res` file (in `ReadModel/`) and add `@@reventless.mappings` at the top. The auto-generated Plugin.res then references the projections module directly: `Platform.ReadModel.Make(<Spec>, <Spec>_Projections)`."

(* Shared helper used by the file-level @@reventless.mappings /
   @@reventless.automation kinds — emits [module type Mapping = M.Mapping]. *)
let gen_module_type_mapping ~loc =
  { pstr_desc = Pstr_modtype {
      pmtd_name = { txt = "Mapping"; loc };
      pmtd_type = Some {
        pmty_desc = Pmty_ident { txt = Ldot (Lident "M", "Mapping"); loc };
        pmty_loc = loc;
        pmty_attributes = [];
      };
      pmtd_attributes = [];
      pmtd_loc = loc;
    };
    pstr_loc = loc }

let rec walk_structure ~specifier ~is_spec (str : structure) : structure =
  List.map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_module mb ->
      if Util.has_attr "reventless.projections" mb.pmb_attributes then
        raise_projections_retired ~loc:item.pstr_loc;
      let has_del = Util.has_attr "reventless.delegate" mb.pmb_attributes in
      let is_delegate = has_del ||
        (is_spec && (match mb.pmb_name.txt with Some "Delegate" -> true | _ -> false)) in
      let mb = if is_delegate then
        transform_delegate_module ~loc:item.pstr_loc ~specifier mb
      else mb in
      let mb = { mb with pmb_expr = walk_module_expr ~specifier ~is_spec mb.pmb_expr } in
      { item with pstr_desc = Pstr_module mb }
    | _ -> item
  ) str

and walk_module_expr ~specifier ~is_spec (me : module_expr) : module_expr =
  match me.pmod_desc with
  | Pmod_structure str ->
    { me with pmod_desc = Pmod_structure (walk_structure ~specifier ~is_spec str) }
  | Pmod_functor (param, body) ->
    { me with pmod_desc = Pmod_functor (param, walk_module_expr ~specifier ~is_spec body) }
  | Pmod_constraint (body, mty) ->
    { me with pmod_desc = Pmod_constraint (walk_module_expr ~specifier ~is_spec body, mty) }
  | _ -> me

let has_module_level_attr_deep (str : structure) =
  let found = ref false in
  let rec scan_str items =
    List.iter (fun (item : structure_item) ->
      match item.pstr_desc with
      | Pstr_module mb ->
        if Util.has_attr "reventless.delegate" mb.pmb_attributes
        then found := true;
        scan_mod mb.pmb_expr
      | _ -> ()
    ) items
  and scan_mod (me : module_expr) =
    match me.pmod_desc with
    | Pmod_structure s -> scan_str s
    | Pmod_functor (_, body) -> scan_mod body
    | Pmod_constraint (body, _) -> scan_mod body
    | _ -> ()
  in
  scan_str str;
  !found

let has_no_api_attr (str : structure) =
  let found = ref false in
  let rec scan_str items =
    List.iter (fun item ->
      match item.pstr_desc with
      | Pstr_type (_, decls) ->
        List.iter (fun td ->
          if List.exists (fun a -> String.equal a.attr_name.txt "noApi") td.ptype_attributes then
            found := true
          else
            (match td.ptype_kind with
             | Ptype_variant ctors ->
               List.iter (fun cd ->
                 if List.exists (fun a -> String.equal a.attr_name.txt "noApi") cd.pcd_attributes then
                   found := true
               ) ctors
             | _ -> ())
        ) decls
      | Pstr_module mb ->
        scan_mod mb.pmb_expr
      | _ -> ()
    ) items
  and scan_mod (me : module_expr) =
    match me.pmod_desc with
    | Pmod_structure s -> scan_str s
    | Pmod_functor (_, body) -> scan_mod body
    | Pmod_constraint (body, _) -> scan_mod body
    | _ -> ()
  in
  scan_str str;
  !found

(* --- Phase: file-level Mappings / Extension / Task PPX kinds ----------------- *)

(* Build [open Reventless.<Sub>]. Used for [Reventless.Projection] /
   [Reventless.Message] / [Reventless.EventMapping] / [Reventless.AutomationSlice]. *)
let gen_open_reventless_sub ~loc sub =
  let lid = { txt = Ldot (Lident "Reventless", sub); loc } in
  { pstr_desc = Pstr_open {
      popen_expr = { pmod_desc = Pmod_ident lid; pmod_loc = loc; pmod_attributes = [] };
      popen_override = Fresh;
      popen_loc = loc;
      popen_attributes = [];
    };
    pstr_loc = loc }

let gen_open_extension_mapping ~loc =
  let lid = { txt = Ldot (Lident "ReventlessInfra", "ExtensionMapping"); loc } in
  { pstr_desc = Pstr_open {
      popen_expr = { pmod_desc = Pmod_ident lid; pmod_loc = loc; pmod_attributes = [] };
      popen_override = Fresh;
      popen_loc = loc;
      popen_attributes = [];
    };
    pstr_loc = loc }

(* Build [module M = Reventless.<Domain>.Mappings.Make(<SpecName>)]. *)
let gen_mappings_make_call ~loc ~domain spec_name =
  let make_lid = Ldot (Ldot (Ldot (Lident "Reventless", domain), "Mappings"), "Make") in
  let spec_mod = {
    pmod_desc = Pmod_ident { txt = Lident spec_name; loc };
    pmod_loc = loc;
    pmod_attributes = [];
  } in
  { pstr_desc = Pstr_module {
      pmb_name = { txt = Some "M"; loc };
      pmb_expr = {
        pmod_desc = Pmod_apply ({
          pmod_desc = Pmod_ident { txt = make_lid; loc };
          pmod_loc = loc;
          pmod_attributes = [];
        }, spec_mod);
        pmod_loc = loc;
        pmod_attributes = [];
      };
      pmb_attributes = [];
      pmb_loc = loc;
    };
    pstr_loc = loc }

let gen_let_counter_none ~loc =
  [%stri let counter = None]

(* Injected inside `module Mapping` in @@reventless.extension files so the
   compiled .res.mjs exposes `Mapping.delegateModuleUrl` — the bundled Plugin
   EventCollector entry point reads it to dynamic-import the Delegate spec
   (Mapping.Delegate itself is erased in the JS export). *)
let gen_let_delegate_module_url ~loc =
  [%stri let delegateModuleUrl : string = Delegate.moduleUrl]

(* DCB Source detection — a module qualifies if its body has
   both [let name = "..."] and [@schema type event].
   The new file-level kinds (@@reventless.mappings, @@reventless.automation)
   scan their inner modules for these and inject [module Id] + dcbTags. *)
let module_looks_like_dcb_source (mb : module_binding) : bool =
  match mb.pmb_expr.pmod_desc with
  | Pmod_structure body ->
    let has_name_string =
      List.exists (fun (item : structure_item) ->
        match item.pstr_desc with
        | Pstr_value (_, bindings) ->
          List.exists (fun (vb : value_binding) ->
            match vb.pvb_pat.ppat_desc with
            | Ppat_var { txt = "name"; _ } ->
              (match vb.pvb_expr.pexp_desc with
               | Pexp_constant (Pconst_string _) -> true
               | _ -> false)
            | _ -> false
          ) bindings
        | _ -> false
      ) body
    in
    let has_schema_event_type =
      List.exists (fun (item : structure_item) ->
        match item.pstr_desc with
        | Pstr_type (_, decls) ->
          List.exists (fun (td : type_declaration) ->
            String.equal td.ptype_name.txt "event"
            && Util.has_attr "schema" td.ptype_attributes
          ) decls
        | _ -> false
      ) body
    in
    has_name_string && has_schema_event_type
  | _ -> false

let transform_dcb_source_module ~loc (mb : module_binding) : module_binding =
  match mb.pmb_expr.pmod_desc with
  | Pmod_structure body ->
    let body = DcbTagInference.transform_structure ~loc body in
    let body =
      if not (Util.has_module_binding "Id" body) then
        gen_module_id ~loc :: body
      else body
    in
    { mb with pmb_expr = { mb.pmb_expr with pmod_desc = Pmod_structure body } }
  | _ -> mb

(* One-level scan of file-level inner modules. *)
let walk_for_dcb_sources (str : structure) : structure =
  List.map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_module mb when module_looks_like_dcb_source mb ->
      let mb' = transform_dcb_source_module ~loc:item.pstr_loc mb in
      { item with pstr_desc = Pstr_module mb' }
    | _ -> item
  ) str

(* Detect the target domain for @@reventless.mappings from the file's folder. *)
type mappings_domain =
  | DomainProjection
  | DomainEventMapping
  | DomainAutomationSlice

let mappings_domain_module = function
  | DomainProjection -> "Projection"
  | DomainEventMapping -> "EventMapping"
  | DomainAutomationSlice -> "AutomationSlice"

let detect_mappings_domain ~loc fname =
  if Util.is_in_readmodel_folder fname then DomainProjection
  else if Util.is_in_aggregate_folder fname then DomainEventMapping
  else if Util.is_in_automationslice_folder fname then DomainAutomationSlice
  else
    Location.raise_errorf ~loc
      "[reventless-ppx] @@reventless.mappings must live under Aggregate/, ReadModel/, or AutomationSlice/ — got %s"
      fname

(* Spec name derivation for Mappings — handles _Mappings, _Projections, and
   the legacy non-underscored Mappings/Projections suffixes. *)
let derive_mappings_spec_name fname =
  let base = Filename.basename fname in
  let stem = match String.index_opt base '.' with
    | Some i -> String.sub base 0 i
    | None -> base
  in
  let try_strip suffix =
    let stripped = Util.strip_suffix stem suffix in
    if not (String.equal stripped stem) && String.length stripped > 0 then Some stripped
    else None
  in
  match try_strip "_Mappings" with
  | Some n -> n
  | None ->
    (match try_strip "_Projections" with
     | Some n -> n
     | None ->
       (match try_strip "Mappings" with
        | Some n -> n
        | None ->
          (match try_strip "Projections" with
           | Some n -> n
           | None -> stem)))

(* For Extension files. Filename forms:
   - <Name>_Extension.res (new convention) → strip _Extension
   - <Name>Extension.res  (legacy) → strip Extension *)
let derive_extension_name fname =
  let base = Filename.basename fname in
  let stem = match String.index_opt base '.' with
    | Some i -> String.sub base 0 i
    | None -> base
  in
  let try_strip suffix =
    let stripped = Util.strip_suffix stem suffix in
    if not (String.equal stripped stem) && String.length stripped > 0 then Some stripped
    else None
  in
  match try_strip "_Extension" with
  | Some n -> n
  | None ->
    (match try_strip "Extension" with
     | Some n -> n
     | None -> stem)

(* For Task files. Filename IS the task name (no suffix per Plan convention). *)
let derive_task_name fname =
  let base = Filename.basename fname in
  match String.index_opt base '.' with
  | Some i -> String.sub base 0 i
  | None -> base

(* Inject the AutomationSlice.Mappings.Make wrapper alongside the existing
   `open Spec; module Spec = Spec` injections. Used by @@reventless.automation
   in the merged AutomationSlice file shape (Plan 04 + the gap-closure plan). *)
let automation_mappings_extension ~loc ~spec_name body =
  let body = walk_for_dcb_sources body in
  let extra = ref [] in
  if not (Util.has_open_dotted "Reventless" "AutomationSlice" body) then
    extra := !extra @ [gen_open_reventless_sub ~loc "AutomationSlice"];
  if not (Util.has_module_binding "M" body) then
    extra := !extra @ [gen_mappings_make_call ~loc ~domain:"AutomationSlice" spec_name];
  if not (Util.has_modtype_binding "Mapping" body) then
    extra := !extra @ [gen_module_type_mapping ~loc];
  !extra @ body

(* @@reventless.mappings dispatch — file-level on _Mappings.res / _Projections.res. *)
let dispatch_mappings_impl ~loc ~specifier ~spec_name fname body =
  let domain = detect_mappings_domain ~loc fname in
  let domain_mod = mappings_domain_module domain in
  let body = walk_for_dcb_sources body in
  let prefix = ref [] in
  if not (Util.has_open_dotted "Reventless" domain_mod body) then
    prefix := !prefix @ [gen_open_reventless_sub ~loc domain_mod];
  if domain = DomainProjection
     && not (Util.has_open_dotted "Reventless" "Message" body) then
    prefix := !prefix @ [gen_open_reventless_sub ~loc "Message"];
  if not (Util.has_module_binding "Target" body) then
    prefix := !prefix @ [gen_module_alias ~loc ~alias_name:"Target" ~target_name:spec_name];
  if not (Util.has_module_binding "M" body) then
    prefix := !prefix @ [gen_mappings_make_call ~loc ~domain:domain_mod spec_name];
  if not (Util.has_modtype_binding "Mapping" body) then
    prefix := !prefix @ [gen_module_type_mapping ~loc];
  let suffix = ref [] in
  if domain = DomainEventMapping
     && not (Util.has_let_binding "counter" body) then
    suffix := !suffix @ [gen_let_counter_none ~loc];
  if not (Util.has_let_binding "moduleUrl" body) then
    suffix := !suffix @ [ModuleUrl.gen_module_url ~loc specifier];
  !prefix @ body @ !suffix

(* @@reventless.extension dispatch — file-level on Extension/<Name>_Extension.res.
   Auto-opens ReventlessInfra.ExtensionMapping and applies the Delegate transform
   inside the file's Mapping module. *)
let dispatch_extension_impl ~loc ~specifier body =
  let body = List.map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_module mb
      when (match mb.pmb_name.txt with Some "Mapping" -> true | _ -> false) ->
      (match mb.pmb_expr.pmod_desc with
       | Pmod_structure inner ->
         let inner' = List.map (fun (inner_item : structure_item) ->
           match inner_item.pstr_desc with
           | Pstr_module inner_mb
             when (match inner_mb.pmb_name.txt with Some "Delegate" -> true | _ -> false) ->
             let inner_mb' =
               transform_delegate_module ~loc:inner_item.pstr_loc ~specifier inner_mb
             in
             { inner_item with pstr_desc = Pstr_module inner_mb' }
           | _ -> inner_item
         ) inner in
         let inner'' =
           if Util.has_let_binding "delegateModuleUrl" inner'
           then inner'
           else inner' @ [gen_let_delegate_module_url ~loc:item.pstr_loc]
         in
         let inner''' =
           if Util.has_let_binding "moduleUrl" inner''
           then inner''
           else inner'' @ [ModuleUrl.gen_module_url ~loc:item.pstr_loc specifier]
         in
         let mb' = { mb with pmb_expr = { mb.pmb_expr with pmod_desc = Pmod_structure inner''' } } in
         { item with pstr_desc = Pstr_module mb' }
       | _ -> item)
    | _ -> item
  ) body in
  let prefix = ref [] in
  if not (Util.has_open_dotted "ReventlessInfra" "ExtensionMapping" body) then
    prefix := !prefix @ [gen_open_extension_mapping ~loc];
  let suffix =
    if not (Util.has_let_binding "moduleUrl" body) then
      [ModuleUrl.gen_module_url ~loc specifier]
    else []
  in
  !prefix @ body @ suffix

(* @@reventless.task dispatch — file-level on Task/<Name>.res. *)
let dispatch_task_impl ~loc ~specifier ~name body =
  let prefix = ref [] in
  if not (Util.has_open "Reventless" body) then
    prefix := !prefix @ [gen_open ~loc "Reventless"];
  if not (Util.has_let_binding "name" body) then
    prefix := !prefix @ [gen_name ~loc name];
  let suffix =
    if not (Util.has_let_binding "moduleUrl" body) then
      [ModuleUrl.gen_module_url ~loc specifier]
    else []
  in
  !prefix @ body @ suffix

let transform (str : structure) : structure =
  (* Plan 06 Phase 2: emit <Stem>.gwt.json from the inline-literal test bodies
     before GwtInference injects the include/open. No-op unless
     REVENTLESS_EMIT_SIDECAR=1 and the file carries @@reventless.gwt. *)
  let () =
    let fname =
      match GwtInference.find_gwt_attr str with
      | Some (_, gloc) -> gloc.Location.loc_start.pos_fname
      (* No attribute is not the same as no scenarios — a multi-source read
         model's GWT file wires its own functors and carries none. Fall back to
         the location the structure itself came from and let the filename
         decide. *)
      | None -> (
        match str with
        | item :: _ when SidecarEmit.looks_like_gwt_file item.pstr_loc.loc_start.pos_fname
          -> item.pstr_loc.loc_start.pos_fname
        | _ -> "")
    in
    SidecarEmit.maybe_emit_gwt ~fname str
  in
  let str = GwtInference.transform str in
  (* Inline spec-shaped inner modules (test fixtures, framework-internal
     helpers) get auth-field injection before any other pass — independent
     of @@reventless.spec mode. Cheap no-op when the file has no specs. *)
  let str = AuthorizationInjection.walk_inline_specs str in
  let str = VisibilityInjection.walk_inline_specs str in
  let str = ReadConsistencyInjection.walk_inline_specs str in
  (* Mapping-shaped inner modules — the framework's own ports and test fixtures —
     get their translation table derived independent of any file-level mode. *)
  let str = TranslationTable.walk_inline_mappings str in
  let initial_mode = detect_mode str in
  let has_mode = initial_mode <> None in
  let is_spec = match initial_mode with Some (Spec _, _) -> true | _ -> false in
  let has_module_attr = has_module_level_attr_deep str in
  let has_no_api = has_no_api_attr str in
  if not has_mode && not has_module_attr && not has_no_api then str
  else
  let loc = match str with
    | item :: _ -> item.pstr_loc
    | [] -> Location.none
  in
  let specifier = ModuleUrl.compute_specifier loc in
  let str = if has_module_attr || is_spec then walk_structure ~specifier ~is_spec str else str in
  match detect_mode str with
  | None ->
    (* No @reventless.spec or @reventless.behavior, but might have @noApi annotations *)
    if has_no_api then
      NoApiAnnotation.transform ~loc str
    else
      str
  | Some (mode, loc) ->
    let dcb_tags = has_dcb_tags_attr str
                   || Util.is_in_slice_folder loc.loc_start.pos_fname in
    let body = strip_ppx_attrs str in
    (* Capture the spec body before the DCB-tag passes rewrite the field
       annotations into [@s.matches(...)] — the Plan 06 sidecar emitter reads
       the original [@partitionTag] / [@noDcbTag] / [@dcbTag] / [@id] intent. *)
    let raw_spec_body = body in
    let () = DcbTagInference.check_deprecated_no_tag body in
    let body = ReferenceInference.transform_structure body in
    let body = StorageRefInference.transform_structure body in
    (* After StorageRefInference, which leaves uploadable-typed fields — including
       the ones carrying an explicit @storageRef override — to this pass. *)
    let body = UploadableInference.transform_structure body in
    let body = OffloadInference.transform_structure body in
    let body = if dcb_tags then DcbTagInference.transform_structure ~loc body else body in
    let body = DcbTagInference.transform_partition_tags ~loc body in
    let body = DcbTagInference.transform_cross_partition_tags ~loc body in
    let body = DcbTagInference.transform_composite_partition_tags ~loc body in
    let body = DcbTagInference.transform_explicit_dcb_tags ~loc body in
    let body = DcbTagInference.strip_no_tag_attrs body in
    (* Before OwnerInference, which strips [@owner] on its way through — a check
       that ran afterwards would silently pass @internal + @owner, the one pairing
       that most wants catching. See validate_internal_conflicts. *)
    StateAnnotations.validate_internal_conflicts body;
    (* Captured here for the same reason, and consumed further down by
       [gen_config_let]: the index [@owner] derives is keyed on a field this is
       the last point that can still name. *)
    let owner_index = StateAnnotations.derived_owner_index body in
    (* After every DCB-tag pass, on purpose: [@owner] wraps whatever schema the
       field ended up with rather than replacing it, so an owner field keeps the
       tag it would otherwise have had. See OwnerInference's header. *)
    let body = OwnerInference.transform_structure body in
    let body = DisplayNameInference.transform_structure body in
    let body = NoApiAnnotation.transform ~loc body in
    let body = TransitionAnnotation.transform ~loc body in
    match mode with
    | Spec name_opt ->
      let name = derive_spec_name ~loc name_opt in
      (* Plan 06 Phase 1: emit a <Stem>.model.json sidecar when
         REVENTLESS_EMIT_SIDECAR=1. No-op for ordinary builds. *)
      let () =
        SidecarEmit.maybe_emit ~spec_name:name
          ~fname:loc.loc_start.pos_fname raw_spec_body
      in
      let pkg = ModuleUrl.find_package_for loc in
      let has_reventless_spec = match pkg with
        | Some p -> p.has_reventless_spec
        | None -> false
      in
      let prefix = ref [] in
      if Util.is_extensionpointmapping_filename loc.loc_start.pos_fname
         && not (Util.has_open_dotted "ReventlessInfra" "ExtensionPointMapping" body) then
        prefix := !prefix @ [gen_open_ep_mapping ~loc];
      (* Stateview spec files only need [open Reventless.Projection] when
         they still carry a [project] binding (legacy merged form). After the
         Plan 02 split, [project] lives in the [_Projection] impl file and
         the spec file no longer references the action constructors. *)
      if Util.is_stateview_filename loc.loc_start.pos_fname
         && Util.has_let_binding "project" body
         && not (Util.has_open_dotted "Reventless" "Projection" body) then
        prefix := !prefix @ [gen_open_projection ~loc];
      if not (Util.has_let_binding "name" body) then
        prefix := !prefix @ [gen_name ~loc name];
      if has_reventless_spec && not (Util.has_module_binding "Id" body) then
        prefix := !prefix @ [gen_module_id ~loc];
      let is_readmodel =
        Util.is_readmodel_filename loc.loc_start.pos_fname
        && Util.has_schema_state_type body
        && not (Util.has_let_binding "config" body)
      in
      let is_stateview =
        Util.is_stateview_filename loc.loc_start.pos_fname
        && Util.has_schema_state_type body
        && (not (Util.has_let_binding "subIdConfig" body)
            || not (Util.has_let_binding "config" body))
      in
      (* A union used as a state field, checked and named before the annotation
         strips run — the guards read the very attributes those strips remove. *)
      let () = if is_readmodel || is_stateview then TaggedUnionInference.check body in
      let body =
        if is_readmodel || is_stateview then
          let base = String.concat "_" (String.split_on_char '.' name) in
          let prefix =
            match pkg with
            | Some p when not (ModuleUrl.is_spec_namespace p) ->
              (match ModuleUrl.plugin_name_from_namespace p with
               | "" -> base
               | plugin -> plugin ^ "_" ^ base)
            (* A *Spec namespace already carries the plugin in the spec name. *)
            | _ -> base
          in
          TaggedUnionInference.inject_names ~prefix body
        else body
      in
      (* Generate subIdConfig and makeId BEFORE stripping annotations *)
      let sub_id_items = gen_sub_id_config ~loc body in
      let make_id_items = gen_make_id ~loc body in
      let state_annotations_items =
        if is_readmodel || is_stateview
        then StateAnnotations.generate_state_annotations ~loc body
        else []
      in
      let readmodel_suffix =
        if is_readmodel
        then [gen_config_let ~loc ?owner_index body] @ sub_id_items @ make_id_items
             @ state_annotations_items
        else if is_stateview then
          (if not (Util.has_let_binding "config" body)
           then [gen_config_let ~loc ?owner_index body] else [])
          @ sub_id_items @ make_id_items @ state_annotations_items
        else []
      in
      let body = if is_readmodel || is_stateview
                 then StateAnnotations.strip_sub_id_attrs body
                      |> StateAnnotations.strip_id_attrs
                      |> StateAnnotations.strip_index_attrs
                      |> StateAnnotations.strip_resolver_attrs
                      |> StateAnnotations.strip_visibility_attrs
                      |> StateAnnotations.strip_drill_collapsed_attrs
                      |> StateAnnotations.strip_scan_attrs
                      |> StateAnnotations.strip_semantic_metric_attrs
                      |> StateAnnotations.strip_lifecycle_attrs
                      |> StateAnnotations.strip_group_by_attrs
                      |> StateAnnotations.strip_retired_attrs
                      |> StateAnnotations.strip_retired_ctor_attrs
                      |> StateAnnotations.strip_live_attrs
                      |> StateAnnotations.strip_named_when_retired_attrs
                 else (StateAnnotations.check_live_placement body;
                       StateAnnotations.check_named_when_retired_placement body;
                       body) in
      let suffix =
        if not (Util.has_let_binding "moduleUrl" body) then
          [ModuleUrl.gen_module_url ~loc specifier]
        else []
      in
      (* Authorization auto-injection (Aggregate / *Slice → commandAuthorization,
         ReadModel / StateViewSlice → authorization). Consumes a file-level
         @@reventless.authorize(<rule>) attribute and falls back to the framework
         default AllowAuthenticated. Idempotent on bodies already declaring the
         binding. *)
      let (authz_prefix, body, authz_suffix) =
        AuthorizationInjection.inject ~loc loc.loc_start.pos_fname body
      in
      (* Visibility auto-injection (ReadModel / StateViewSlice only). Consumes
         a file-level @@reventless.visibility(<case>) attribute and falls back
         to the framework default Public. Idempotent on bodies already declaring
         the binding. *)
      let (vis_prefix, body, vis_suffix) =
        VisibilityInjection.inject ~loc loc.loc_start.pos_fname body
      in
      (* Read-consistency auto-injection (StateChangeSlice only). Consumes a
         file-level @@reventless.consistency(<case>) attribute and falls back to
         the framework default EscalateOnRetry. Idempotent on bodies already
         declaring the binding. *)
      let (rc_prefix, body, rc_suffix) =
        ReadConsistencyInjection.inject ~loc loc.loc_start.pos_fname body
      in
      (* externalSystem auto-injection (Inbound/Outbound translation only). Appends
         [let externalSystem = None] when the spec doesn't name its foreign system, so
         the optional Spec field is satisfied without a manual binding. Idempotent. *)
      let ext_suffix =
        AuthorizationInjection.external_system_suffix ~loc loc.loc_start.pos_fname body
      in
      (* The port's two translation tables, read off the arms of `mapOutgoingEvent`
         and `mapIncomingCommand` — see TranslationTable. *)
      let table_suffix =
        if Util.is_extensionpointmapping_filename loc.loc_start.pos_fname then
          List.filter_map
            (fun derive -> derive ~loc body)
            [TranslationTable.derive_published; TranslationTable.derive_accepted]
        else []
      in
      !prefix @ authz_prefix @ vis_prefix @ rc_prefix @ body
        @ readmodel_suffix @ suffix @ authz_suffix @ vis_suffix @ rc_suffix @ ext_suffix
        @ table_suffix

    | Implementation (kind, spec_name_opt) ->
      let fname = loc.loc_start.pos_fname in
      (match kind with
       | Mappings ->
         let spec_name = match spec_name_opt with
           | Some n -> n
           | None -> derive_mappings_spec_name fname
         in
         dispatch_mappings_impl ~loc ~specifier ~spec_name fname body
       | Extension ->
         dispatch_extension_impl ~loc ~specifier body
       | Task ->
         let name = match spec_name_opt with
           | Some n -> n
           | None -> derive_task_name fname
         in
         dispatch_task_impl ~loc ~specifier ~name body
       | Behavior | Projection | Automation | Translation ->
         let spec_name = match spec_name_opt with
           | Some n -> n
           | None -> derive_impl_spec_name ~kind fname
         in
         (* Inject type annotations on recognised function bindings. The split
            form's Spec puts both [consumedEvent] and [event] in the impl file's
            scope (via [open Spec]); without explicit annotations the merged
            form's declaration-order disambiguation no longer holds. *)
         let body =
           match TypeAnnotationInjection.kind_from_impl_kind
                   ~fname (impl_kind_name kind) with
           | Some inj_kind ->
             TypeAnnotationInjection.transform_structure ~kind:inj_kind body
           | None -> body
         in
         (* @@reventless.automation: in the merged AutomationSlice file shape
            (process + per-source Mapping.Make + let mappings), inject the
            AutomationSlice.Mappings.Make wrapper and scan inner DCB Source
            modules. Trigger conditions:
              - file lives under AutomationSlice/
              - file declares `let mappings = …` (signals merged shape)
              - file does NOT declare its own `module type Mapping` (which
                would mean it's a re-export bridge to a sibling _Mappings.res
                — no PPX wrapper needed there).
            The legacy 3-file shape (process only) and the bridge shape both
            skip this extension to avoid emitting unused
            `open Reventless.AutomationSlice` / `module M`. *)
         let body =
           if kind = Automation
              && Util.is_in_automationslice_folder fname
              && Util.has_let_binding "mappings" body
              && not (Util.has_modtype_binding "Mapping" body)
           then automation_mappings_extension ~loc ~spec_name body
           else body
         in
         (* Aggregate-behavior snapshot config (docs/plans/done/aggregate-snapshotting.md):
            default [let snapshot = None]; @@reventless.snapshots(<interval>)
            switches to Some({interval, stateSchema}). Consumes the attribute;
            idempotent on bodies already declaring the binding. Aggregate
            folders only — StateChangeSlice behaviors satisfy a different
            module type without [snapshot]. *)
         let (body, snap_suffix) =
           if kind = Behavior then SnapshotInjection.inject ~loc fname body
           else (body, [])
         in
         let prefix = ref [] in
         (* Projection implementations need [Reventless.Projection]'s action
            constructors ([Set], [Update], …) in scope. This mirrors the
            auto-open the Spec branch does for [is_stateview_filename] files in
            the merged form. *)
         if kind = Projection
            && not (Util.has_open_dotted "Reventless" "Projection" body) then
           prefix := !prefix @ [gen_open_projection ~loc];
         if not (Util.has_open spec_name body) then
           prefix := !prefix @ [gen_open ~loc spec_name];
         if not (Util.has_module_binding "Spec" body) then
           prefix := !prefix @ [gen_module_alias ~loc ~alias_name:"Spec" ~target_name:spec_name];
         let suffix =
           if not (Util.has_let_binding "moduleUrl" body) then
             [ModuleUrl.gen_module_url ~loc specifier]
           else []
         in
         !prefix @ body @ suffix @ snap_suffix)

let () =
  Driver.register_transformation
    ~impl:transform
    "reventless"
