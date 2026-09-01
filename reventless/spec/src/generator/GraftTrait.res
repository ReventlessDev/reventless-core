// Graft a domain trait into a plugin: write the spec surface it can own, print
// the arms it cannot.
//
// Usage: graft-trait <trait-package> --into <srcDir> --tests <testsDir> [--key value …]
//
// The trait is resolved **by the name it is given** and its scaffold module is
// dynamically imported. That is what keeps this file honest: `reventless-spec`
// ships the CLI and never depends on a trait, so the rule that framework
// packages never import one survives a generator that runs their code.
//
// Every remaining `--key value` becomes a config field, handed to the trait's
// own sury-validated schema. A misspelled key is a decode error naming the key,
// here, rather than a placeholder that survives into a file and fails at
// compile — which is the whole difference between this and a text template.

@val external dynImport: string => promise<'a> = "import"

// ── The dynamic-import boundary ──────────────────────────────────────────────
//
// Typed at the boundary: a trait's scaffold module exports exactly these two,
// and everything downstream is ordinary typed ReScript. Same shape as
// `EmitCapabilities`, which reaches a composition root the same way.

type file = {path: string, contents: string}
type patch = {into: string, at: string, contents: string}
type output = {files: array<file>, patches: array<patch>}
type scaffoldExports = {
  configSchema: S.t<unknown>,
  emit: (~config: unknown, ~into: string, ~tests: string) => output,
}

let fail = (message: string) => {
  Console.error("graft-trait: " ++ message)
  NodeProcess.exit(1)
}

let usage = `Usage: graft-trait <trait-package> --into <srcDir> --tests <testsDir> [--key value …]

  <trait-package>  the installed trait, e.g. @reventlessdev/trait-attachments
  --into           where the graft's own components are written
  --tests          where its conformance binding is written
  --dry-run        print what would be written, write nothing

  Every other --key value is a field of the trait's config. The trait validates
  them, so run it once to be told what it wants.`

// ── Arguments ────────────────────────────────────────────────────────────────

/** `--key value` pairs, in order, with the leading positional taken off first.
    A flag with no value (`--dry-run`) reads as `true`, so the config schema can
    take it as a boolean without the CLI knowing which keys are flags. */
let parseFlags = (args: array<string>): dict<JSON.t> => {
  let out = Dict.make()
  let rec go = i =>
    switch args->Array.get(i) {
    | None => ()
    | Some(arg) if arg->String.startsWith("--") =>
      let key = arg->String.sliceToEnd(~start=2)
      switch args->Array.get(i + 1) {
      | Some(value) if !(value->String.startsWith("--")) =>
        out->Dict.set(key, JSON.Encode.string(value))
        go(i + 2)
      | _ =>
        out->Dict.set(key, JSON.Encode.bool(true))
        go(i + 1)
      }
    | Some(_) => go(i + 1)
    }
  go(0)
  out
}

/** A comma-separated value becomes an array. Applied only to keys the trait's
    schema declares as arrays, so a name that happens to contain a comma is not
    split behind the author's back. */
let splitList = (value: string): JSON.t =>
  value
  ->String.split(",")
  ->Array.map(part => part->String.trim)
  ->Array.filter(part => part != "")
  ->Array.map(JSON.Encode.string)
  ->JSON.Encode.array

let arrayFieldNames = (schema: S.t<unknown>): array<string> =>
  switch schema {
  | Object({properties}) =>
    properties
    ->Dict.toArray
    ->Array.filterMap(((name, field)) =>
      switch field {
      | Array(_) => Some(name)
      | AnyOf({anyOf}) =>
        anyOf->Array.some(m =>
          switch m {
          | Array(_) => true
          | _ => false
          }
        )
          ? Some(name)
          : None
      | _ => None
      }
    )
  | _ => []
  }

// ── Entry point ──────────────────────────────────────────────────────────────

