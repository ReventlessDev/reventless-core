/***
Bake the component manifest — the file that tells the web app which pages to
show — once every plugin stack of a deployment is up.

```
pnpm exec bake-manifest --stack alpha
```

The manifest describes the whole deployment, so no single stack's deploy is the
moment it is settled. Without it every user but an administrator sees an empty
web app: the discovery query the file stands in for is Admin-gated.

Registration is asynchronous — a plugin stack publishes a re-detect, the plugin
answers, the Plugin read model projects — so the bake function refuses to write
until each plugin's row holds the structure its stack exported, and this command
asks again while one is still on its way.

A deployment that declares no bake exports no `bakedManifestFunction`, and the
command does nothing.
*/

module Lambda = AwsSdk.Lambda

// ── Arguments ────────────────────────────────────────────────────────────────

type args = {
  manifest: option<string>,
  stack: option<string>,
  since: option<string>,
  help: bool,
}

let parseArgs = (argv: array<string>): result<args, string> => {
  let acc = ref(Ok({manifest: None, stack: None, since: None, help: false}))
  let i = ref(0)
  let count = argv->Array.length
  while i.contents < count {
    let flag = argv->Array.getUnsafe(i.contents)
    let value = argv->Array.get(i.contents + 1)
    switch (acc.contents, flag, value) {
    | (Error(_), _, _) => i := count
    | (Ok(a), "--manifest", Some(v)) =>
      acc := Ok({...a, manifest: Some(v)})
      i := i.contents + 2
    | (Ok(a), "--stack", Some(v)) =>
      acc := Ok({...a, stack: Some(v)})
      i := i.contents + 2
    | (Ok(a), "--since", Some(v)) =>
      acc := Ok({...a, since: v == "" ? None : Some(v)})
      i := i.contents + 2
    | (Ok(a), "--help", _) | (Ok(a), "-h", _) =>
      acc := Ok({...a, help: true})
      i := i.contents + 1
    | (Ok(_), "--manifest", None) | (Ok(_), "--stack", None) | (Ok(_), "--since", None) =>
      acc := Error(`${flag} needs a value`)
    | (Ok(_), unknown, _) => acc := Error(`unknown argument "${unknown}"`)
    }
  }
  acc.contents
}

let usage = `
Bake the component manifest of a deployed platform.

  --manifest <path>   The deploy manifest. Defaults to ${DeployManifest.defaultFile}
                      in the working directory.
  --stack <name>      The stack to bake. Defaults to the stack selected in the
                      platform's folder.
  --since <instant>   When this deploy started (ISO 8601). Lets the report tell a
                      plugin that re-registered from one that was unchanged.

Reads the bake function from the platform stack and each plugin's structure key
from its stack, then asks the function to bake — again every
15 seconds, up to 20 times, while a plugin's registration has
not arrived. A registration this deploy wrote with another key cannot arrive by
waiting, so that stops the run at once.
`

// ── What the stacks say ──────────────────────────────────────────────────────

type target = {functionName: string, bucket: string, key: string}

/** `None` when the platform declares no bake. */
let targetOf = (outputs: dict<JSON.t>): option<target> =>
  switch (
    outputs->PulumiCli.stringOutput("bakedManifestFunction"),
    outputs->PulumiCli.stringOutput("bakedManifestBucket"),
  ) {
  | (Some(functionName), Some(bucket)) =>
    Some({
      functionName,
      bucket,
      key: outputs->PulumiCli.stringOutput("bakedManifestKey")->Option.getOr(""),
    })
  | _ => None
  }

/** The plugin name and structure key a plugin stack exported. A stack deployed
    before this output existed exports nothing and is not waited for. */
let structureRefOf = (outputs: dict<JSON.t>): option<(string, string)> =>
  switch outputs->Dict.get("pluginStructureRef")->Option.flatMap(JSON.Decode.object) {
  | Some(ref) =>
    switch (
      ref->Dict.get("plugin")->Option.flatMap(JSON.Decode.string),
      ref->Dict.get("key")->Option.flatMap(JSON.Decode.string),
    ) {
    | (Some(plugin), Some(key)) => Some((plugin, key))
    | _ => None
    }
  | None => None
  }

/** The key names the default file; a deployment that curates a surface per
    audience writes one file per journey beside it, under keys the function
    already knows. */
let payload = (~target: target, ~expect: dict<string>, ~since: option<string>): JSON.t => {
  let fields = [
    ("bake", JSON.Encode.bool(true)),
    ("bucket", JSON.Encode.string(target.bucket)),
    ("key", JSON.Encode.string(target.key)),
    ("expect", expect->Dict.mapValues(JSON.Encode.string)->JSON.Encode.object),
  ]
  since->Option.forEach(s => fields->Array.push(("since", JSON.Encode.string(s))))
  fields->Dict.fromArray->JSON.Encode.object
}

// ── What the bake function answers ───────────────────────────────────────────

