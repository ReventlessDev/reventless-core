/***
An app's own words as a catalogue: one message key per thing a person reads, derived from a
plugin's `pluginStructure`, with the humanized identifier as its English text.

Keys are `<Plugin>.<Element>.<kind>`, `Plugin` the composition's name and `Element` the
identifier, so every reader (the screens, a translator, a glossary) addresses the same text:

| key | text | from |
|---|---|---|
| `Ordering.Customers.name` | Customer | a view, singular (its `singleQueryField`) |
| `Ordering.Customers.plural` | Customers | the view's own name, or its `@plural` |
| `Ordering.Customers.count` | `{count, plural, one {# customer} other {# customers}}` | the two |
| `Ordering.Customers.field.email` | Email | a top-level field of the view |
| `Ordering.Customers.state.Deactivated` | Deactivated | a value of its lifecycle field |
| `Ordering.PlaceOrder.name` | Place Order | a command |
| `Ordering.PlaceOrder.field.orderId` | Order ID | a field of the command |
| `Ordering.CancelOrder.error.OrderAlreadyShipped` | Order already shipped | a write side's refusal |
| `Ordering.role.Merchandiser` | Merchandiser | a role |
| `Ordering.plugin.name` | Ordering | the plugin, as a menu groups its pages |

The English is what the screens draw today from the identifier, so a fresh catalogue changes
nothing on screen; a translation is the first thing that does.

A rerun is idempotent. It adds new keys, rewrites a text only while it is still the one it
generated (the lock file holds that text's hash), keeps a text a person edited, and reports a
key the structure no longer has as an orphan instead of deleting it: a rename needs the old
key's translations.
*/
// ── Humanizing an identifier ──────────────────────────────────────────────────
// The rule the screens draw an identifier by: the catalogue's English must read as the screens
// read before there was one. If the screens' rule changes, change this one with it.

let acronyms = Dict.fromArray([
  ("id", "ID"),
  ("ids", "IDs"),
  ("url", "URL"),
  ("uri", "URI"),
  ("api", "API"),
  ("arn", "ARN"),
  ("aws", "AWS"),
  ("iam", "IAM"),
  ("sqs", "SQS"),
  ("sns", "SNS"),
  ("uuid", "UUID"),
  ("ip", "IP"),
  ("dns", "DNS"),
  ("http", "HTTP"),
  ("https", "HTTPS"),
  ("json", "JSON"),
  ("xml", "XML"),
  ("sql", "SQL"),
  ("ui", "UI"),
  ("ux", "UX"),
])

let isUpper = (ch: string): bool => ch == String.toUpperCase(ch) && ch != String.toLowerCase(ch)
let isLower = (ch: string): bool => ch == String.toLowerCase(ch) && ch != String.toUpperCase(ch)
let isDigit = (ch: string): bool => ch >= "0" && ch <= "9" && String.length(ch) == 1

/** Words at `_`, `-`, spaces and camelCase boundaries; a run of capitals stays one word
    (`ARNValue` → `ARN`, `Value`). */
let splitWords = (input: string): array<string> => {
  let length = String.length(input)
  let words = []
  let current = ref("")
  let flush = () =>
    if String.length(current.contents) > 0 {
      words->Array.push(current.contents)
      current := ""
    }
  for i in 0 to length - 1 {
    let ch = String.charAt(input, i)
    if ch == "_" || ch == "-" || ch == " " {
      flush()
    } else if isUpper(ch) {
      let prevLower = i > 0 && isLower(String.charAt(input, i - 1))
      let nextLower = i + 1 < length && isLower(String.charAt(input, i + 1))
      let prevUpper = i > 0 && isUpper(String.charAt(input, i - 1))
      if prevLower || (prevUpper && nextLower) {
        flush()
      }
      current := current.contents ++ ch
    } else if isDigit(ch) {
      let prev = i > 0 ? String.charAt(input, i - 1) : ""
      if isUpper(prev) || isLower(prev) {
        flush()
      }
      current := current.contents ++ ch
    } else {
      current := current.contents ++ ch
    }
  }
  flush()
  words
}