let main = async () => {
  let argv = NodeProcess.argv->Array.sliceToEnd(~start=2)
  switch argv->Array.get(0) {
  | None | Some("") | Some("--help") | Some("-h") => {
      Console.log(usage)
      NodeProcess.exit(argv->Array.length == 0 ? 1 : 0)
    }
  | Some(traitPackage) => {
      let flags = parseFlags(argv->Array.sliceToEnd(~start=1))
      let stringFlag = key => flags->Dict.get(key)->Option.flatMap(JSON.Decode.string)
      let into = stringFlag("into")
      let tests = stringFlag("tests")
      let dryRun = flags->Dict.get("dry-run")->Option.isSome

      switch (into, tests) {
      | (None, _) | (_, None) => fail("--into and --tests are both required.\n\n" ++ usage)
      | (Some(into), Some(tests)) => {
          // Resolved by name, from the consumer's own `node_modules`. A trait
          // that ships no scaffold fails here, saying so, rather than half-way
          // through writing files.
          // `@scope/trait-attachments` → `Attachments_Scaffold`;
          // `@scope/trait-address-geocoding` → `AddressGeocoding_Scaffold`.
          let scaffoldModule =
            traitPackage
            ->String.split("/")
            ->Array.last
            ->Option.getOr("")
            ->String.replace("trait-", "")
            ->String.split("-")
            ->Array.map(part =>
              part->String.charAt(0)->String.toUpperCase ++ part->String.sliceToEnd(~start=1)
            )
            ->Array.join("") ++ "_Scaffold"
          let specifier = `${traitPackage}/src/${scaffoldModule}.res.mjs`
          // Resolved from the **caller's** directory, not this file's. The trait
          // is a dependency of the plugin being grafted, and deliberately not one
          // of this package — a bare `import()` here would look in
          // `reventless-spec`'s own tree and never find it. Same reason
          // `HostShellDist` reaches for the host shell this way.
          let modulePath = try NodeModule.createRequire(
            NodeProcess.cwd() ++ "/index.js",
          )->NodeModule.requireResolve(specifier) catch {
          | _ => specifier
          }
          let scaffold: scaffoldExports = try await dynImport(
            NodeUrl.pathToFileURL(modulePath)["href"],
          ) catch {
          | _ =>
            fail(
              `${traitPackage} ships no scaffold (looked for ${specifier}).\n` ++
              `  Not every trait has one — a trait whose graft is all patches has nothing to write.\n` ++
              `  Write the graft by hand instead; its README says what the host must declare.`,
            )
            %raw(`undefined`)
          }

          // The trait validates its own config, so the CLI never learns a
          // trait's vocabulary — and a misspelled key is named here.
          let listFields = arrayFieldNames(scaffold.configSchema)
          let raw = Dict.make()
          flags
          ->Dict.toArray
          ->Array.forEach(((key, value)) =>
            switch (listFields->Array.includes(key), value->JSON.Decode.string) {
            | (true, Some(text)) => raw->Dict.set(key, splitList(text))
            | _ => raw->Dict.set(key, value)
            }
          )
          ["into", "tests", "dry-run"]->Array.forEach(k => raw->Dict.delete(k))

          let config = try raw->JSON.Encode.object->Util_Sury.fromJson(scaffold.configSchema) catch {
          | exn => {
              fail(
                `${traitPackage} refused this config: ${Util_Sury.exnMessage(exn)}\n` ++
                `  Every --key is a field of the trait's own config; it decides what it needs.`,
              )
              %raw(`undefined`)
            }
          }

          let {files, patches} = scaffold.emit(~config, ~into, ~tests)

          files->Array.forEach(({path, contents}) =>
            if dryRun {
              Console.log(`Would write: ${path} (${contents->String.split("\n")->Array.length->Int.toString} lines)`)
            } else if NodeFs.existsSync(path) {
              // Never overwrite. From the moment a graft lands it is the host's
              // source, edited with the policy the trait deliberately does not
              // write — silently replacing it would delete exactly the part no
              // generator can reproduce.
              Console.log(`Skipped (exists): ${path}`)
            } else {
              NodeFs.mkdirSync(NodePath.dirname(path), {recursive: true})
              NodeFs.writeFileSync(path, contents)
              Console.log(`Wrote: ${path}`)
            }
          )

          if patches->Array.length > 0 {
            Console.log("")
            Console.log("── Paste these; they go into files you already own ──────────────")
            patches->Array.forEach(({into, at, contents}) => {
              Console.log("")
              Console.log(`# ${into} — ${at}`)
              Console.log(contents)
            })
            Console.log("")
            Console.log(
              "Printed rather than written: placing an arm in an existing ordered `switch`\n" ++
              "is an AST operation, and a text splice into the wrong arm is a bug the\n" ++
              "compiler cannot see.",
            )
          }

          NodeProcess.exit(0)
        }
      }
    }
  }
}

await main()
