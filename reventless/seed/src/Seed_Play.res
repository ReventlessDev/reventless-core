// A data set read from a file, for a caller who writes no ReScript: mutations by
// name with their arguments, encoded by `Seed_Commands` from what the API says.
//
//   pace: 30/min~          # optional; SEED_PACE overrides
//   repeatable: true       # optional; then SEED_REPEAT may play it again
//   steps:
//     - send: Catalog_AddCategory
//       args: {categoryId: "cat-{run}-{rep}", name: "Toys {rep}"}
//     - waitFor: {field: Catalog_CategoriesByIds, ids: ["cat-{run}-{rep}"]}
//     - id: order                       # optional; the result names the step by it
//       send: Ordering_PlaceOrder
//       as: ada
//       args: {orderId: "o-{run}-{rep}", ownerId: "{id:ada}"}
//       expect: accepted                # or {refused: <errorCode>}, or {acceptedOr: <errorCode>}
//                                       #   when an earlier play may have made it already
//       row: {view: Ordering_OrdersByIds, key: "o-{run}-{rep}", has: {lifecycle: "{any}"}}
//     - id: ada-looks                   # a step that only reads a row, as its person
//       as: ada
//       row: {view: Ordering_OrdersByIds, key: "o-{run}-{rep}", has: {ownerId: "{id:ada}"}}
//
// `{rep}` is the repetition's number in this run, `{run}` names the run
// (`SEED_RUN_TAG`, else the start time), so ids differ between runs and repeat
// within one when the tag is given. `{id:ada}` is the id of the account that
// plays ada on the platform the file is played into.
//
// A step with `as` is sent, or waited for, as the account that plays that
// person: the account whose `demoOwner` is the name, else the one whose
// username it is, from the accounts file. Each such account signs in once per
// run; a step without `as` goes as the run's caller.
//
// A step that says what it `expect`s, or which `row` a view then shows, makes the
// file a play that expects: it stops at the first step that went otherwise, says
// what came instead, and writes what came of each step to `SEED_RESULT` when that
// names a file. Such a play is refused on a platform that is production or does
// not say what it is for, and on a file in which no value has `{run}`.

open Seed_Types

/** A row a step's view shows after it: `key` of the `view` field, with the values `has` names. */
type row = {view: string, key: string, has: dict<JSON.t>}

type step =
  | Send({
      field: string,
      args: JSON.t,
      as_?: string,
      id?: string,
      expect?: Seed_Client.expected,
      row?: row,
    })
  | WaitFor({field: string, ids: array<string>, as_?: string})
  /** A step that sends nothing and reads a row, as its person: someone looks at a view. */
  | Read({row: row, as_?: string, id?: string})

type file = {pace?: string, repeatable: bool, steps: array<step>}

let expectOf = (json: JSON.t, ~at: string): result<option<Seed_Client.expected>, string> =>
  switch json->Seed_Commands.get("expect") {
  | None => Ok(None)
  | Some(String("accepted")) => Ok(Some(Accepted))
  | Some(Object(_) as e) =>
    switch (e->Seed_Commands.str("refused"), e->Seed_Commands.str("acceptedOr")) {
    | (Some(code), None) if code != "" => Ok(Some(Refused(code)))
    | (None, Some(code)) if code != "" => Ok(Some(AcceptedOr(code)))
    | _ => Error(`${at}: expect is accepted, {refused: <errorCode>} or {acceptedOr: <errorCode>}`)
    }
  | Some(_) =>
    Error(`${at}: expect is accepted, {refused: <errorCode>} or {acceptedOr: <errorCode>}`)
  }

let rowOf = (json: JSON.t, ~at: string): result<option<row>, string> =>
  switch json->Seed_Commands.get("row") {
  | None => Ok(None)
  | Some(r) =>
    switch (
      r->Seed_Commands.str("view"),
      r->Seed_Commands.str("key"),
      r->Seed_Commands.get("has"),
    ) {
    | (Some(view), Some(key), None) => Ok(Some({view, key, has: Dict.make()}))
    | (Some(view), Some(key), Some(Object(has))) => Ok(Some({view, key, has}))
    | _ => Error(`${at}: row needs a view, a key and, if any, an object of the values it has`)
    }
  }

