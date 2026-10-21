open JestGlobals

// `ScenarioRecorder` writes what a decision test runs as a sidecar `check-lifecycle` reads, for
// a suite whose source names nothing (one written against a binding). Each case records into a
// file of its own under the OS temp folder, named by `setFile` as an external runner would.

let dir = NodeFs.mkdtempSync(NodePath.join([NodeOs.tmpdir(), "scenario-recorder-"]))
let testFile = name => NodePath.join([dir, `${name}_GWT.res.mjs`])
let sidecarOf = name => NodePath.join([dir, `${name}_GWT.gwt.json`])

let read = path => NodeFs.readFileSync(path)->JSON.parseOrThrow

let field = (json: JSON.t, key) =>
  switch json {
  | Object(d) => d->Dict.get(key)
  | _ => None
  }

// One recorded test: the history, the command, and the event it expects.
let run = (~spec, ~title, ~expects) =>
  ScenarioRecorder.around(~spec, title, () => {
    ScenarioRecorder.given(["CustomerRegistered"])
    ScenarioRecorder.whenCommand("RequestNotification")
    ScenarioRecorder.thenEvents([expects])
  })

let switched = (on, f) => {
  NodeProcess.env->Dict.set("REVENTLESS_EMIT_SIDECAR", on ? "1" : "0")
  let out = f()
  NodeProcess.env->Dict.delete("REVENTLESS_EMIT_SIDECAR")
  out
}

describe("ScenarioRecorder", () => {
  testSync("with the switch off it writes nothing", () => {
    ScenarioRecorder.setFile(testFile("Off"))
    switched(false, () => run(~spec="Prefs", ~title="t", ~expects="NotificationRequested"))
    expect(NodeFs.existsSync(sidecarOf("Off")))->toBe(false)
  })

  testSync("a test run with the switch on is a sidecar naming its spec as the component", () => {
    ScenarioRecorder.setFile(testFile("Conformance"))
    switched(
      true,
      () => {
        run(~spec="Prefs", ~title="undeliverable", ~expects="NotificationUndeliverable")
        run(~spec="Prefs", ~title="deferred", ~expects="NotificationDeferred")
      },
    )
    let json = read(sidecarOf("Conformance"))
    let scenarios = switch json->field("scenarios") {
    | Some(Array(xs)) => xs
    | _ => []
    }
    expect((
      json->field("stem"),
      json->field("recorded"),
      scenarios->Array.map(
        s =>
          switch (s->field("when"), s->field("then")) {
          | (Some(Array([w])), Some(Array([t]))) => (w->field("element"), t->field("element"))
          | _ => (None, None)
          },
      ),
    ))->toEqual((
      Some(JSON.String("Prefs")),
      Some(JSON.Boolean(true)),
      [
        (Some(JSON.String("RequestNotification")), Some(JSON.String("NotificationUndeliverable"))),
        (Some(JSON.String("RequestNotification")), Some(JSON.String("NotificationDeferred"))),
      ],
    ))
  })

  testSync("a sidecar the PPX wrote is left as it is", () => {
    let ppx = `{"stem":"Mine_GWT","scenarios":[]}`
    NodeFs.writeFileSync(sidecarOf("Mine"), ppx)
    ScenarioRecorder.setFile(testFile("Mine"))
    switched(true, () => run(~spec="Prefs", ~title="t", ~expects="NotificationRequested"))
    expect(NodeFs.readFileSync(sidecarOf("Mine")))->toBe(ppx)
  })

  testSync("a second spec in one file gets a sidecar of its own", () => {
    ScenarioRecorder.setFile(testFile("Two"))
    switched(
      true,
      () => {
        run(~spec="Prefs", ~title="a", ~expects="NotificationRequested")
        run(~spec="Claims", ~title="b", ~expects="NotificationSourceClaimed")
      },
    )
    expect((
      read(sidecarOf("Two"))->field("stem"),
      read(NodePath.join([dir, "Two_GWT.Claims.gwt.json"]))->field("stem"),
    ))->toEqual((Some(JSON.String("Prefs")), Some(JSON.String("Claims"))))
  })

  testSync("steps outside a recorded test record nothing", () =>
    expect(ScenarioRecorder.recording())->toBe(false)
  )
})