type registration = {
  plugin: string,
  state: string,
  expected: string,
  found: option<string>,
  writtenAt: option<string>,
}

type summary = {plugins: int, registered: int, unchanged: int, matched: int}

type written = {bucket: string, key: string, bytes: int, group: option<string>}

type answer =
  | Baked({written: array<written>, summary: option<summary>, registrations: array<registration>})
  | Pending({pending: array<string>, registrations: array<registration>})

let _string = (o, name) => o->Dict.get(name)->Option.flatMap(JSON.Decode.string)
let _int = (o, name) =>
  o->Dict.get(name)->Option.flatMap(JSON.Decode.float)->Option.mapOr(0, Float.toInt)

let _registrations = (o: dict<JSON.t>): array<registration> =>
  o
  ->Dict.get("registrations")
  ->Option.flatMap(JSON.Decode.array)
  ->Option.getOr([])
  ->Array.filterMap(JSON.Decode.object)
  ->Array.map(r => {
    plugin: r->_string("plugin")->Option.getOr("?"),
    state: r->_string("state")->Option.getOr("?"),
    expected: r->_string("expected")->Option.getOr("?"),
    found: r->_string("found"),
    writtenAt: r->_string("writtenAt"),
  })

let readAnswer = (json: JSON.t): result<answer, string> => {
  let entries = json->JSON.Decode.array->Option.getOr([])->Array.filterMap(JSON.Decode.object)
  switch entries->Array.get(0) {
  | None => Error(`the bake function answered ${JSON.stringify(json)}`)
  | Some(first) if first->Dict.get("baked") == Some(JSON.Boolean(false)) =>
    Ok(
      Pending({
        pending: first
        ->Dict.get("pending")
        ->Option.flatMap(JSON.Decode.array)
        ->Option.getOr([])
        ->Array.filterMap(JSON.Decode.string),
        registrations: _registrations(first),
      }),
    )
  | Some(_) =>
    let summaryEntry = entries->Array.find(e => e->Dict.get("summary") == Some(JSON.Boolean(true)))
    Ok(
      Baked({
        written: entries
        ->Array.filter(e => e->Dict.get("baked") == Some(JSON.Boolean(true)))
        ->Array.map(e => {
          bucket: e->_string("bucket")->Option.getOr("?"),
          key: e->_string("key")->Option.getOr("?"),
          bytes: e->_int("bytes"),
          group: e->_string("group"),
        }),
        summary: summaryEntry->Option.map(s => {
          plugins: s->_int("plugins"),
          registered: s->_int("registered"),
          unchanged: s->_int("unchanged"),
          matched: s->_int("matched"),
        }),
        registrations: summaryEntry->Option.mapOr([], _registrations),
      }),
    )
  }
}

/** Both halves of a plugin's comparison and the row's date — what separates the
    causes on sight. */
let registrationLine = (r: registration): string =>
  `  ${r.plugin}: ${r.state} — expected ${r.expected}, row holds ${r.found->Option.getOr(
      "no row",
    )} (written ${r.writtenAt->Option.getOr("never")})`

/** A registration this deploy already wrote with another key. Waiting does not
    change it. `missing` is waited for: on a first deploy no plugin has a row
    until its registration lands. */
let unreachable = (registrations: array<registration>): array<registration> =>
  registrations->Array.filter(r => r.state == "diverged")

// ── Asking until it is settled ───────────────────────────────────────────────

type settled = {
  written: array<written>,
  summary: option<summary>,
  registrations: array<registration>,
}

/** Asks `invoke` until it bakes, a registration becomes unreachable, or the
    attempts run out. Every attempt's registrations are printed through `log`. */
let converge = async (
  ~invoke: unit => promise<result<JSON.t, string>>,
  ~sleep: unit => promise<unit>,
  ~log: string => unit,
  ~attempts: int,
): result<settled, string> => {
  let rec attempt = async n =>
    switch await invoke() {
    | Error(_) as e => e
    | Ok(json) =>
      switch readAnswer(json) {
      | Error(_) as e => e
      | Ok(Baked({written, summary, registrations})) => Ok({written, summary, registrations})
      | Ok(Pending({pending, registrations})) =>
        registrations->Array.forEach(r => log(registrationLine(r)))
        switch unreachable(registrations) {
        | [] if n < attempts =>
          log(
            `Attempt ${n->Int.toString}: registration has not caught up yet — ${pending->Array.join(
                ", ",
              )}`,
          )
          await sleep()
          await attempt(n + 1)
        | [] =>
          Error(
            `registration never caught up with this deploy (${pending->Array.join(
                ", ",
              )}); the manifest would describe the previous one, so nothing was written`,
          )
        | diverged =>
          Error(
            `${diverged
              ->Array.map(r => r.plugin)
              ->Array.join(
                ", ",
              )} registered during this deploy with a different structure than its stack exported; waiting will not change that, so nothing was written`,
          )
        }
      }
    }
  await attempt(1)
}

// ── Main ─────────────────────────────────────────────────────────────────────

