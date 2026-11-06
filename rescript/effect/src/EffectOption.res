/** Effect's internal Option type — used only for binding-level conversion to ReScript `option`. */
type t<'a>

/** Convert Effect's Option to a ReScript option. */
@module("effect/Option")
external toOption: t<'a> => option<'a> = "getOrUndefined"
