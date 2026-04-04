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

let transform (str : structure) : structure =
  match detect_mode str with
  | None -> str
  | Some (mode, loc) ->
    let specifier = ModuleUrl.compute_specifier loc in
    let dcb_tags = has_dcb_tags_attr str in
    let body = strip_ppx_attrs str in
    let body = if dcb_tags then DcbTagInference.transform_structure ~loc body else body in
    match mode with
    | Spec name_opt ->
      let name = derive_spec_name ~loc name_opt in
      let pkg = ModuleUrl.find_package_for loc in
      let has_reventless_spec = match pkg with
        | Some p -> p.has_reventless_spec
        | None -> false
      in
      let prefix = ref [] in
      if not (Util.has_let_binding "name" body) then
        prefix := !prefix @ [gen_name ~loc name];
      if has_reventless_spec && not (Util.has_module_binding "Id" body) then
        prefix := !prefix @ [gen_module_id ~loc];
      let suffix =
        if not (Util.has_let_binding "moduleUrl" body) then
          [ModuleUrl.gen_module_url ~loc specifier]
        else []
      in
      !prefix @ body @ suffix

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