let capitalizeWord = (word: string): string =>
  switch acronyms->Dict.get(String.toLowerCase(word)) {
  | Some(acronym) => acronym
  | None =>
    String.length(word) == 0
      ? ""
      : String.toUpperCase(String.charAt(word, 0)) ++
        String.toLowerCase(String.slice(word, ~start=1))
  }

/** `customerId` → "Customer ID", `PlaceOrder` → "Place Order". */
let humanizeKey = (key: string): string =>
  switch splitWords(key) {
  | [] => key
  | words => words->Array.map(capitalizeWord)->Array.join(" ")
  }

/** `OrderAlreadyShipped` → "Order already shipped". */
let sentence = (code: string): string =>
  splitWords(code)
  ->Array.mapWithIndex((word, i) =>
    switch (i, acronyms->Dict.get(String.toLowerCase(word))) {
    | (_, Some(acronym)) => acronym
    | (0, None) => capitalizeWord(word)
    | (_, None) => String.toLowerCase(word)
    }
  )
  ->Array.join(" ")

/** A noun inside an English sentence: lower case, acronyms kept (`Order Lines` → "order lines"). */
let inSentence = (identifier: string): string =>
  splitWords(identifier)
  ->Array.map(word =>
    switch acronyms->Dict.get(String.toLowerCase(word)) {
    | Some(acronym) => acronym
    | None => String.toLowerCase(word)
    }
  )
  ->Array.join(" ")

// ── Keys from a structure ─────────────────────────────────────────────────────

/** Where a key came from, for a translator's context and, later, the glossary's terms. */
type element = {plugin: string, identifier: string, kind: string}

type entry = {key: string, text: string, element: element}

let schemaOf = (schema: string): option<dict<JSON.t>> =>
  try JSON.parseOrThrow(schema)->JSON.Decode.object catch {
  | _ => None
  }

/** A schema's top-level properties, in declaration order. */
let propertiesOf = (schema: string): array<(string, dict<JSON.t>)> =>
  schemaOf(schema)
  ->Option.flatMap(s => s->Dict.get("properties"))
  ->Option.flatMap(JSON.Decode.object)
  ->Option.mapOr([], props =>
    props
    ->Dict.toArray
    ->Array.filterMap(((k, v)) => v->JSON.Decode.object->Option.map(o => (k, o)))
  )

/** The values an enum field declares: `enum`, or `oneOf` of `const`s. */
let enumValues = (property: dict<JSON.t>): array<string> =>
  switch property->Dict.get("enum")->Option.flatMap(JSON.Decode.array) {
  | Some(values) => values->Array.filterMap(JSON.Decode.string)
  | None =>
    property
    ->Dict.get("oneOf")
    ->Option.flatMap(JSON.Decode.array)
    ->Option.getOr([])
    ->Array.filterMap(v =>
      v
      ->JSON.Decode.object
      ->Option.flatMap(o => o->Dict.get("const"))
      ->Option.flatMap(JSON.Decode.string)
    )
  }

/** A GraphQL field without its plugin's prefix: `Ordering_Customer` → `Customer`. */
let unprefixed = (field: string): string =>
  switch field->String.indexOf("_") {
  | -1 => field
  | _ => field->String.split("_")->Array.at(-1)->Option.getOr(field)
  }

/** The plugin's name as its GraphQL fields carry it: `Ordering_Customers` for the view
    `Customers` → `Ordering`. `None` for a plugin with no view and no command. */
let pluginNameOf = (structure: Plugin.pluginStructure): option<string> => {
  let views = Array.concat(structure.readModels, structure.stateViewSlices)
  let fromView =
    views->Array.findMap(v =>
      v.queryField->String.endsWith("_" ++ v.name)
        ? Some(v.queryField->String.slice(~start=0, ~end=-(String.length(v.name) + 1)))
        : None
    )
  let fromCommand = () =>
    Array.concat(structure.stateChangeSlices, structure.aggregates)
    ->Array.flatMap(w => w.commands)
    ->Array.findMap(c =>
      c.mutationField->String.endsWith("_" ++ c.name)
        ? Some(c.mutationField->String.slice(~start=0, ~end=-(String.length(c.name) + 1)))
        : None
    )
  fromView->Option.orElse(fromCommand())
}

