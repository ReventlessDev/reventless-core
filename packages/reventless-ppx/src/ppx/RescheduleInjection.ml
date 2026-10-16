(* An automation's mapping may say which schedules an event sets or clears, with
   [reschedule]. A [Mapping.Make(Source, Target, {...})] whose third argument does
   not define it gets [let reschedule = _ => []], so every mapping written before
   it existed compiles unchanged. Only a literal structure as the third argument
   is seen into; anything else is left for the compiler to name. *)

open Ppxlib

let rec path_of (lid : longident) =
  match lid with
  | Lident s -> s
  | Ldot (p, s) -> path_of p ^ "." ^ s
  | Lapply _ -> ""

let is_mapping_make (me : module_expr) =
  match me.pmod_desc with
  | Pmod_ident { txt; _ } ->
    let p = path_of txt in
    p = "Mapping.Make" || String.ends_with ~suffix:".Mapping.Make" p
  | _ -> false

let defines_reschedule (str : structure) = Util.has_let_binding "reschedule" str

let gen_reschedule ~loc =
  let fn =
    AuthorizationInjection.arity1_fun ~loc (Ast_builder.Default.ppat_any ~loc)
      (Ast_builder.Default.pexp_array ~loc [])
  in
  Ast_builder.Default.pstr_value ~loc Nonrecursive
    [ Ast_builder.Default.value_binding ~loc
        ~pat:(Ast_builder.Default.ppat_var ~loc { txt = "reschedule"; loc })
        ~expr:fn ]

(* [Mapping.Make(S, T, {...})] parses as [((Mapping.Make(S))(T))({...})]. *)
let rec rewrite_module_expr (me : module_expr) =
  match me.pmod_desc with
  | Pmod_constraint (inner, mt) ->
    { me with pmod_desc = Pmod_constraint (rewrite_module_expr inner, mt) }
  | Pmod_apply
      ( ({ pmod_desc = Pmod_apply ({ pmod_desc = Pmod_apply (head, _); _ }, _); _ } as fn),
        ({ pmod_desc = Pmod_structure impl; _ } as arg) )
    when is_mapping_make head && not (defines_reschedule impl) ->
    let loc = arg.pmod_loc in
    { me with
      pmod_desc = Pmod_apply (fn, { arg with pmod_desc = Pmod_structure (impl @ [ gen_reschedule ~loc ]) })
    }
  | _ -> me

let inject (str : structure) : structure =
  List.map
    (fun (item : structure_item) ->
      match item.pstr_desc with
      | Pstr_module mb -> { item with pstr_desc = Pstr_module { mb with pmb_expr = rewrite_module_expr mb.pmb_expr } }
      | _ -> item)
    str

(* Whether a [Mapping.Make] third argument, as written, defines [reschedule]. *)
let rec third_arg_reschedules (me : module_expr) =
  match me.pmod_desc with
  | Pmod_constraint (inner, _) -> third_arg_reschedules inner
  | Pmod_apply (_, { pmod_desc = Pmod_structure impl; _ }) -> defines_reschedule impl
  | _ -> false
