// Harness for StateChangeDescriptorParityTest.
//
// The live-update change descriptor has three independent implementations and no
// shared code (the DynamoDB relay's module is deliberately Pulumi-free, so it
// cannot import a core builder without risking deploy-time code in its Lambda
// graph). This harness drives all three through the same logical changes and
// hands the results back for comparison.
//
// Plain ESM rather than ReScript because two of the three modules live outside
// this package and one is hand-written JS; the assertions stay in the .res test.

const LOCAL = "../../local/src/adapter/LocalStateChangeDescriptor.res.mjs";
const RELAY = "../src/adapter/StateTopic/StateTopic_AppSync_Ops.res.mjs";
const POSTGRES = "../src/adapter/Runtime/StateTopicPublish.mjs";

// Each case is one logical change expressed three ways. `changeKind` is already
// normalised: the three sites derive it differently (local compares against the
// stored row, the relay maps the stream eventName, Postgres has only upserts), and
// that derivation is covered by their own tests — what is asserted here is that
// the same logical change produces the same descriptor.
const CASES = [
  {
    name: "single-key save with updatedAt",
    changeKind: "Updated",
    entityKey: "p1",
    state: { id: "p1", name: "Widget", updatedAt: "2026-05-19T12:00:00Z" },
  },
  {
    name: "composite-key save falling back to createdAt",
    changeKind: "Updated",
    entityKey: "o1-L2",
    state: { id: "o1", lineId: "L2", createdAt: "2026-03-04T08:00:00Z" },
  },
  {
    name: "save with no sort timestamp",
    changeKind: "Updated",
    entityKey: "p1",
    state: { id: "p1", name: "Widget" },
  },
  {
    name: "first save of a key",
    changeKind: "Added",
    entityKey: "p2",
    state: { id: "p2", name: "Gadget", updatedAt: "2026-05-19T12:00:00Z" },
  },
  {
    name: "oversized row degrades to metadata only",
    changeKind: "Updated",
    entityKey: "p3",
    state: { id: "p3", blob: "x".repeat(70 * 1024), updatedAt: "2026-05-19T12:00:00Z" },
  },
  // Retirement: the row is withdrawn, so every implementation must publish the
  // metadata-only shape — no state, and no sortKeyValue either, even though this
  // row carries an updatedAt that the same row would publish while live.
  {
    name: "retired row degrades to metadata only",
    changeKind: "Updated",
    entityKey: "p4",
    state: { id: "p4", name: "Widget", archived: true, updatedAt: "2026-05-19T12:00:00Z" },
    retiredField: "archived",
  },
  // The control: same field declared, flag false, so nothing changes. Without
  // this, an implementation that dropped the payload unconditionally whenever a
  // retiredField was configured would still pass the case above.
  {
    name: "live row with a retirement flag carries the row",
    changeKind: "Updated",
    entityKey: "p5",
    state: { id: "p5", name: "Widget", archived: false, updatedAt: "2026-05-19T12:00:00Z" },
    retiredField: "archived",
  },
  {
    name: "delete carries no row",
    changeKind: "Removed",
    entityKey: "p1",
    state: undefined,
  },
];

/**
 * Build every case with every implementation.
 *
 * Returns `[{ name, local, relay, postgres }]`, each descriptor a plain object
 * with `seq` replaced by the literal "<seq>" — the three sites take their
 * sequence from different monotonic sources by design (stream SequenceNumber vs
 * a wall-clock counter), so the values differ while the field's presence and
 * type must not.
 */
export async function buildAll() {
  const local = await import(LOCAL);
  const relay = await import(RELAY);
  const postgres = await import(POSTGRES);

  const normalise = (descriptor) => {
    const seq = descriptor.seq;
    if (typeof seq !== "string" || seq.length === 0) {
      throw new Error("descriptor is missing a string seq: " + JSON.stringify(descriptor));
    }
    return { ...descriptor, seq: "<seq>" };
  };

  return CASES.map(({ name, changeKind, entityKey, state, retiredField }) => ({
    name,
    local: normalise(
      local.make(
        changeKind,
        entityKey,
        state === undefined ? undefined : state,
        local.nextSequence(),
        retiredField,
      ),
    ),
    relay: normalise(
      relay.makeDescriptor(
        changeKind,
        entityKey,
        // The relay unmarshalls the stream image before building the descriptor,
        // so it takes the same plain row the other two do. A REMOVE is handed the
        // OldImage, which makeDescriptor then drops.
        state === undefined ? { id: entityKey } : state,
        "49590300000000016818000000",
        retiredField,
      ),
    ),
    postgres: normalise(
      postgres.makeDescriptor({
        changeKind,
        entityKey,
        state,
        seq: postgres.nextSequence(),
        retiredField,
      }),
    ),
  }));
}