let entries = (~plugin: string, structure: Plugin.pluginStructure): array<entry> => {
  let out: array<entry> = []
  let add = (~identifier, ~kind, text) =>
    out->Array.push({
      key: `${plugin}.${identifier}.${kind}`,
      text,
      element: {plugin, identifier, kind},
    })

  Array.concat(structure.readModels, structure.stateViewSlices)->Array.forEach(view => {
    let singular = view.singleQueryField->Option.mapOr(view.name, unprefixed)
    // A declared `@plural` is where the view's name does not read as its plural.
    let plural = switch (view.pluralSource, view.plural) {
    | (Some("declared"), Some(p)) => p
    | _ => view.name
    }
    add(~identifier=view.name, ~kind="name", humanizeKey(singular))
    add(~identifier=view.name, ~kind="plural", humanizeKey(plural))
    add(
      ~identifier=view.name,
      ~kind="count",
      `{count, plural, one {# ${inSentence(singular)}} other {# ${inSentence(plural)}}}`,
    )
    let properties = propertiesOf(view.schema)
    properties->Array.forEach(((field, _)) =>
      add(~identifier=view.name, ~kind=`field.${field}`, humanizeKey(field))
    )
    view.lifecycleField
    ->Option.flatMap(field => properties->Array.find(((k, _)) => k == field))
    ->Option.forEach(((_, property)) =>
      enumValues(property)->Array.forEach(
        value => add(~identifier=view.name, ~kind=`state.${value}`, humanizeKey(value)),
      )
    )
  })

  Array.concat(structure.stateChangeSlices, structure.aggregates)->Array.forEach(writeSide => {
    writeSide.commands->Array.forEach(command => {
      add(~identifier=command.name, ~kind="name", humanizeKey(command.name))
      propertiesOf(command.schema)->Array.forEach(
        ((field, _)) => add(~identifier=command.name, ~kind=`field.${field}`, humanizeKey(field)),
      )
    })
    writeSide.errors->Array.forEach(error =>
      add(~identifier=writeSide.name, ~kind=`error.${error.name}`, sentence(error.name))
    )
  })

  // The plugin itself, as a menu groups its pages under it.
  out->Array.push({
    key: `${plugin}.plugin.name`,
    text: humanizeKey(plugin),
    element: {plugin, identifier: plugin, kind: "plugin"},
  })

  let roles = Array.concat(
    structure.admission->Option.getOr([])->Array.map(a => a.role),
    Array.concat(structure.stateChangeSlices, structure.aggregates)
    ->Array.flatMap(w => w.commands)
    ->Array.flatMap(c => c.requiredRoles->Option.getOr([])),
  )
  roles->Array.forEach(role =>
    if !(out->Array.some(e => e.key == `${plugin}.role.${role}`)) {
      out->Array.push({
        key: `${plugin}.role.${role}`,
        text: humanizeKey(role),
        element: {plugin, identifier: role, kind: "role"},
      })
    }
  )

  // One entry per key, the first winning: a command two write sides share is one text.
  let seen = Set.make()
  out
  ->Array.filter(e =>
    if seen->Set.has(e.key) {
      false
    } else {
      seen->Set.add(e.key)
      true
    }
  )
  ->Array.toSorted((a, b) => String.compare(a.key, b.key))
}

// ── A rerun against what is on disk ───────────────────────────────────────────

/** What the lock file keeps per key: the hash of the text the generator last wrote, the
    element it came from, and room for the glossary terms a translation used. */
type lock = {source: string, element: element, terms: dict<string>}

type merged = {
  catalogue: dict<string>,
  locks: dict<lock>,
  added: array<string>,
  updated: array<string>,
  /** Keys whose text a person changed: kept, and no longer rewritten. */
  edited: array<string>,
  /** Keys the structure no longer has: kept until a person removes them. */
  orphans: array<string>,
}

