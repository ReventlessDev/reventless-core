/**
Renders message text from a template, a JSON payload and the payload's schema.

Grammar: `{{ path }}`, `{{ path | formatter }}`, `{{# if path }}…{{/ if }}` and
`{{# each path }}…{{ .field }}…{{/ each }}`. Total and pure — nothing is
evaluated, an unresolved path renders a visible placeholder rather than throwing,
and a field the schema marks `@sensitive` is withheld.
*/

/** A path into the payload, in **wire** field names. `text` is what was written,
    so a placeholder can name it. */
type path = {text: string, relative: bool, segments: array<string>}

type rec node =
  | Text(string)
  | Field({path: path, formatter: option<string>})
  | If({path: path, body: array<node>})
  | Each({path: path, body: array<node>})

/** A parsed template. */
type t = array<node>

/** Renders the value as the payload holds it, whatever semantic it carries. */
let rawFormatter = "raw"

/** The override vocabulary *is* the semantic vocabulary, so no second table can
    drift from it. */
let formatters = [
  rawFormatter,
  Semantic.Id.money,
  Semantic.Id.percent,
  Semantic.Id.bytes,
  Semantic.Id.duration,
  Semantic.Id.dateRange,
  Semantic.Id.geoPoint,
]

// ---------- parsing ----------

let segmentGrammar = /^[A-Za-z0-9_]+$/
let whitespace = /\s+/g

let parsePath = (raw: string, ~insideEach: bool): result<path, string> => {
  let text = raw->String.trim
  if text == "" {
    Error("a tag with no path")
  } else {
    let relative = text->String.startsWith(".")
    if relative && !insideEach {
      Error(`"${text}" is item-relative, and there is no item outside an "each"`)
    } else {
      let body = relative ? text->String.slice(~start=1) : text
      let segments = body == "" ? [] : body->String.split(".")
      segments->Array.every(segment => segmentGrammar->RegExp.test(segment))
        ? Ok({text, relative, segments})
        : Error(
            `"${text}" is not a path — segments are letters, digits and ` ++
            `underscores, separated by dots`,
          )
    }
  }
}

type token = TextToken(string) | TagToken(string)

let tokenize = (source: string): result<array<token>, string> => {
  let tokens = []
  let rest = ref(source)
  let failure = ref(None)
  let running = ref(true)
  while running.contents {
    let current = rest.contents
    switch current->String.indexOf("{{") {
    | -1 =>
      if current != "" {
        tokens->Array.push(TextToken(current))
      }
      running := false
    | start =>
      let before = current->String.slice(~start=0, ~end=start)
      if before != "" {
        tokens->Array.push(TextToken(before))
      }
      let after = current->String.slice(~start=start + 2)
      switch after->String.indexOf("}}") {
      | -1 =>
        failure := Some(`an opening "{{" with no closing "}}"`)
        running := false
      | stop =>
        tokens->Array.push(
          TagToken(
            after
            ->String.slice(~start=0, ~end=stop)
            ->String.replaceRegExp(whitespace, " ")
            ->String.trim,
          ),
        )
        rest := after->String.slice(~start=stop + 2)
      }
    }
  }
  switch failure.contents {
  | Some(message) => Error(message)
  | None => Ok(tokens)
  }
}

type blockKind = IfBlock | EachBlock

let blockWord = (kind: blockKind) =>
  switch kind {
  | IfBlock => "if"
  | EachBlock => "each"
  }

type frame = {kind: blockKind, path: path, body: array<node>}

