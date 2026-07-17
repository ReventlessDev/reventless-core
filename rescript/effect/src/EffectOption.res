/** Effect's internal Option type — used only for binding-level conversion to ReScript `option`. */
type t<'a>

/** Convert Effect's Option to a ReScript option. */
let toOption: t<'a> => option<'a> = %raw(`
  function(opt) { return opt._tag === "Some" ? opt.value : undefined; }
`)
