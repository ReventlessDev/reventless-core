open JestGlobals

// `isAffirmative` is the one vocabulary for "yes", shared by a typed `[y/N]`
// reply and by the env var that stands in for it on a run with no terminal.
//
// It exists because those two drifted: the prompt took `y`, the env var took
// only the literals `1` and `yes`, and every other value — `y` included, and an
// explicit `no` with it — fell through to the interactive branch, which throws
// when there is no TTY. So the variable that exists to make the tool
// non-interactive had two spellings that worked and a crash for the rest.
//
// The suite is written around the shape of that bug rather than around the
// function: what must confirm, what must decline, and — the case that actually
// broke CI — that declining is a normal answer and not a fall-through.

describe("Seed_Prompt.isAffirmative:", () => {
  testSync("takes the three spellings of yes", () => {
    ["y", "yes", "1"]->Array.forEach(v =>
      expect(Seed_Prompt.isAffirmative(v))->Expect.toBe(true)
    )
  })

  // A prompt that prints `[y/N]` invites a capital as readily as a lowercase
  // one, and an env var set by hand is written however the hand felt.
  testSync("ignores case, so Y and YES answer as y does", () => {
    ["Y", "Yes", "YES"]->Array.forEach(v =>
      expect(Seed_Prompt.isAffirmative(v))->Expect.toBe(true)
    )
  })

  testSync("ignores surrounding space", () => {
    [" y", "y ", "  yes  "]->Array.forEach(v =>
      expect(Seed_Prompt.isAffirmative(v))->Expect.toBe(true)
    )
  })

  // The half that matters most: every one of these is an ANSWER, and the caller
  // reads it as "no". None may be mistaken for "nothing was said", which is what
  // sent the old code to a prompt it could not open.
  testSync("declines every spelling of no, capital N included", () => {
    ["n", "N", "no", "No", "NO"]->Array.forEach(v =>
      expect(Seed_Prompt.isAffirmative(v))->Expect.toBe(false)
    )
  })

  testSync("declines anything it does not recognise", () => {
    ["", "  ", "0", "true", "yep", "y.", "yesplease", "affirmative"]->Array.forEach(v =>
      expect(Seed_Prompt.isAffirmative(v))->Expect.toBe(false)
    )
  })

  // `true` is deliberately absent from the vocabulary above. Named here so that
  // adding it is a decision someone takes against a failing test rather than a
  // kindness someone slips in: the prompt this stands in for asks `[y/N]`, and a
  // reply nobody would type at that prompt should not work around it either.
  testSync("does not quietly grow a fourth spelling", () => {
    expect(Seed_Prompt.isAffirmative("true"))->Expect.toBe(false)
  })
})
