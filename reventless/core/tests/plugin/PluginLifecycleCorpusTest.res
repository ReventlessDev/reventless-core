// Frozen-payload compatibility corpus for the Plugin lifecycle aggregate.
//
// The Plugin aggregate replays its own event log before every decision, so ONE
// undecodable stored event freezes Heartbeat / Redetect / Connect for that plugin
// permanently — and it does so silently, surfacing only as a registration that
// stops tracking deploys. See docs/analysis/plugin-definition-schema-evolution-wedge.md.
//
// The two hand-constructed cases in MessageTest build a `pluginDefinition` from the
// CURRENT ReScript type and then strip keys. That literal recompiles with every
// schema change, so it can only test the fields whoever wrote it thought to strip —
// which is why it did not catch `annotation: string`. These fixtures are frozen JSON
// captured off a deployed log and are never regenerated; see the corpus README.
//
// What turns this suite red is a change no amount of healing can absorb: a field
// whose TYPE changed under stored data (`float` → an object, say), a `bigint`, or a
// genuinely corrupt payload. It names the fixture and the sury field path. The fix is
// to make the change decodable — never to re-cut the fixtures.
//
// A newly added required *scalar* does NOT land here: `fillMissingDefaults` invents a
// value for it, so these still decode. That case is caught by the sibling
// PluginDefinitionRequiredScalarsTest, at the declaration site.

open JestGlobals

let entries = PluginLifecycleCorpus.entries

// Mirrors EventLog_Operations.decodeEvent: reassemble the stored `{event, data}`
// pair into a variant and decode it — the exact call replay makes.
let decodeStored = (entry: PluginLifecycleCorpus.entry) =>
  Message.combineMessage(entry.event, entry.data)->Message.decode(PluginSpec.eventSchema)

describe("The stored plugin-lifecycle payload corpus", () => {
  testSync("is not empty (a corpus that loaded nothing would pass vacuously)", () =>
    expect(entries->Array.length > 0)->toBe(true)
  )

  entries->Array.forEach(entry =>
    testSync(`still decodes: ${entry.name}`, () => {
      // Sury's own error carries the field path, which is the whole value of
      // this suite's failure message — report it verbatim rather than "it threw".
      // sury 11 throws a plain JS `SuryError` with no ReScript exception
      // constructor to match on, so the message comes off the JS exception.
      let outcome = switch decodeStored(entry) {
      | _ => "decodes"
      | exception JsExn(e) => JsExn.message(e)->Option.getOr("threw: no message")
      | exception _ => "threw a non-JS exception"
      }
      expect(outcome)->toBe("decodes")
    })
  )
})
