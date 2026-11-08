(* An automation's functions gain labeled arguments over time. One written before an
   argument existed gets it as a last parameter [~label as _], so it compiles unchanged:
   [process] is given [~now], the current time, and [onExhausted] [~lastError], why the
   last attempt failed.

   Only a function literal is rewritten: [let process = (id, item) => ...]. A function
   bound to another one ([let process = Helper.f]) cannot be seen into and is left alone;
   the compiler then names the missing argument. *)

open Ppxlib

(* Each function an automation declares, and the label it is given when missing. *)
let injected = [ ("process", "now"); ("onExhausted", "lastError") ]

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

let is_label name = function
  | Labelled l | Optional l -> l = name
  | Nolabel -> false

let rec takes name (e : expression) =
  match e.pexp_desc with
  | Pexp_fun (label, _, _, body) -> is_label name label || takes name body
  | _ -> false

(* Appends [~label as _] after the last parameter of a [Pexp_fun] chain. *)
let rec append ~loc name (e : expression) =
  match e.pexp_desc with
  | Pexp_fun (label, default, pat, body) -> (
    match body.pexp_desc with
    | Pexp_fun _ -> { e with pexp_desc = Pexp_fun (label, default, pat, append ~loc name body) }
    | _ ->
      let added = Ast_builder.Default.pexp_fun ~loc (Labelled name) None (Ast_builder.Default.ppat_any ~loc) body in
      { e with pexp_desc = Pexp_fun (label, default, pat, added) })
  | _ -> e

let rewrite name (e : expression) =
  match e.pexp_desc with
  | Pexp_construct (({ txt = Lident "Function$"; _ } as lid), Some ({ pexp_desc = Pexp_fun _; _ } as fn))
    when not (takes name fn) -> (
    match arity_of e.pexp_attributes with
    | Some n ->
      let loc = e.pexp_loc in
      { e with
        pexp_desc = Pexp_construct (lid, Some (append ~loc name fn));
        pexp_attributes = with_arity ~loc (n + 1) e.pexp_attributes;
      }
    | None -> e)
  | _ -> e

let rewrite_binding (vb : value_binding) =
  match vb.pvb_pat.ppat_desc with
  | Ppat_var { txt; _ } -> (
    match List.assoc_opt txt injected with
    | Some label -> { vb with pvb_expr = rewrite label vb.pvb_expr }
    | None -> vb)
  | _ -> vb

let inject (str : structure) : structure =
  List.map
    (fun (item : structure_item) ->
      match item.pstr_desc with
      | Pstr_value (rec_flag, bindings) ->
        { item with pstr_desc = Pstr_value (rec_flag, List.map rewrite_binding bindings) }
      | _ -> item)
    str
