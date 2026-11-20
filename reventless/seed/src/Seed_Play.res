// A data set read from a file, for a caller who writes no ReScript: mutations by
// name with their arguments, encoded by `Seed_Commands` from what the API says.
//
//   pace: 30/min~          # optional; SEED_PACE overrides
//   repeatable: true       # optional; then SEED_REPEAT may play it again
//   steps:
//     - send: Catalog_AddCategory
//       args: {categoryId: "cat-{run}-{rep}", name: "Toys {rep}"}
//     - waitFor: {field: Catalog_CategoriesByIds, ids: ["cat-{run}-{rep}"]}
//
// `{rep}` is the repetition's number in this run, `{run}` names the run
// (`SEED_RUN_TAG`, else the start time), so ids differ between runs and repeat
// within one when the tag is given.

open Seed_Types

type step =
  | Send(string, JSON.t)
  | WaitFor(string, array<string>)

type file = {pace?: string, repeatable: bool, steps: array<step>}

let stepOf = (json: JSON.t, ~index: int): result<step, string> => {
  let at = `step ${(index + 1)->Int.toString}`
  switch (
    json->Seed_Commands.str("send"),
    json->Seed_Commands.get("args"),
    json->Seed_Commands.get("waitFor"),
  ) {
  | (Some(field), Some(Object(_) as args), None) => Ok(Send(field, args))
  | (Some(field), None, None) => Ok(Send(field, JSON.Encode.object(Dict.make())))
  | (None, None, Some(wait)) =>
    switch (wait->Seed_Commands.str("field"), wait->Seed_Commands.items("ids")) {
    | (Some(field), ids) if ids->Array.length > 0 =>
      Ok(
        WaitFor(
          field,
          ids->Array.filterMap(id =>
            switch id {
            | String(s) => Some(s)
            | _ => None
            }
          ),
        ),
      )
    | _ => Error(`${at}: waitFor needs a field and a list of ids`)
    }
  | _ => Error(`${at}: expected {send, args} or {waitFor: {field, ids}}`)
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

/** Sends one repetition of `file`'s steps. */
let playOnce = async (file: file, ~commands: Seed_Commands.t, ~client, ~vars) =>
  for i in 0 to file.steps->Array.length - 1 {
    switch file.steps[i] {
    | Some(Send(field, args)) =>
      (
        await client->Seed_Client.send(
          commands->Seed_Commands.encodeOrThrow(~field, fill(args, ~vars)),
        )
      )->ignore
    | Some(WaitFor(field, ids)) =>
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
      let read = await Seed_Commands.fetch(connection.client)
      file.steps->Array.forEach(step =>
        switch step {
        | Send(field, args) =>
          switch read->Seed_Commands.encode(
            ~field,
            fill(args, ~vars=[("run", run), ("rep", "1")]),
          ) {
          | Error(message) => throw(Failed(`${path}: ${message}`))
          | Ok(_) => ()
          }
        | WaitFor(_) => ()
        }
      )
      commands := Some(read)
    },
    seed: async connection => {
      repetition := repetition.contents + 1
      let rep = repetition.contents->Int.toString
      Console.log(`  run ${run}, repetition ${rep}`)
      switch commands.contents {
      | Some(commands) =>
        await playOnce(
          file,
          ~commands,
          ~client=connection.client,
          ~vars=[("run", run), ("rep", rep)],
        )
      | None => throw(Failed("the file's mutations were not checked before the run"))
      }
    },
  }
}
