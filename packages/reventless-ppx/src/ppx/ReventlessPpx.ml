open Ppxlib

type mode =
  | Spec of string option
  | Behavior of string option

let detect_mode (str : structure) =
  let rec scan = function
    | [] -> None
    | item :: rest ->
      (match item.pstr_desc with
       | Pstr_attribute attr ->
         if String.equal attr.attr_name.txt "reventless.spec" then
           let name = Util.get_string_payload attr in
           Some (Spec name, attr.attr_loc)
         else if String.equal attr.attr_name.txt "reventless.behavior" then
           let spec_name =
             match Util.get_string_payload attr with
             | Some s -> Some s
             | None -> Util.get_ident_payload attr
           in
           Some (Behavior spec_name, attr.attr_loc)
         else
           scan rest
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
  List.filter (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_attribute attr ->
      not (String.equal attr.attr_name.txt "reventless.spec"
           || String.equal attr.attr_name.txt "reventless.behavior"
           || String.equal attr.attr_name.txt "reventless.dcbTags")
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

let gen_config_let ~loc body =
  StateAnnotations.generate_config ~loc body

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
    let suffix =
      (if not (Util.has_type_binding "error" body) then [gen_schema_unit_type ~loc "error"] else [])
      @ (if not (Util.has_let_binding "moduleUrl" body) then [ModuleUrl.gen_module_url ~loc specifier] else [])
    in
    let new_body = { mb.pmb_expr with pmod_desc = Pmod_structure (prefix @ body @ suffix) } in
    { mb with pmb_expr = new_body; pmb_attributes = attrs }
  | _ -> { mb with pmb_attributes = attrs }

(* --- Phase 5: @reventless.projections inside module bodies --- *)

let extract_target_from_constraint (mty : module_type) : Longident.t option =
  match mty.pmty_desc with
  | Pmty_with (_, constraints) ->
    let rec find = function
      | [] -> None
      | Pwith_modsubst ({ txt = Lident "Target"; _ }, { txt = lid; _ }) :: _ -> Some lid
      | _ :: rest -> find rest
    in
    find constraints
  | _ -> None

let gen_mappings_make ~loc (target : Longident.t) =
  let mappings_make = Ldot (Ldot (Ldot (Lident "Reventless", "Projection"), "Mappings"), "Make") in
  let target_mod = {
    pmod_desc = Pmod_ident { txt = target; loc };
    pmod_loc = loc;
    pmod_attributes = [];
  } in
  { pstr_desc = Pstr_module {
      pmb_name = { txt = Some "M"; loc };
      pmb_expr = {
        pmod_desc = Pmod_apply ({
          pmod_desc = Pmod_ident { txt = mappings_make; loc };
          pmod_loc = loc;
          pmod_attributes = [];
        }, target_mod);
        pmod_loc = loc;
        pmod_attributes = [];
      };
      pmb_attributes = [];
      pmb_loc = loc;
    };
    pstr_loc = loc }

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

let transform_projections_module ~loc ~specifier (mb : module_binding) : module_binding =
  let attrs = List.filter (fun (a : attribute) ->
    not (String.equal a.attr_name.txt "reventless.projections")
  ) mb.pmb_attributes in
  match mb.pmb_expr.pmod_desc with
  | Pmod_constraint (body_expr, mty) ->
    let target = extract_target_from_constraint mty in
    (match target, body_expr.pmod_desc with
     | Some target_lid, Pmod_structure body ->
       let prefix =
         (if not (Util.has_module_binding "M" body) then [gen_mappings_make ~loc target_lid] else [])
         @ (if not (Util.has_module_binding "Mapping" body) then [gen_module_type_mapping ~loc] else [])
         @ (if not (Util.has_let_binding "moduleUrl" body) then [ModuleUrl.gen_module_url ~loc specifier] else [])
       in
       let new_body = { body_expr with pmod_desc = Pmod_structure (prefix @ body) } in
       { mb with pmb_expr = { mb.pmb_expr with pmod_desc = Pmod_constraint (new_body, mty) };
                 pmb_attributes = attrs }
     | _ -> { mb with pmb_attributes = attrs })
  | _ -> { mb with pmb_attributes = attrs }

let rec walk_structure ~specifier ~is_spec (str : structure) : structure =
  List.map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_module mb ->
      let has_proj = Util.has_attr "reventless.projections" mb.pmb_attributes in
      let has_del = Util.has_attr "reventless.delegate" mb.pmb_attributes in
      let is_delegate = has_del ||
        (is_spec && (match mb.pmb_name.txt with Some "Delegate" -> true | _ -> false)) in
      let mb = if has_proj then
        transform_projections_module ~loc:item.pstr_loc ~specifier mb
      else if is_delegate then
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
        if Util.has_attr "reventless.projections" mb.pmb_attributes
           || Util.has_attr "reventless.delegate" mb.pmb_attributes
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

let transform (str : structure) : structure =
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
    let () = DcbTagInference.check_deprecated_no_tag body in
    let body = if dcb_tags then DcbTagInference.transform_structure ~loc body else body in
    let body = DcbTagInference.transform_partition_tags ~loc body in
    let body = DcbTagInference.transform_composite_partition_tags ~loc body in
    let body = DcbTagInference.transform_explicit_dcb_tags ~loc body in
    let body = DcbTagInference.strip_no_tag_attrs body in
    let body = DisplayNameInference.transform_structure body in
    let body = NoApiAnnotation.transform ~loc body in
    match mode with
    | Spec name_opt ->
      let name = derive_spec_name ~loc name_opt in
      let pkg = ModuleUrl.find_package_for loc in
      let has_reventless_spec = match pkg with
        | Some p -> p.has_reventless_spec
        | None -> false
      in
      let prefix = ref [] in
      if Util.is_extensionpointmapping_filename loc.loc_start.pos_fname
         && not (Util.has_open_dotted "ReventlessInfra" "ExtensionPointMapping" body) then
        prefix := !prefix @ [gen_open_ep_mapping ~loc];
      if Util.is_stateview_filename loc.loc_start.pos_fname
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
      (* Generate subIdConfig and makeId BEFORE stripping annotations *)
      let sub_id_items = gen_sub_id_config ~loc body in
      let make_id_items = gen_make_id ~loc body in
      let readmodel_suffix =
        if is_readmodel
        then [gen_config_let ~loc body] @ sub_id_items @ make_id_items
        else if is_stateview then
          (if not (Util.has_let_binding "config" body) then [gen_config_let ~loc body] else [])
          @ sub_id_items @ make_id_items
        else []
      in
      let body = if is_readmodel || is_stateview
                 then StateAnnotations.strip_sub_id_attrs body
                      |> StateAnnotations.strip_id_attrs
                      |> StateAnnotations.strip_index_attrs
                      |> StateAnnotations.strip_resolver_attrs
                 else body in
      let suffix =
        if not (Util.has_let_binding "moduleUrl" body) then
          [ModuleUrl.gen_module_url ~loc specifier]
        else []
      in
      !prefix @ body @ readmodel_suffix @ suffix

    | Behavior spec_name_opt ->
      let spec_name = match spec_name_opt with
        | Some n -> n
        | None -> Util.filename_to_name loc.loc_start.pos_fname
      in
      let prefix = ref [] in
      if not (Util.has_open spec_name body) then
        prefix := !prefix @ [gen_open ~loc spec_name];
      if not (Util.has_module_binding "Spec" body) then
        prefix := !prefix @ [gen_module_alias ~loc ~alias_name:"Spec" ~target_name:spec_name];
      let suffix =
        if not (Util.has_let_binding "moduleUrl" body) then
          [ModuleUrl.gen_module_url ~loc specifier]
        else []
      in
      !prefix @ body @ suffix

let () =
  Driver.register_transformation
    ~impl:transform
    "reventless"
