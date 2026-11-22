// The schema of the narrow API for visitors: the fields a plugin declares
// `AllowAnonymous`, taken out of the plugin's own schema and given one of their
// own, with the types they reach and nothing else of the plugin's.
//
// The platform API has two kinds of caller and no directive that means "no one
// signed in", so an anonymous field cannot live there. A second API whose only
// authorization is an API key carries them instead: the key identifies the
// deployment, it does not protect it. The protection is the limit on that API and
// answers that tell a visitor nothing.
//
// Pure: no Pulumi, so what goes where is tested without a deploy.

module Stitcher = ReventlessCore.GraphQL_Stitcher

/** A plugin's fields for visitors, by root type. */
type fields = {mutations: array<string>, queries: array<string>}

let none: fields = {mutations: [], queries: []}

let isEmpty = (f: fields) => f.mutations == [] && f.queries == []

/** The fields whose rule is `AllowAnonymous`: a mutation by its field's own
    rule, a view by its rule with every field the generator derives from it. */
let fieldsOf = (
  ~mutationEntries: array<ReventlessInfra.Api.mutationSchemaEntry>,
  ~queryEntries: array<ReventlessInfra.Api.querySchemaEntry>,
): fields => {
  mutations: mutationEntries->Array.flatMap(entry =>
    entry.fieldPermissions->Option.mapOr([], fp =>
      fp
      ->Dict.toArray
      ->Array.filterMap(
        ((fieldName, permission)) =>
          permission == Reventless.Authorization.AllowAnonymous ? Some(fieldName) : None,
      )
    )
  ),
  queries: queryEntries->Array.flatMap(entry =>
    entry.permission == Some(Reventless.Authorization.AllowAnonymous)
      ? ReventlessCore.GraphQL_FragmentGenerator.queryFieldNamesOf(entry)
      : []
  ),
}

let nameOf = Stitcher.extractLeadingName

/** A declaration's name, whatever its kind. */
let declName = (decl: string): option<string> =>
  switch nameOf(decl) {
  | "" => None
  | name => Some(name)
  }

/** The declarations `roots` reach, through every name each mentions. */
let reachable = (types: array<string>, ~roots: array<string>): array<string> => {
  let byName = types->Array.filterMap(d => declName(d)->Option.map(n => (n, d)))->Dict.fromArray
  let words = (text: string) =>
    text->String.match(/[_A-Za-z][_0-9A-Za-z]*/g)->Option.getOr([])->Array.filterMap(x => x)
  let seen: dict<bool> = Dict.make()
  let rec visit = (text: string) =>
    words(text)->Array.forEach(word =>
      switch (seen->Dict.get(word), byName->Dict.get(word)) {
      | (None, Some(decl)) =>
        seen->Dict.set(word, true)
        visit(decl)
      | _ => ()
      }
    )
  roots->Array.forEach(visit)
  // In the order the plugin declares them, so the document does not churn.
  types->Array.filter(d => declName(d)->Option.mapOr(false, n => seen->Dict.get(n) == Some(true)))
}

/** The plugin's own fragment without its visitor fields, and without the
    subscriptions that announce a visitor mutation: a subscription to a mutation
    the schema does not have is refused by AppSync. */
let without = (
  fragment: Reventless.Plugin.apiSchemaFragment,
  fields: fields,
): Reventless.Plugin.apiSchemaFragment =>
  if isEmpty(fields) {
    fragment
  } else {
    let parts = Stitcher.decode(fragment)
    let visitor = name => fields.mutations->Array.includes(name)
    let sources =
      parts.subscriptionSources
      ->Array.map(s => {...s, mutations: s.mutations->Array.filter(m => !visitor(m))})
      ->Array.filter(s => s.mutations != [])
    // A subscription the fragment gives a source keeps it only while a mutation
    // of its own is left.
    let sourced = parts.subscriptionSources->Array.map(s => s.field)
    let kept = sources->Array.map(s => s.field)
    Stitcher.encode({
      ...parts,
      mutations: parts.mutations->Array.filter(f => !visitor(nameOf(f))),
      queries: parts.queries->Array.filter(f => !(fields.queries->Array.includes(nameOf(f)))),
      subscriptions: parts.subscriptions->Array.filter(f =>
        !(sourced->Array.includes(nameOf(f))) || kept->Array.includes(nameOf(f))
      ),
      subscriptionSources: sources,
    })
  }

/** The visitor fields of a fragment, with the declarations they reach. Taken
    from the fragment before any directive is put on it: an API with one way in
    needs none. */
let only = (
  fragment: Reventless.Plugin.apiSchemaFragment,
  fields: fields,
): Reventless.Plugin.apiSchemaFragment => {
  let parts = Stitcher.decode(fragment)
  let mutations = parts.mutations->Array.filter(f => fields.mutations->Array.includes(nameOf(f)))
  let queries = parts.queries->Array.filter(f => fields.queries->Array.includes(nameOf(f)))
  Stitcher.encode({
    types: reachable(parts.types, ~roots=Array.concat(mutations, queries)),
    mutations,
    queries,
    subscriptions: [],
    subscriptionSources: [],
  })
}

/** The narrow API's schema document. */
let sdl = (fragment: Reventless.Plugin.apiSchemaFragment): string =>
  Stitcher.stitchStandalone(~fragment)
