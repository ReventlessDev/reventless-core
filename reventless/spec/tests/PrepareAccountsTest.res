open JestGlobals

// Finding the manifest, and the one rule that keeps a typo from provisioning the
// wrong cast. `locate` is the only part of preparation that touches a path it was
// not handed, so it is the part worth pinning.
//
// The generating itself is covered by `AccountsManifestTest` (the write-back
// rules) and `Util_PasswordTest` (the policy the passwords satisfy).

let scratch = (): string => NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "manifest-"]))

let template = `- username: admin
  password: ""
  groups: [Admin]
`

describe("AccountsManifest.locate", () => {
  // A file left under its old name is no longer read, but refused naming both names, so the
  // app learns why rather than starting with no accounts. Beside a new one it is ignored.
  testSync(
    "a file left under its old name is refused, naming both; beside a new one it is ignored",
    () => {
      let old = scratch()
      NodeFs.writeFileSync(NodePath.join([old, AccountsManifest.oldTemplateName]), template)
      NodeFs.mkdirSync(NodePath.join([old, ".reventless"]), {recursive: true})
      NodeFs.writeFileSync(
        NodePath.join([old, ".reventless", AccountsManifest.oldFileName]),
        template,
      )
      let both = scratch()
      NodeFs.mkdirSync(NodePath.join([both, ".reventless"]), {recursive: true})
      NodeFs.writeFileSync(
        NodePath.join([both, ".reventless", AccountsManifest.fileName]),
        template,
      )
      NodeFs.writeFileSync(
        NodePath.join([both, ".reventless", AccountsManifest.oldFileName]),
        template,
      )
      let cwd = NodeProcess.cwd()
      let at = (dir, f) => {
        NodeProcess.chdir(dir)
        let r = try {Ok(f())} catch {
        | JsExn(err) => Error(JsExn.message(err)->Option.getOr(""))
        }
        NodeProcess.chdir(cwd)
        r
      }
      let names = (r, ~old, ~current) =>
        switch r {
        | Error(message) => message->String.includes(old) && message->String.includes(current)
        | Ok(_) => false
        }
      expect((
        at(old, () => AccountsManifest.defaultPath())->names(
          ~old=AccountsManifest.oldFileName,
          ~current=AccountsManifest.fileName,
        ),
        at(old, () => AccountsManifest.templateIn(old))->names(
          ~old=AccountsManifest.oldTemplateName,
          ~current=AccountsManifest.templateName,
        ),
        at(both, () => AccountsManifest.defaultPath())->Result.map(
          p => p->String.endsWith(AccountsManifest.fileName),
        ),
      ))->toEqual((true, true, Ok(true)))
    },
  )

  // The ceremony this removes: `.reventless/` is gitignored on every platform, so
  // a fresh clone has no manifest and the first thing anyone met was a `cp`.
  testSync("copies the committed template into place when there is no manifest", () => {
    let dir = scratch()
    NodeFs.writeFileSync(NodePath.join([dir, AccountsManifest.templateName]), template)
    let manifest = NodePath.join([dir, ".reventless", "accounts.yaml"])
    let cwd = NodeProcess.cwd()
    NodeProcess.chdir(dir)
    let located = AccountsManifest.locate()
    NodeProcess.chdir(cwd)
    switch located {
    | Error(message) => fail(message)
    | Ok(SeededFrom(file, from)) =>
      expect(NodeFs.existsSync(manifest))->toBe(true)
      expect(file->String.endsWith("accounts.yaml"))->toBe(true)
      expect(from->String.endsWith(AccountsManifest.templateName))->toBe(true)
    | Ok(Declared(_)) => fail("expected the template to be copied, not an existing manifest")
    }
  })

  testSync("adopts a manifest that is already there rather than copying over it", () => {
    let dir = scratch()
    NodeFs.writeFileSync(NodePath.join([dir, AccountsManifest.templateName]), template)
    NodeFs.mkdirSync(NodePath.join([dir, ".reventless"]), {recursive: true})
    NodeFs.writeFileSync(
      NodePath.join([dir, ".reventless", "accounts.yaml"]),
      "- username: mine\n  password: kept\n  groups: []\n",
    )
    let cwd = NodeProcess.cwd()
    NodeProcess.chdir(dir)
    let located = AccountsManifest.locate()
    NodeProcess.chdir(cwd)
    switch located {
    | Ok(Declared(file)) =>
      expect(
        AccountsManifest.parseFile(file)->Result.map(e => e->Array.map(x => x.username)),
      )->toEqual(Ok(["mine"]))
    | _ => fail("expected the existing manifest to be adopted")
    }
  })

  // 🚨 A named path is a claim that it exists. Copying a template over that claim
  // would answer a mistyped `--file` by provisioning a cast the operator never
  // named — on AWS, into a real pool.
  testSync("never seeds a path that was named explicitly", () => {
    let dir = scratch()
    NodeFs.writeFileSync(NodePath.join([dir, AccountsManifest.templateName]), template)
    let typo = NodePath.join([dir, "users.yml"])
    let cwd = NodeProcess.cwd()
    NodeProcess.chdir(dir)
    let located = AccountsManifest.locate(~given=typo, ())
    NodeProcess.chdir(cwd)
    expect(located->Result.isError)->toBe(true)
    expect(NodeFs.existsSync(typo))->toBe(false)
  })

  // Nothing to adopt and nothing to copy from: the message has to say what to
  // write, because there is no file to point at.
  testSync("says what to declare when there is neither manifest nor template", () => {
    let dir = scratch()
    let cwd = NodeProcess.cwd()
    NodeProcess.chdir(dir)
    let located = AccountsManifest.locate()
    NodeProcess.chdir(cwd)
    switch located {
    | Error(message) => expect(message->String.includes("accounts.yaml"))->toBe(true)
    | Ok(_) => fail("expected an error naming what to declare")
    }
  })
})

describe("PrepareAccounts.parseArgs", () => {
  testSync("no arguments reads the default manifest", () =>
    expect(PrepareAccounts.parseArgs([]))->toEqual(Ok({PrepareAccounts.file: ?None, help: false}))
  )

  testSync("--file names one", () =>
    expect(PrepareAccounts.parseArgs(["--file", "cast.yaml"]))->toEqual(
      Ok({PrepareAccounts.file: "cast.yaml", help: false}),
    )
  )

  testSync("an unknown flag refuses rather than being ignored", () =>
    expect(PrepareAccounts.parseArgs(["--prepare-only"]))->toEqual(
      Error(`unknown argument "--prepare-only"`),
    )
  )
})
