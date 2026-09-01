// Turn a test report into a trait conformance certificate.
//
// Usage: certify-trait <trait-package> --host <componentName> --report <jest.json> --out <file>
//
// The trait's suite has run inside a consumer's build since the emitter shipped.
// What was missing is a result something downstream can read: it was console
// output, so a listing could carry a claim nobody could check.
//
// **The framework does not own the runner.** A consumer runs their suite their
// own way and hands the report here — this reads it, selects the assertions
// belonging to the trait's suite, and writes `Reventless.TraitCertificate`. The
// decision of what "verified" means lives in that module, once, so a registry and
// a build gate cannot disagree about it.
//
// The trait is resolved **by the name it is given** and its conformance module is
// dynamically imported, exactly as `graft-trait` imports the scaffold — so
// `reventless-spec` still depends on no trait.

@val external dynImport: string => promise<'a> = "import"

// ── The dynamic-import boundary ──────────────────────────────────────────────
//
// A trait's conformance module exports its suite title as a function of the host
// name. Read rather than reconstructed: the suite registers that exact string,
// and a CLI that re-derived it from prose would be guessing at the trait's own
// wording and would break the day it was reworded.
type conformanceExports = {suiteName: string => string}

let fail = (message: string) => {
  Console.error("certify-trait: " ++ message)
  NodeProcess.exit(1)
}

let usage = `Usage: certify-trait <trait-package> --host <componentName> --report <jest.json> --out <file>

  <trait-package>  the installed trait, e.g. @reventlessdev/trait-attachments
  --host           the bound component's name, as its Spec declares it
  --report         a Jest JSON report (jest --json --outputFile=…)
  --out            where to write the certificate

  Exits non-zero if the suite is absent from the report, or if it did not pass —
  an absent suite is the failure worth catching, since a build that never ran the
  conformance suite is indistinguishable from one that ran it green.`

// ── The report, at the boundary ──────────────────────────────────────────────
//
// Only the three fields this needs, decoded leniently: a report carries a great
// deal more, and a strict shape here would break on a runner version that added
// a field.
@schema
type reportAssertion = {
  ancestorTitles: array<string>,
  title: string,
  status: string,
}

@schema
type reportSuite = {assertionResults: array<reportAssertion>}

@schema
type report = {testResults: array<reportSuite>}

/** Every assertion registered under this suite title, in report order.

    Matched on the *full* ancestor title rather than a prefix or a substring: two
    hosts of one trait produce two suites whose titles differ only by the host's
    name, and a prefix match would fold one into the other and certify a host
    against another host's run. */
let assertionsFor = (report: report, ~suite: string): array<(string, bool)> =>
  report.testResults->Array.flatMap(s =>
    s.assertionResults->Array.filterMap(a =>
      a.ancestorTitles->Array.includes(suite) ? Some((a.title, a.status == "passed")) : None
    )
  )

let readJson = (path: string) =>
  switch NodeFs.readFileSync(path)->JSON.parseOrThrow {
  | json => json
  | exception _ =>
    fail(`could not read ${path} as JSON.`)
    JSON.Encode.null
  }

// ── Entry point ──────────────────────────────────────────────────────────────

let main = async () => {
  let argv = NodeProcess.argv->Array.slice(~start=2, ~end=NodeProcess.argv->Array.length)
  let flag = key =>
    switch argv->Array.indexOf("--" ++ key) {
    | -1 => None
    | i => argv->Array.get(i + 1)
    }

  switch argv->Array.get(0) {
  | None | Some("") | Some("--help") | Some("-h") => {
      Console.log(usage)
      NodeProcess.exit(argv->Array.length == 0 ? 1 : 0)
    }
  | Some(traitPackage) =>
    switch (flag("host"), flag("report"), flag("out")) {
    | (None, _, _) | (_, None, _) | (_, _, None) =>
      fail("--host, --report and --out are all required.\n\n" ++ usage)
    | (Some(host), Some(reportPath), Some(out)) => {
        // `@scope/trait-attachments` → `Attachments_Conformance`, the same
        // derivation `graft-trait` does for `_Scaffold`.
        let conformanceModule =
          traitPackage
          ->String.split("/")
          ->Array.last
          ->Option.getOr("")
          ->String.replace("trait-", "")
          ->String.split("-")
          ->Array.map(part =>
            part->String.charAt(0)->String.toUpperCase ++
              part->String.slice(~start=1, ~end=part->String.length)
          )
          ->Array.join("") ++ "_Conformance"
        let specifier = `${traitPackage}/src/${conformanceModule}.res.mjs`
        // Resolved from the **caller's** directory: the trait is a dependency of
        // the plugin being certified and deliberately not one of this package.
        let modulePath = try NodeModule.createRequire(
          NodeProcess.cwd() ++ "/index.js",
        )->NodeModule.requireResolve(specifier) catch {
        | _ => specifier
        }
        let conformance: conformanceExports = try await dynImport(
          NodeUrl.pathToFileURL(modulePath)["href"],
        ) catch {
        | _ =>
          fail(
            `${traitPackage} ships no conformance suite (looked for ${specifier}).\n` ++
            `  A trait without one cannot be certified — there is nothing to prove.`,
          )
          %raw(`undefined`)
        }

        let suite = conformance.suiteName(host)
        let parsed = switch readJson(reportPath)->Util_Sury.fromJson(reportSchema) {
        | value => value
        | exception _ =>
          fail(`${reportPath} is not a Jest JSON report (expected \`testResults\`).`)
          %raw(`undefined`)
        }

        switch parsed->assertionsFor(~suite) {
        // The failure worth catching. A green build that never ran the suite
        // looks exactly like one that ran it and passed, so silence is refused
        // rather than certified as zero-of-zero.
        | [] =>
          fail(
            `the report contains no suite titled "${suite}".\n` ++
            `  Either the conformance binding was never registered, or ${host} is not the ` ++
            `name its Spec declares.`,
          )
        | results => {
            let resolveVersion = specifier =>
              try {
                let entry =
                  NodeModule.createRequire(
                    NodeProcess.cwd() ++ "/index.js",
                  )->NodeModule.requireResolve(specifier)
                PackageVersion.fromModuleUrl(NodeUrl.pathToFileURL(entry)["href"])
              } catch {
              | _ => "0.0.0"
              }

            let certificate = TraitCertificate.fromReport(
              ~trait=traitPackage,
              ~traitVersion=resolveVersion(specifier),
              // The framework the suite ran against, read the same way — a trait
              // is certified against a version, never in the abstract.
              ~framework=resolveVersion("@reventlessdev/reventless-spec/package.json"),
              ~host,
              ~suite,
              ~results,
            )
            NodeFs.writeFileSync(out, certificate->TraitCertificate.render)
            Console.log(`certify-trait: ${certificate->TraitCertificate.summarize}`)
            Console.log(`Wrote: ${out}`)
            if !(certificate->TraitCertificate.verified) {
              NodeProcess.exit(1)
            }
          }
        }
      }
    }
  }
}

main()->Promise.ignore
