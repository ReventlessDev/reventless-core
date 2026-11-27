open Ppxlib

(** [@readWhole] on a case of a slice's [consumedEvent]: the slice reads every
    event of that type, beside what its command's tags read.

    {[
      @schema
      type consumedEvent =
        | OrderPlaced({orderId: string})
        | @readWhole DeliveryFeeSet({deliveryOption: string, fee: float})
    ]}

    The cases are carried on the schema, because both the deploy-time builder and
    the deployed command handler derive the read from schemas alone: this pass
    emits [let consumedEventSchema = Reventless.DcbTag.readWhole(consumedEventSchema, [...])]
    right after the declaration, where it shadows what sury-ppx generates, and
    strips the attribute. A case is named as it is on the wire, so [@as] wins.

    Refused on any other type: only a slice's [consumedEvent] is read. *)

let attr_name = "readWhole"

(* The compiler's own `@as`, read as AuthorizationInjection reads it. *)
let wire_name (cd : constructor_declaration) =
  List.fold_left (fun name (attr : attribute) ->
    match attr.attr_name.txt, attr.attr_payload with
    | "as", PStr [{ pstr_desc = Pstr_eval ({ pexp_desc = Pexp_constant (Pconst_string (s, _, _)); _ }, _); _ }] -> s
    | _ -> name
  ) cd.pcd_name.txt cd.pcd_attributes

let strip (cd : constructor_declaration) =
  { cd with
    pcd_attributes =
      List.filter (fun (a : attribute) -> not (String.equal a.attr_name.txt attr_name))
        cd.pcd_attributes }

let binding ~loc (types : string list) =
  let ident txt = Ast_builder.Default.pexp_ident ~loc { txt; loc } in
  let call =
    Ast_builder.Default.pexp_apply ~loc
      (ident (Ldot (Ldot (Lident "Reventless", "DcbTag"), "readWhole")))
      [ (Nolabel, ident (Lident "consumedEventSchema"));
        (Nolabel,
         Ast_builder.Default.pexp_array ~loc
           (List.map (Ast_builder.Default.estring ~loc) types)) ]
  in
  Ast_builder.Default.pstr_value ~loc Nonrecursive
    [ Ast_builder.Default.value_binding ~loc
        ~pat:(Ast_builder.Default.ppat_var ~loc { txt = "consumedEventSchema"; loc })
        ~expr:call ]

let marked ctors = List.filter (fun cd -> Util.has_attr attr_name cd.pcd_attributes) ctors

let transform_structure (str : structure) : structure =
  List.concat_map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (rf, decls) ->
      let extras = ref [] in
      let decls =
        List.map (fun (td : type_declaration) ->
          match td.ptype_kind with
          | Ptype_variant ctors when marked ctors <> [] ->
            let is_consumed =
              String.equal td.ptype_name.txt "consumedEvent"
              && Util.has_attr "schema" td.ptype_attributes
            in
            if not is_consumed then
              Location.raise_errorf ~loc:(List.hd (marked ctors)).pcd_loc
                "[reventless-ppx] @readWhole on a case of `%s`: only a slice's \
                 `@schema type consumedEvent` is read, so only its cases can be read whole."
                td.ptype_name.txt;
            if Util.has_let_binding "consumedEventSchema" str then
              Location.raise_errorf ~loc:(List.hd (marked ctors)).pcd_loc
                "[reventless-ppx] @readWhole needs the schema sury-ppx derives for \
                 `consumedEvent`, and this file binds `consumedEventSchema` itself. Mark it \
                 there instead: `Reventless.DcbTag.readWhole(<schema>, [\"%s\"])`."
                (wire_name (List.hd (marked ctors)));
            extras := !extras @ [ binding ~loc:td.ptype_loc (List.map wire_name (marked ctors)) ];
            { td with ptype_kind = Ptype_variant (List.map strip ctors) }
          | _ -> td
        ) decls
      in
      { item with pstr_desc = Pstr_type (rf, decls) } :: !extras
    | _ -> [ item ]
  ) str