let stepOf = (json: JSON.t, ~index: int): result<step, string> => {
  let at = `step ${(index + 1)->Int.toString}`
  let as_ = json->Seed_Commands.str("as")
  let id = json->Seed_Commands.str("id")
  switch (
    json->Seed_Commands.str("send"),
    json->Seed_Commands.get("args"),
    json->Seed_Commands.get("waitFor"),
  ) {
  | _ if json->Seed_Commands.get("as")->Option.isSome && as_ == Some("") =>
    Error(`${at}: as names nobody`)
  | (Some(field), (Some(Object(_)) | None) as args, None) =>
    switch (expectOf(json, ~at), rowOf(json, ~at)) {
    | (Error(e), _) | (_, Error(e)) => Error(e)
    | (Ok(expect), Ok(row)) =>
      Ok(
        Send({
          field,
          args: args->Option.getOr(JSON.Encode.object(Dict.make())),
          ?as_,
          ?id,
          ?expect,
          ?row,
        }),
      )
    }
  | (None, None, None) if json->Seed_Commands.get("row")->Option.isSome =>
    switch rowOf(json, ~at) {
    | Error(e) => Error(e)
    | Ok(None) => Error(`${at}: expected {send, args}, {waitFor: {field, ids}} or {row}`)
    | Ok(Some(row)) => Ok(Read({row, ?as_, ?id}))
    }
  | (None, None, Some(wait)) =>
    switch (wait->Seed_Commands.str("field"), wait->Seed_Commands.items("ids")) {
    | (Some(field), ids) if ids->Array.length > 0 =>
      Ok(
        WaitFor({
          field,
          ids: ids->Array.filterMap(id =>
            switch id {
            | String(s) => Some(s)
            | _ => None
            }
          ),
          ?as_,
        }),
      )
    | _ => Error(`${at}: waitFor needs a field and a list of ids`)
    }
  | _ => Error(`${at}: expected {send, args}, {waitFor: {field, ids}} or {row}`)
  }
}

let parse = (text: string): result<file, string> =>
  switch try Some(Seed_Accounts.parseYaml(text)) catch {
  | _ => None
  } {
  | None => Error("the file is neither YAML nor JSON")
  | Some(doc) =>
    let steps =
      doc
      ->Seed_Commands.items("steps")
      ->Array.mapWithIndex((s, index) => stepOf(s, ~index))
    switch steps->Array.find(Result.isError) {
    | Some(Error(message)) => Error(message)
    | _ if steps->Array.length == 0 => Error("the file lists no steps")
    | _ =>
      Ok({
        pace: ?(doc->Seed_Commands.str("pace")),
        repeatable: doc->Seed_Commands.get("repeatable") == Some(Boolean(true)),
        steps: steps->Array.filterMap(r => r->Result.mapOr(None, s => Some(s))),
      })
    }
  }

/** Whether any step of `file` says what it expects: then the file is a play that expects. */
let expects = (file: file): bool =>
  file.steps->Array.some(step =>
    switch step {
    | Send({?expect, ?row}) => expect->Option.isSome || row->Option.isSome
    | Read(_) => true
    | WaitFor(_) => false
    }
  )

/** How a step is named in what is said about it: its `id`, else its number. */
let stepName = (file: file, index: int): string =>
  switch file.steps[index] {
  | Some(Send({id: ?Some(id)})) | Some(Read({id: ?Some(id)})) => id
  | _ => `step ${(index + 1)->Int.toString}`
  }

let rec fill = (json: JSON.t, ~vars: array<(string, string)>): JSON.t =>
  switch json {
  | String(s) => String(vars->Array.reduce(s, (acc, (k, v)) => acc->String.replaceAll(`{${k}}`, v)))
  | Array(xs) => Array(xs->Array.map(x => fill(x, ~vars)))
  | Object(d) => Object(d->Dict.mapValues(x => fill(x, ~vars)))
  | other => other
  }

/** `20261120T101500` for the start of a run, when `SEED_RUN_TAG` names none. */
let runTag = (): string =>
  Seed_Prompt.envValue("SEED_RUN_TAG")->Option.getOr(
    Date.make()
    ->Date.toISOString
    ->String.slice(~start=0, ~end=19)
    ->String.replaceAll("-", "")
    ->String.replaceAll(":", ""),
  )

