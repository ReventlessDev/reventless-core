open Ppxlib

(* ── @noApi annotation helpers ── *)

let has_no_api_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "noApi"
  ) attrs

let strip_no_api_attr (attrs : attributes) =
  List.filter (fun (attr : attribute) ->
    not (String.equal attr.attr_name.txt "noApi")
  ) attrs

(* ── Type-level @noApi: emits let commandSchema = ...->S.Metadata.set(~id=ReventlessInfra.Api.noApiId, true) ── *)

let has_no_api_on_type (td : type_declaration) =
  has_no_api_attr td.ptype_attributes

let gen_no_api_metadata_binding ~loc ~schema_name =
  (* Generates: let commandSchema = ReventlessInfra.Api.markNoApi(commandSchema) *)
  let set_call = {
    pexp_desc = Pexp_apply (
      { pexp_desc = Pexp_ident { txt = Ldot (Ldot (Lident "ReventlessInfra", "Api"), "markNoApi"); loc };
        pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] },
      [
        ( Nolabel,
          { pexp_desc = Pexp_ident { txt = Lident schema_name; loc };
            pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }
        )
      ]
    );
    pexp_loc = loc;
    pexp_loc_stack = [];
    pexp_attributes = [];
  } in
  { pstr_desc = Pstr_value (Nonrecursive, [{
      pvb_pat = { ppat_desc = Ppat_var { txt = schema_name; loc };
                  ppat_loc = loc; ppat_loc_stack = []; ppat_attributes = [] };
      pvb_expr = set_call;
      pvb_attributes = [];
      pvb_loc = loc;
    }]);
    pstr_loc = loc }

(* ── Variant-level @noApi: collects constructor names and emits Set-based metadata ── *)

let extract_variant_names_with_no_api (td : type_declaration) =
  match td.ptype_kind with
  | Ptype_variant constructors ->
    List.filter_map (fun (cd : constructor_declaration) ->
      if has_no_api_attr cd.pcd_attributes then
        Some cd.pcd_name.txt
      else
        None
    ) constructors
  | _ -> []

let gen_no_api_variants_metadata_binding ~loc ~schema_name ~variant_names =
  (* Generates: let commandSchema = ReventlessInfra.Api.markNoApiVariants(commandSchema, [|"V1"; "V2"|]) *)
  let variants_array =
    List.map (fun name ->
      { pexp_desc = Pexp_constant (Pconst_string (name, loc, None));
        pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }
    ) variant_names
  in
  let set_call = {
    pexp_desc = Pexp_apply (
      { pexp_desc = Pexp_ident { txt = Ldot (Ldot (Lident "ReventlessInfra", "Api"), "markNoApiVariants"); loc };
        pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] },
      [
        ( Nolabel,
          { pexp_desc = Pexp_ident { txt = Lident schema_name; loc };
            pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }
        );
        ( Nolabel,
          { pexp_desc = Pexp_array variants_array;
            pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }
        )
      ]
    );
    pexp_loc = loc;
    pexp_loc_stack = [];
    pexp_attributes = [];
  } in
  { pstr_desc = Pstr_value (Nonrecursive, [{
      pvb_pat = { ppat_desc = Ppat_var { txt = schema_name; loc };
                  ppat_loc = loc; ppat_loc_stack = []; ppat_attributes = [] };
      pvb_expr = set_call;
      pvb_attributes = [];
      pvb_loc = loc;
    }]);
    pstr_loc = loc }

(* ── Strip @noApi from constructors ── *)

let strip_no_api_from_constructor (cd : constructor_declaration) =
  { cd with pcd_attributes = strip_no_api_attr cd.pcd_attributes }

(* ── Strip @noApi from type declaration ── *)

let strip_no_api_from_type_decl (td : type_declaration) =
  { td with ptype_attributes = strip_no_api_attr td.ptype_attributes }

(* ── Main transform: runs on the body of a @@reventless.spec module ── *)

let transform ~loc (str : structure) =
  let rec process_structure (str : structure) =
    let new_items = ref [] in
    let metadata_bindings = ref [] in

    List.iter (fun (item : structure_item) ->
      match item.pstr_desc with
      | Pstr_type (_, decls) ->
        List.iter (fun (td : type_declaration) ->
          if Util.has_attr "schema" td.ptype_attributes then
          (
            let type_has_no_api = has_no_api_on_type td in
            let variant_names = extract_variant_names_with_no_api td in

            if type_has_no_api || (List.length variant_names > 0) then
            (
              let schema_name = td.ptype_name.txt ^ "Schema" in

              if type_has_no_api then
                metadata_bindings := !metadata_bindings @ [gen_no_api_metadata_binding ~loc ~schema_name];

              if List.length variant_names > 0 then
                metadata_bindings := !metadata_bindings @ [gen_no_api_variants_metadata_binding ~loc ~schema_name ~variant_names];

              let new_ctors = List.map strip_no_api_from_constructor (
                match td.ptype_kind with
                | Ptype_variant ctors -> ctors
                | _ -> []
              ) in
              let stripped_td = {
                td with
                ptype_attributes = strip_no_api_attr td.ptype_attributes;
                ptype_kind = Ptype_variant new_ctors;
              } in
              new_items := !new_items @ [{ item with pstr_desc = Pstr_type (Nonrecursive, [stripped_td]) }]
            )
            else
              new_items := !new_items @ [item]
          )
          else
            new_items := !new_items @ [item]
        ) decls
      | Pstr_module mb ->
        (* Recursively process nested modules *)
        let new_expr = process_module_expr mb.pmb_expr in
        new_items := !new_items @ [{ item with pstr_desc = Pstr_module { mb with pmb_expr = new_expr } }]
      | _ ->
        new_items := !new_items @ [item]
    ) str;

    !new_items @ !metadata_bindings

  and process_module_expr (me : module_expr) : module_expr =
    match me.pmod_desc with
    | Pmod_structure str ->
      { me with pmod_desc = Pmod_structure (process_structure str) }
    | Pmod_functor (param, body) ->
      { me with pmod_desc = Pmod_functor (param, process_module_expr body) }
    | Pmod_constraint (body, mty) ->
      { me with pmod_desc = Pmod_constraint (process_module_expr body, mty) }
    | _ -> me
  in
  process_structure str