let merge = (
  ~generated: array<entry>,
  ~existing: dict<string>,
  ~locks: dict<lock>,
  ~hash: string => string,
): merged => {
  let catalogue = Dict.make()
  let nextLocks = Dict.make()
  let added = []
  let updated = []
  let edited = []
  generated->Array.forEach(({key, text, element}) => {
    let lockOf = text => {source: hash(text), element, terms: Dict.make()}
    switch existing->Dict.get(key) {
    | None =>
      added->Array.push(key)
      catalogue->Dict.set(key, text)
      nextLocks->Dict.set(key, lockOf(text))
    | Some(current) =>
      let generatedLast = locks->Dict.get(key)->Option.map(l => l.source) == Some(hash(current))
      if current == text {
        catalogue->Dict.set(key, current)
        nextLocks->Dict.set(
          key,
          locks->Dict.get(key)->Option.mapOr(lockOf(text), l => {...l, element}),
        )
      } else if generatedLast {
        updated->Array.push(key)
        catalogue->Dict.set(key, text)
        nextLocks->Dict.set(key, lockOf(text))
      } else {
        edited->Array.push(key)
        catalogue->Dict.set(key, current)
        locks->Dict.get(key)->Option.forEach(l => nextLocks->Dict.set(key, {...l, element}))
      }
    }
  })
  let orphans =
    existing
    ->Dict.keysToArray
    ->Array.filter(key => catalogue->Dict.get(key)->Option.isNone)
    ->Array.toSorted(String.compare)
  orphans->Array.forEach(key => {
    existing->Dict.get(key)->Option.forEach(text => catalogue->Dict.set(key, text))
    locks->Dict.get(key)->Option.forEach(l => nextLocks->Dict.set(key, l))
  })
  {catalogue, locks: nextLocks, added, updated, edited, orphans}
}

// ── The files ─────────────────────────────────────────────────────────────────

let sortedObject = (d: dict<JSON.t>): JSON.t =>
  d
  ->Dict.toArray
  ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))
  ->Dict.fromArray
  ->JSON.Encode.object

/** A catalogue as written: keys sorted, two-space indent, a final newline, so a rerun with
    nothing new is byte-identical. */
let catalogueText = (catalogue: dict<string>): string =>
  JSON.stringify(sortedObject(catalogue->Dict.mapValues(JSON.Encode.string)), ~space=2) ++ "\n"

let lockText = (locks: dict<lock>): string =>
  JSON.stringify(
    sortedObject(
      locks->Dict.mapValues(l =>
        JSON.Encode.object(
          dict{
            "source": JSON.Encode.string(l.source),
            "element": JSON.Encode.object(
              dict{
                "plugin": JSON.Encode.string(l.element.plugin),
                "identifier": JSON.Encode.string(l.element.identifier),
                "kind": JSON.Encode.string(l.element.kind),
              },
            ),
            "terms": sortedObject(l.terms->Dict.mapValues(JSON.Encode.string)),
          },
        )
      ),
    ),
    ~space=2,
  ) ++ "\n"

let readCatalogue = (text: string): dict<string> =>
  try JSON.parseOrThrow(text)
  ->JSON.Decode.object
  ->Option.getOr(Dict.make())
  ->Dict.toArray
  ->Array.filterMap(((k, v)) => v->JSON.Decode.string->Option.map(s => (k, s)))
  ->Dict.fromArray catch {
  | _ => Dict.make()
  }

let readLocks = (text: string): dict<lock> =>
  try {
    let str = (d, k) => d->Dict.get(k)->Option.flatMap(JSON.Decode.string)
    JSON.parseOrThrow(text)
    ->JSON.Decode.object
    ->Option.getOr(Dict.make())
    ->Dict.toArray
    ->Array.filterMap(((key, v)) =>
      v
      ->JSON.Decode.object
      ->Option.flatMap(o => {
        let element = o->Dict.get("element")->Option.flatMap(JSON.Decode.object)
        switch (str(o, "source"), element) {
        | (Some(source), Some(e)) =>
          Some((
            key,
            {
              source,
              element: {
                plugin: str(e, "plugin")->Option.getOr(""),
                identifier: str(e, "identifier")->Option.getOr(""),
                kind: str(e, "kind")->Option.getOr(""),
              },
              terms: o
              ->Dict.get("terms")
              ->Option.flatMap(JSON.Decode.object)
              ->Option.mapOr(
                Dict.make(),
                t =>
                  t
                  ->Dict.toArray
                  ->Array.filterMap(((k, v)) => v->JSON.Decode.string->Option.map(s => (k, s)))
                  ->Dict.fromArray,
              ),
            },
          ))
        | _ => None
        }
      })
    )
    ->Dict.fromArray
  } catch {
  | _ => Dict.make()
  }