/** Every string in `json`, nested ones too. */
let rec strings = (json: JSON.t): array<string> =>
  switch json {
  | String(s) => [s]
  | Array(xs) => xs->Array.flatMap(strings)
  | Object(d) => d->Dict.valuesToArray->Array.flatMap(strings)
  | _ => []
  }

/** Every value a step's command or row is written with. */
let valuesOf = (step: step): array<string> =>
  switch step {
  | Send({args, ?row}) =>
    Array.concat(strings(args), row->Option.mapOr([], r => [r.key, ...strings(JSON.Object(r.has))]))
  | Read({row}) => [row.key, ...strings(JSON.Object(row.has))]
  | WaitFor({ids}) => ids
  }

/** The people whose ids the file's values name (`{id:ada}`), each once. */
let idNames = (file: file): array<string> =>
  file.steps
  ->Array.flatMap(valuesOf)
  ->Array.flatMap(s =>
    s
    ->String.match(/\{id:([^}]+)\}/g)
    ->Option.getOr([])
    ->Array.filterMap(m => m->Option.map(m => m->String.slice(~start=4, ~end=-1)))
  )
  ->Array.reduce([], (seen, name) => seen->Array.includes(name) ? seen : [...seen, name])

/** The people the file's steps act as, or whose ids it names, each once, in the order they
    first come. */
let people = (file: file): array<string> =>
  file.steps
  ->Array.filterMap(step =>
    switch step {
    | Send({?as_}) | WaitFor({?as_}) | Read({?as_}) => as_
    }
  )
  ->Array.concat(idNames(file))
  ->Array.reduce([], (seen, name) => seen->Array.includes(name) ? seen : [...seen, name])

/** Whether any value of `file` has `{run}`, the mark that keeps one play from meeting another. */
let marked = (file: file): bool =>
  file.steps->Array.some(step => valuesOf(step)->Array.some(s => s->String.includes("{run}")))

/** The ids a command is sent with that carry neither the run's mark nor a person's id: each
    names something that is there before the play. Read from the mutation as encoded, so only
    what the API types as an `ID` counts. */
let unmarkedIds = (m: mutation): array<string> => {
  let rec walk = (path: string, v: value): array<string> =>
    switch v {
    | Id(s) if !(s->String.includes("{run}")) && !(s->String.includes("{id:")) => [`${path} "${s}"`]
    | List(xs) => xs->Array.flatMapWithIndex((x, i) => walk(`${path}[${i->Int.toString}]`, x))
    | Object(fs) => fs->Array.flatMap(((k, x)) => walk(`${path}.${k}`, x))
    | _ => []
    }
  m.args->Array.flatMap(((k, v)) => walk(`${m.field}.${k}`, v))
}

/** Why a play that expects may not be played on a platform that says `purpose`, if it may not. */
let refusePurpose = (~purpose: option<string>, ~label: string): option<string> =>
  switch purpose {
  | Some("production") =>
    Some(
      `${label} is production, and a file that says what its steps expect writes into it: it is never played there`,
    )
  | Some(_) => None
  | None =>
    Some(
      `${label} does not say what it is for (its config.json has no environmentPurpose), so a file that says what its steps expect is not played there`,
    )
  }

// ── What came of each step ──────────────────────────────────────────────────

let str = (s: string) => JSON.String(s)

let answerJson = (a: Seed_Client.answer): JSON.t => JSON.Object(
  Dict.fromArray(
    Array.concat(
      [("accepted", JSON.Boolean(a.accepted))],
      Array.concat(
        a.code->Option.mapOr([], c => [("code", str(c))]),
        a.detail->Option.mapOr([], d => [("detail", str(d))]),
      ),
    ),
  ),
)

let rowJson = (r: row, read: Seed_Client.rowRead): JSON.t => JSON.Object(
  Dict.fromArray(
    Array.concat(
      [
        ("view", str(r.view)),
        ("key", str(r.key)),
        ("has", JSON.Object(r.has)),
        ("matches", JSON.Boolean(read.matches)),
        ("waitedMs", JSON.Number(read.waitedMs->Int.toFloat)),
      ],
      Array.concat(
        read.values->Option.mapOr([], v => [("values", v)]),
        read.denied ? [("denied", JSON.Boolean(true))] : [],
      ),
    ),
  ),
)