/** Parse a template, or say what is wrong with it. */
let parse = (source: string): result<t, string> =>
  switch tokenize(source) {
  | Error(message) => Error(message)
  | Ok(tokens) => {
      let root: array<node> = []
      let stack: array<frame> = []
      let failure = ref(None)

      let fail = message =>
        if failure.contents->Option.isNone {
          failure := Some(message)
        }

      let body = () =>
        switch stack->Array.at(-1) {
        | Some(frame) => frame.body
        | None => root
        }

      let insideEach = () => stack->Array.some(frame => frame.kind == EachBlock)

      let addField = (rawPath, formatter) =>
        switch parsePath(rawPath, ~insideEach=insideEach()) {
        | Error(message) => fail(message)
        | Ok(path) => body()->Array.push(Field({path, formatter}))
        }

      let openBlock = (kind, rawPath) =>
        if kind == EachBlock && insideEach() {
          fail(`an "each" inside an "each" — iteration is one level deep`)
        } else {
          switch parsePath(rawPath, ~insideEach=insideEach()) {
          | Error(message) => fail(message)
          | Ok(path) => stack->Array.push({kind, path, body: []})
          }
        }

      let closeBlock = word =>
        switch stack->Array.pop {
        | None => fail(`a closing "{{/ ${word} }}" with nothing open`)
        | Some(frame) =>
          blockWord(frame.kind) != word
            ? fail(`"{{/ ${word} }}" closes a "${blockWord(frame.kind)}"`)
            : body()->Array.push(
                switch frame.kind {
                | IfBlock => If({path: frame.path, body: frame.body})
                | EachBlock => Each({path: frame.path, body: frame.body})
                },
              )
        }

      tokens->Array.forEach(token =>
        if failure.contents->Option.isNone {
          switch token {
          | TextToken(text) => body()->Array.push(Text(text))
          | TagToken(tag) =>
            if tag->String.startsWith("#") {
              let rest = tag->String.slice(~start=1)->String.trim
              switch rest->String.indexOf(" ") {
              | -1 => fail(`"{{# ${rest} }}" opens a block with no path`)
              | at =>
                switch rest->String.slice(~start=0, ~end=at) {
                | "if" => openBlock(IfBlock, rest->String.slice(~start=at + 1))
                | "each" => openBlock(EachBlock, rest->String.slice(~start=at + 1))
                | word => fail(`"${word}" is not a block — "if" and "each" are`)
                }
              }
            } else if tag->String.startsWith("/") {
              closeBlock(tag->String.slice(~start=1)->String.trim)
            } else {
              switch tag->String.split("|") {
              | [rawPath] => addField(rawPath, None)
              | [rawPath, name] =>
                let formatter = name->String.trim
                formatters->Array.includes(formatter)
                  ? addField(rawPath, Some(formatter))
                  : fail(
                      `"${formatter}" is not a formatter — one of ` ++
                      formatters->Array.join(", "),
                    )
              | _ => fail(`"${tag}" names more than one formatter`)
              }
            }
          }
        }
      )

      switch failure.contents {
      | Some(message) => Error(message)
      | None =>
        switch stack->Array.at(-1) {
        | Some(frame) =>
          Error(`"{{# ${blockWord(frame.kind)} ${frame.path.text} }}" was never closed`)
        | None => Ok(root)
        }
      }
    }
  }

// ---------- rendering ----------

/** A value and the schema describing it, at one point in the payload. */
type scope = {value: option<JSON.t>, schema: option<S.t<unknown>>}

let nothing: scope = {value: None, schema: None}

let missing = (path: path) => `[missing: ${path.text}]`
let withheld = (path: path) => `[withheld: ${path.text}]`

/** How many items one `each` renders before it stops and says how many it left. */
let maxItems = 100

let unwrap = (schema: S.t<unknown>) => schema->Semantic.unwrapOptional->Option.getOr(schema)

let propertyOf = (schema: S.t<unknown>, name: string): option<S.t<unknown>> =>
  switch schema->unwrap {
  | Object({properties}) => properties->Dict.get(name)
  | _ => None
  }

let elementOf = (schema: S.t<unknown>): option<S.t<unknown>> =>
  switch schema->unwrap {
  | Array({additionalItems: Schema(item)}) => Some(item)
  | _ => None
  }

let step = (scope: scope, segment: string): scope => {
  value: switch scope.value {
  | Some(Object(fields)) => fields->Dict.get(segment)
  | _ => None
  },
  schema: scope.schema->Option.flatMap(propertyOf(_, segment)),
}

let resolve = (path: path, ~root: scope, ~item: option<scope>): scope =>
  path.segments->Array.reduce(path.relative ? item->Option.getOr(nothing) : root, step)

/** A dotted path looked up in a payload, with no schema and no item scope — the
    same walk a template does, for a caller that is not rendering one. */
let lookup = (payload: JSON.t, dotted: string): option<JSON.t> =>
  dotted
  ->String.split(".")
  ->Array.reduce({value: Some(payload), schema: None}, step)
  ->(scope => scope.value)

/** Absent means "not stated", not "safe": a schema this walk cannot follow
    renders, the open failure `Sensitive` documents. */
let isWithheld = (schema: option<S.t<unknown>>): bool =>
  switch schema {
  | None => false
  | Some(field) =>
    Sensitive.isFieldSensitive(field) ||
      switch Semantic.getFrom(field) {
      | Some({id}) => Sensitive.impliedBySemantic(id)
      | None => false
      }
  }

