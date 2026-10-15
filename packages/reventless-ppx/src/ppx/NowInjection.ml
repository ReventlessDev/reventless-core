(* An automation's [process] is given the current time as [~now]. A [process]
   that does not take it gets a last parameter [~now as _], so every automation
   written before it existed compiles unchanged.

   Only a function literal is rewritten: [let process = (id, item) => ...]. A
   [process] bound to another function ([let process = Helper.f]) cannot be seen
   into and is left alone; the compiler then names the missing [~now]. *)

open Ppxlib

let arity_attr = "res.arity"

let arity_of attrs =
  List.find_map
    (fun a ->
      match (a.attr_name.txt, a.attr_payload) with
      | name, PStr [ { pstr_desc = Pstr_eval ({ pexp_desc = Pexp_constant (Pconst_integer (n, _)); _ }, _); _ } ]
        when name = arity_attr ->
        int_of_string_opt n
      | _ -> None)
    attrs

let with_arity ~loc n attrs =
  Ast_builder.Default.attribute ~loc ~name:{ txt = arity_attr; loc }
    ~payload:(PStr [ Ast_builder.Default.pstr_eval ~loc (Ast_builder.Default.eint ~loc n) [] ])
  :: List.filter (fun a -> a.attr_name.txt <> arity_attr) attrs

let is_now = function
  | Labelled "now" | Optional "now" -> true
  | _ -> false

let rec takes_now (e : expression) =
  match e.pexp_desc with
  | Pexp_fun (label, _, _, body) -> is_now label || takes_now body
  | _ -> false

(* Appends [~now as _] after the last parameter of a [Pexp_fun] chain. *)
let rec append_now ~loc (e : expression) =
  match e.pexp_desc with
  | Pexp_fun (label, default, pat, body) -> (
    match body.pexp_desc with
    | Pexp_fun _ -> { e with pexp_desc = Pexp_fun (label, default, pat, append_now ~loc body) }
    | _ ->
      let now = Ast_builder.Default.pexp_fun ~loc (Labelled "now") None (Ast_builder.Default.ppat_any ~loc) body in
      { e with pexp_desc = Pexp_fun (label, default, pat, now) })
  | _ -> e

let rewrite_process (e : expression) =
  match e.pexp_desc with
  | Pexp_construct (({ txt = Lident "Function$"; _ } as lid), Some ({ pexp_desc = Pexp_fun _; _ } as fn))
    when not (takes_now fn) -> (
    match arity_of e.pexp_attributes with
    | Some n ->
      let loc = e.pexp_loc in
      { e with
        pexp_desc = Pexp_construct (lid, Some (append_now ~loc fn));
        pexp_attributes = with_arity ~loc (n + 1) e.pexp_attributes;
      }
    | None -> e)
  | _ -> e

let rewrite_binding (vb : value_binding) =
  match vb.pvb_pat.ppat_desc with
  | Ppat_var { txt = "process"; _ } -> { vb with pvb_expr = rewrite_process vb.pvb_expr }
  | _ -> vb

let inject (str : structure) : structure =
  List.map
    (fun (item : structure_item) ->
      match item.pstr_desc with
      | Pstr_value (rec_flag, bindings) ->
        { item with pstr_desc = Pstr_value (rec_flag, List.map rewrite_binding bindings) }
      | _ -> item)
    str