let attempts = 20
let intervalMs = 15_000

let inGitHubActions = () => NodeProcess.env->Dict.get("GITHUB_ACTIONS") == Some("true")

let invokeWith = (client: Lambda.client, ~functionName: string, ~payload: JSON.t) =>
  async () =>
    switch await Lambda.InvokeCommand.make({
      functionName,
      payload: payload->JSON.stringify->NodeBuffer.fromStringUtf8,
    })->Lambda.InvokeCommand.send(client, _) {
    | output =>
      let text =
        output.payload->Option.mapOr("", bytes =>
          bytes->NodeBuffer.fromBytes->NodeBuffer.toStringUtf8
        )
      switch output.functionError {
      | Some(_) => Error(`baking the component manifest failed: ${text}`)
      | None =>
        switch JSON.parseOrThrow(text) {
        | json => Ok(json)
        | exception _ => Error(`the bake function answered something that is not JSON: ${text}`)
        }
      }
    | exception exn => Error(`could not invoke ${functionName}: ${Util_AwsError.describe(exn)}`)
    }

let bake = async (~manifest: DeployManifest.resolved, ~stack: string, ~since: option<string>) =>
  switch PulumiCli.stackOutputs(~dir=manifest.platformDir, ~stack) {
  | Error(_) as e => e
  | Ok(outputs) =>
    switch targetOf(outputs) {
    | None =>
      Console.log("This platform declares no baked manifest — nothing to bake.")
      Ok()
    | Some(target) =>
      let refs = []
      manifest.plugins->Array.forEach(p =>
        if PulumiCli.hasStackFile(~dir=p.dir, ~stack) {
          switch PulumiCli.stackOutputs(~dir=p.dir, ~stack) {
          | Ok(o) => o->structureRefOf->Option.forEach(r => refs->Array.push(r))
          | Error(message) => Console.error(`${p.name}: ${message} — not waited for`)
          }
        }
      )
      let expect = refs->Dict.fromArray
      Console.log(
        `Expecting: ${expect
          ->Dict.mapValues(JSON.Encode.string)
          ->JSON.Encode.object
          ->JSON.stringify}`,
      )
      Console.log(`Baking ${target.bucket}/${target.key} via ${target.functionName}`)
      let client = Lambda.client(~region=?manifest.region, ())
      switch await converge(
        ~invoke=invokeWith(
          client,
          ~functionName=target.functionName,
          ~payload=payload(~target, ~expect, ~since),
        ),
        ~sleep=() =>
          Promise.make((resolve, _) => {
            let _ = setTimeout(() => resolve(), intervalMs)
          }),
        ~log=Console.log,
        ~attempts,
      ) {
      | Error(_) as e => e
      | Ok({written, summary, registrations}) =>
        written->Array.forEach(w =>
          Console.log(
            `Wrote ${w.bucket}/${w.key} (${w.bytes->Int.toString} bytes${w.group->Option.mapOr(
                "",
                g => `, for ${g}`,
              )})`,
          )
        )
        registrations->Array.forEach(r => Console.log(registrationLine(r)))
        summary->Option.forEach(s => {
          Console.log(
            `${s.registered->Int.toString}/${s.plugins->Int.toString} plugin(s) re-registered during this deploy (${s.unchanged->Int.toString} unchanged, ${s.matched->Int.toString} undated).`,
          )

          // A bake where nothing re-registered proved the manifest current and
          // nothing about the chain that keeps it current.
          if s.registered == 0 {
            let note = "The manifest is current, but no plugin exercised the registration chain on this deploy — it is unverified, not proven working."
            Console.log(inGitHubActions() ? `::notice::${note}` : `note: ${note}`)
          }
        })
        Ok()
      }
    }
  }

let run = async (): result<unit, string> =>
  switch parseArgs(NodeProcess.argv->Array.slice(~start=2, ~end=NodeProcess.argv->Array.length)) {
  | Error(_) as e => e
  | Ok(args) if args.help =>
    Console.log(usage)
    Ok()
  | Ok(args) =>
    switch DeployManifest.load(args.manifest->Option.getOr(DeployManifest.defaultFile)) {
    | Error(_) as e => e
    | Ok(manifest) =>
      switch args.stack->Option.orElse(PulumiCli.selectedStack(~dir=manifest.platformDir)) {
      | None => Error(`no stack selected in ${manifest.platformDir} — pass --stack`)
      | Some(stack) => await bake(~manifest, ~stack, ~since=args.since)
      }
    }
  }

let main = async () =>
  switch await run() {
  | Ok() => ()
  | Error(message) =>
    Console.error(inGitHubActions() ? `::error::${message}` : `bake-manifest: ${message}`)
    NodeProcess.exit(1)
  | exception exn =>
    Console.error(`bake-manifest: ${Util_AwsError.describe(exn)}`)
    NodeProcess.exit(1)
  }

// No top-level call: `../run-bake-manifest.mjs` invokes [main], so a test can
// import this module.