let parseSafely = (json: JSON.t, schema: S.t<'a>): option<'a> =>
  try Some(json->S.parseOrThrow(~to=schema)) catch {
  | _ => None
  }

let formatBySemantic = (json: JSON.t, ~id: string): option<string> =>
  if id == Semantic.Id.money {
    json->parseSafely(Money.schema)->Option.map(Money.format)
  } else if id == Semantic.Id.dateRange {
    json->parseSafely(DateRange.schema)->Option.map(DateRange.format)
  } else if id == Semantic.Id.geoPoint {
    json->parseSafely(GeoPoint.schema)->Option.map(GeoPoint.format)
  } else {
    switch json {
    | Number(number) =>
      if id == Semantic.Id.percent {
        Some(Percent.format(number))
      } else if id == Semantic.Id.bytes {
        Some(Bytes.format(number))
      } else if id == Semantic.Id.duration {
        Some(Duration.format(Float.toInt(number)))
      } else {
        None
      }
    | _ => None
    }
  }

let scalar = (value: JSON.t): string =>
  switch value {
  | String(text) => text
  | Number(number) => Float.toString(number)
  | Boolean(flag) => flag ? "true" : "false"
  | Null => ""
  | Object(_) | Array(_) => value->JSON.stringify
  }

let truthy = (value: option<JSON.t>): bool =>
  switch value {
  | None
  | Some(Null)
  | Some(Boolean(false))
  | Some(String(""))
  | Some(Array([])) => false
  | Some(Number(number)) => number != 0.0
  | Some(_) => true
  }

let renderField = (path, ~formatter, ~root, ~item) => {
  let scope = resolve(path, ~root, ~item)
  if isWithheld(scope.schema) {
    withheld(path)
  } else {
    switch scope.value {
    | None | Some(Null) => missing(path)
    | Some(value) =>
      // An override that does not apply falls back to the plain value rather
      // than to a placeholder: the value is there, only the shaping failed.
      switch formatter {
      | Some(name) if name == rawFormatter => scalar(value)
      | Some(name) => formatBySemantic(value, ~id=name)->Option.getOr(scalar(value))
      | None =>
        switch scope.schema->Option.flatMap(Semantic.getFrom) {
        | Some({id}) => formatBySemantic(value, ~id)->Option.getOr(scalar(value))
        | None => scalar(value)
        }
      }
    }
  }
}

// A guard on a withheld field is allowed: it renders no value, and refusing it
// would silently drop the body of `{{# if customer.email }}`.
let rec renderNodes = (
  nodes: array<node>,
  ~root: scope,
  ~item: option<scope>,
  ~out: array<string>,
) =>
  nodes->Array.forEach(node =>
    switch node {
    | Text(text) => out->Array.push(text)
    | Field({path, formatter}) => out->Array.push(renderField(path, ~formatter, ~root, ~item))
    | If({path, body}) =>
      if truthy(resolve(path, ~root, ~item).value) {
        renderNodes(body, ~root, ~item, ~out)
      }
    | Each({path, body}) =>
      let scope = resolve(path, ~root, ~item)
      if isWithheld(scope.schema) {
        out->Array.push(withheld(path))
      } else {
        switch scope.value {
        | Some(Array(items)) =>
          let element = scope.schema->Option.flatMap(elementOf)
          let total = Array.length(items)
          let shown = total > maxItems ? maxItems : total
          for index in 0 to shown - 1 {
            renderNodes(
              body,
              ~root,
              ~item=Some({value: items->Array.get(index), schema: element}),
              ~out,
            )
          }
          if total > shown {
            out->Array.push(`[… ${Int.toString(total - shown)} more]`)
          }
        | _ => out->Array.push(missing(path))
        }
      }
    }
  )

/** Render a parsed template. `schema` describes `payload` — for an event union,
    take the arm with `variantSchema`. */
let render = (template: t, ~payload: JSON.t, ~schema: S.t<'a>): string => {
  let out = []
  renderNodes(
    template,
    ~root={value: Some(payload), schema: Some(schema->S.castToUnknown)},
    ~item=None,
    ~out,
  )
  out->Array.join("")
}

/** Parse and render in one call, for a template held as text rather than
    compiled once. */
let renderSource = (source: string, ~payload: JSON.t, ~schema: S.t<'a>): result<string, string> =>
  parse(source)->Result.map(template => render(template, ~payload, ~schema))

/** The object schema of one arm of a command or event union — what `render`
    wants, since a message is about one occurrence. */
let variantSchema = (schema: S.t<'a>, ~variant: string): option<S.t<unknown>> =>
  schema->S.castToUnknown->Semantic.unionVariant(~variant)
