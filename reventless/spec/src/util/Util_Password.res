/***
A password a Reventless pool will accept, minted rather than chosen.

Here rather than beside the AWS provisioning script because two callers need it
and only one of them is AWS: `provision-admin` mints the first administrator's
credential, and [AccountsManifest.prepare] fills a manifest's empty password
fields on any platform, with no cloud account involved. A generator living in
`reventless/aws` would make the platform-neutral half reach into the AWS package
for arithmetic that has nothing to do with AWS.
*/

/** Excludes the glyphs a person confuses when retyping a printed credential —
  `l`/`I`/`1` and `O`/`0`. These passwords are read off a terminal or out of a
  file once, and a bootstrap that fails on a misread character sends the operator
  back to the console this exists to avoid. */
let lower = "abcdefghijkmnopqrstuvwxyz"
let upper = "ABCDEFGHJKLMNPQRSTUVWXYZ"
let digits = "23456789"
let alphabet = lower ++ upper ++ digits

/** Comfortably over the 12 every Reventless pool is created with, since nobody
  has to remember it. */
let length = 24

/** `count` uniform bytes as ints.

  Via the hex encoding because that is what [NodeCrypto] exposes of a Buffer, and
  a binding returning raw byte values would be a new one added for this alone.
  Two hex digits always parse, so the fallback below is unreachable — it is there
  because the parse is *typed* as partial, not because it can fail. */
let randomInts = (count: int): array<int> => {
  let hex = NodeCrypto.randomBytes(count)->NodeCrypto.bufferToString("hex")
  Array.fromInitializer(~length=count, i =>
    hex->String.substring(~start=i * 2, ~end=i * 2 + 2)->Int.fromString(~radix=16)->Option.getOr(0)
  )
}

let charAt = (source: string, n: int): string =>
  source->String.charAt(mod(n, source->String.length))

/**
A password that satisfies the pool policy every Reventless pool is created with
(12+ characters, with a lowercase, an uppercase and a digit).

Satisfies it *by construction*: the three required classes are written into three
non-overlapping thirds of the string, so one of each is always present. The
obvious alternative — generate, test, regenerate — would leave a branch that
almost never runs and, when it did, would hand Cognito a password it refuses.
Almost-never is exactly the branch nobody has tested.
*/
let generate = (): string => {
  let ints = randomInts(length + 6)
  let chars = ints->Array.slice(~start=0, ~end=length)->Array.map(n => alphabet->charAt(n))
  let third = length / 3
  [lower, upper, digits]->Array.forEachWithIndex((classAlphabet, block) => {
    let position = block * third + mod(ints->Array.getUnsafe(length + block), third)
    chars->Array.set(position, classAlphabet->charAt(ints->Array.getUnsafe(length + 3 + block)))
  })
  chars->Array.join("")
}