/** What is said when a row did not come as wanted. */
let rowWords = (r: row, read: Seed_Client.rowRead): string =>
  if read.denied {
    `${r.view} refuses the step's person, so its row ${r.key} cannot be read`
  } else {
    let seconds = (read.waitedMs / 1000)->Int.toString
    switch read.values {
    | None => `${r.view} shows no row ${r.key} after ${seconds}s`
    | Some(values) =>
      `${r.view} row ${r.key} shows ${JSON.stringify(
          values,
        )} after ${seconds}s, not ${JSON.stringify(JSON.Object(r.has))}`
    }
  }

/** Sends one repetition of `file`'s steps, each as its person's client (`clientOf`), else as
    `client`. What came of each step is pushed to `results`; a step that went otherwise than it
    expects stops the repetition there. */
let playOnce = async (
  file: file,
  ~commands: Seed_Commands.t,
  ~client,
  ~clientOf: string => promise<Seed_Client.t>=async _ => client,
  ~vars,
  ~results: array<JSON.t>=[],
  ~rowTimeoutMs: int=60000,
) =>
  for i in 0 to file.steps->Array.length - 1 {
    let clientAs = async (as_: option<string>) =>
      switch as_ {
      | Some(name) => await clientOf(name)
      | None => client
      }
    let name = stepName(file, i)
    let said = (fields: array<(string, JSON.t)>) =>
      results->Array.push(JSON.Object(Dict.fromArray([("step", str(name)), ...fields])))
    // The row `r` read as `client`, said after `base`; a row that does not come stops the play.
    let readTheRow = async (client, r: row, ~base) => {
      let r = {
        view: r.view,
        key: switch fill(String(r.key), ~vars) {
        | String(k) => k
        | _ => r.key
        },
        has: switch fill(JSON.Object(r.has), ~vars) {
        | Object(h) => h
        | _ => r.has
        },
      }
      let read = await client->Seed_Client.readRow(
        ~field=r.view,
        ~key=r.key,
        ~wanted=r.has,
        ~timeoutMs=rowTimeoutMs,
      )
      said([...base, ("row", rowJson(r, read))])
      if !read.matches {
        throw(Failed(`${name}: ${rowWords(r, read)}`))
      }
    }
    switch file.steps[i] {
    | Some(Send({field, args, ?as_, ?expect, ?row})) =>
      let client = await clientAs(as_)
      let m = commands->Seed_Commands.encodeOrThrow(~field, fill(args, ~vars))
      let who = as_->Option.mapOr([], a => [("as", str(a))])
      switch (expect, row) {
      | (None, None) =>
        (await client->Seed_Client.send(m))->ignore
        said([("send", str(field)), ...who, ("came", answerJson({accepted: true}))])
      | _ =>
        let expected = expect->Option.getOr(Seed_Client.Accepted)
        let (answer, ok) = await client->Seed_Client.sendExpecting(m, ~expect=expected)
        let base = [
          ("send", str(field)),
          ...who,
          ("expected", str(Seed_Client.expectedWords(expected))),
          ("came", answerJson(answer)),
        ]
        if !ok {
          said(base)
          throw(
            Failed(
              `${name}: ${field} was expected to be ${Seed_Client.expectedWords(
                  expected,
                )}, and was ${Seed_Client.answerWords(answer)}${answer.detail->Option.mapOr("", d =>
                  ` (${d})`
                )}`,
            ),
          )
        }
        switch row {
        | None => said(base)
        | Some(r) => await readTheRow(client, r, ~base)
        }
      }
    | Some(Read({row, ?as_})) =>
      let client = await clientAs(as_)
      await readTheRow(client, row, ~base=as_->Option.mapOr([], a => [("as", str(a))]))
    | Some(WaitFor({field, ids, ?as_})) =>
      let client = await clientAs(as_)
      let ids = ids->Array.map(id => {
        let filled = fill(String(id), ~vars)
        switch filled {
        | String(s) => s
        | _ => id
        }
      })
      (await client->Seed_Client.waitForIds(~field, ~ids))->ignore
    | None => ()
    }
  }

// ── Checking a file against the API ─────────────────────────────────────────

let queryFieldsQuery = `${Seed_Commands.typeRefFragment}
query { __schema { queryType { fields { name type { ...TypeRef } } } } }`

let rec namedOf = (t: Seed_Commands.typeRef): string =>
  switch t {
  | Named(n) => n
  | NonNull(inner) | ListOf(inner) => namedOf(inner)
  }

/** Why each `row` of `file` cannot be read on this API, if one cannot: a view it does not have,
    or a value the view's rows do not carry. */
let rowProblems = async (file: file, ~client: Seed_Client.t, ~path: string): array<string> => {
  let rows = file.steps->Array.filterMapWithIndex((step, i) =>
    switch step {
    | Send({row: ?Some(r)}) | Read({row: r}) => Some((stepName(file, i), r))
    | _ => None
    }
  )
  if rows == [] {
    []
  } else {
    let data = await client->Seed_Client.gql(~query=queryFieldsQuery, ~label="introspection")
    let views =
      data
      ->Seed_Commands.get("__schema")
      ->Option.flatMap(s => s->Seed_Commands.get("queryType"))
      ->Option.mapOr([], q => q->Seed_Commands.items("fields"))
      ->Array.filterMap(f =>
        switch (f->Seed_Commands.str("name"), f->Seed_Commands.get("type")) {
        | (Some(n), Some(t)) => Some((n, namedOf(Seed_Commands.typeRefOf(t))))
        | _ => None
        }
      )
      ->Dict.fromArray
    let problems = []
    for i in 0 to rows->Array.length - 1 {
      let (name, r) = rows->Array.getUnsafe(i)
      switch views->Dict.get(r.view) {
      | None => problems->Array.push(`${path}: ${name}: the API has no view "${r.view}"`)
      | Some(rowType) =>
        let typeData = await client->Seed_Client.gql(
          ~query=`{ __type(name: ${quote(rowType)}) { fields { name } } }`,
          ~label="introspection",
        )
        let fields =
          typeData
          ->Seed_Commands.get("__type")
          ->Option.mapOr([], t => t->Seed_Commands.items("fields"))
          ->Array.filterMap(f => f->Seed_Commands.str("name"))
        r.has
        ->Dict.keysToArray
        ->Array.filter(k => !(fields->Array.includes(k)))
        ->Array.forEach(k =>
          problems->Array.push(`${path}: ${name}: a row of ${r.view} has no "${k}"`)
        )
      }
    }
    problems
  }
}

/** Writes what came of a repetition to `SEED_RESULT`, when that names a file. */
let writeResult = (
  ~connection: Seed_Connect.connection,
  ~run: string,
  ~repetition: string,
  ~results: array<JSON.t>,
  ~stopped: option<string>,
) =>
  switch Seed_Prompt.envValue("SEED_RESULT") {
  | None => ()
  | Some(path) =>
    let record = JSON.Object(
      Dict.fromArray(
        Array.concat(
          [
            ("platform", str(connection.label)),
            ("run", str(run)),
            ("repetition", str(repetition)),
            ("finished", JSON.Boolean(stopped->Option.isNone)),
            ("steps", JSON.Array(results)),
          ],
          Array.concat(
            connection.purpose->Option.mapOr([], p => [("purpose", str(p))]),
            stopped->Option.mapOr([], s => [("stopped", str(s))]),
          ),
        ),
      ),
    )
    NodeFs.writeFileSync(path, JSON.stringify(record, ~space=2) ++ "\n")
  }

/** How long a `row` is read before it counts as not come: `SEED_ROW_TIMEOUT` seconds, else 60. */
let rowTimeoutMs = (): int =>
  switch Seed_Prompt.envValue("SEED_ROW_TIMEOUT")->Option.flatMap(s => Int.fromString(s)) {
  | Some(seconds) if seconds > 0 => seconds * 1000
  | _ => 60000
  }

/**
 * The data set a file at `path` describes. The file is read and checked here,
 * so a mistake in it stops the run before anything is sent; its mutations are
 * checked against the API's own description before the first one is sent.
 */
let dataSet = (~path: string, ~name="file"): Seed_DataSet.t => {
  let file = switch NodeFs.existsSync(path)
    ? parse(NodeFs.readFileSync(path))
    : Error("no such file") {
  | Ok(file) => file
  | Error(message) => throw(Failed(`${path}: ${message}`))
  }
  let run = runTag()
  let repetition = ref(0)
  let commands = ref(None)
  {
    name,
    label: `${name} — ${file.steps->Array.length->Int.toString} steps from ${path}`,
    repeatable: file.repeatable,
    pace: ?file.pace,
    preflight: async connection => {
      // A play that expects writes where people may work: only where the platform says it is
      // not production, and only marked by its run.
      if expects(file) {
        switch refusePurpose(~purpose=connection.purpose, ~label=connection.label) {
        | Some(message) => throw(Failed(`${path}: ${message}`))
        | None => ()
        }
        if !marked(file) {
          throw(
            Failed(
              `${path}: a file that says what its steps expect needs {run} in the ids it makes, so one play never meets another, and no value has it`,
            ),
          )
        }
      }
      let read = await Seed_Commands.fetch(connection.client)
      // Every person a step acts as, or whose id it names, is played by an account, before
      // anything is sent.
      people(file)->Array.forEach(name =>
        switch Seed_Accounts.playing(connection.accounts, name) {
        | Some(_) => ()
        | None =>
          throw(
            Failed(
              `${path}: a step acts as ${name}, or names their id, and no account in the accounts file plays ${name}`,
            ),
          )
        }
      )
      file.steps->Array.forEachWithIndex((step, i) =>
        switch step {
        | Send({field, args}) =>
          switch read->Seed_Commands.encode(
            ~field,
            fill(args, ~vars=[("run", run), ("rep", "1")]),
          ) {
          | Error(message) => throw(Failed(`${path}: ${message}`))
          | Ok(_) => ()
          }

          // Said, not refused: a play may reach for something that is there before it.
          if expects(file) {
            switch read->Seed_Commands.encode(~field, args) {
            | Ok(m) =>
              unmarkedIds(m)->Array.forEach(id =>
                Console.log(
                  `  note: ${stepName(
                      file,
                      i,
                    )}: ${id} carries no {run}: it names something that is there before the play`,
                )
              )
            | Error(_) => ()
            }
          }
        | WaitFor(_) | Read(_) => ()
        }
      )
      switch await rowProblems(file, ~client=connection.client, ~path) {
      | [] => ()
      | problems => throw(Failed(problems->Array.join("\n")))
      }
      commands := Some(read)
    },
    seed: async connection => {
      repetition := repetition.contents + 1
      let rep = repetition.contents->Int.toString
      Console.log(`  run ${run}, repetition ${rep}`)
      // Each person's account signs in once, the first time a step acts as them.
      let clients: dict<Seed_Client.t> = Dict.make()
      let clientOf = async name =>
        switch clients->Dict.get(name) {
        | Some(client) => client
        | None =>
          switch Seed_Accounts.playing(connection.accounts, name) {
          | None => throw(Failed(`${path}: no account plays ${name}`))
          | Some(account) =>
            let client = await Seed_Connect.clientFor(connection, ~account)
            clients->Dict.set(name, client)
            client
          }
        }
      // A person's id is the one their account carries here, read from their own sign-in.
      let names = idNames(file)
      let ids = []
      for i in 0 to names->Array.length - 1 {
        let person = names->Array.getUnsafe(i)
        switch Seed_Client.callerId(await clientOf(person)) {
        | Some(id) => ids->Array.push((`id:${person}`, id))
        | None =>
          throw(Failed(`${path}: the account that plays ${person} carries no id in its sign-in`))
        }
      }
      let results = []
      switch commands.contents {
      | Some(commands) =>
        try await playOnce(
          file,
          ~commands,
          ~client=connection.client,
          ~clientOf,
          ~vars=[("run", run), ("rep", rep), ...ids],
          ~results,
          ~rowTimeoutMs=rowTimeoutMs(),
        ) catch {
        | Failed(message) as exn =>
          writeResult(~connection, ~run, ~repetition=rep, ~results, ~stopped=Some(message))
          throw(exn)
        }
        writeResult(~connection, ~run, ~repetition=rep, ~results, ~stopped=None)
        if expects(file) {
          Console.log(
            `  every step went as it expects (${results->Array.length->Int.toString} steps)`,
          )
        }
      | None => throw(Failed("the file's mutations were not checked before the run"))
      }
    },
  }
}
