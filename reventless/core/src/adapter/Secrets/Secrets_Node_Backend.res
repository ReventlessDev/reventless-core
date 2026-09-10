// The secret source both platforms use: `node:crypto`, which AWS Lambda and the
// local runtime both have. One implementation rather than two, for the same
// reason the log messaging transport is shared — a second copy is one edit away
// from differing on the part that matters.

let _bytes = (count: int): array<int> => {
  // Read back as hex and re-split, because the binding treats a Buffer as opaque
  // — it is only ever stringified or fed to an HMAC. Two hex characters is one
  // byte, so this is a decode rather than a reinterpretation.
  let hex = NodeCrypto.randomBytes(count)->NodeCrypto.bufferToString("hex")
  Array.fromInitializer(~length=count, i =>
    hex->String.substring(~start=i * 2, ~end=i * 2 + 2)->Int.fromString(~radix=16)->Option.getOr(0)
  )
}

/**
Whether a random byte may be folded into an alphabet of `size`, or must be drawn
again.

🚨 **`byte % size` is not uniform, and this predicate is the whole defence.** 256
is not a multiple of 10, so bytes 250–255 fold onto digits 0–5 and make those six
about four percent likelier each than the other four. An attacker guessing a
numeric code guesses the likelier half first. Discarding everything at or above
the largest whole multiple of `size` costs a few extra draws and makes every
character equally likely.

Separate and named because the skew it prevents is far too small to catch by
sampling the output — it is checked directly, over every byte value.
*/
let accepts = (~byte: int, ~size: int): bool => byte < 256 - mod(256, size)

let _draw = (~length: int, ~from: string): string => {
  let size = from->String.length
  let out = []
  while out->Array.length < length {
    // Over-draw: most bytes are kept, so one round is nearly always enough, and
    // a short round simply goes again.
    _bytes((length - out->Array.length) * 2 + 8)->Array.forEach(byte =>
      if accepts(~byte, ~size) && out->Array.length < length {
        out->Array.push(from->String.charAt(mod(byte, size)))
      }
    )
  }
  out->Array.join("")
}

/**
The provider both platforms pass.

`length` is refused rather than clamped when it is not positive: a caller asking
for a zero-length token has a bug, and answering `""` would hand back something
that compares equal to nothing and settles every challenge.
*/
let provider: Reventless.Secrets.t = {
  randomToken: (~length, ~alphabet) =>
    length <= 0
      ? Error(Unavailable(`a token needs a positive length, not ${length->Int.toString}`))
      : Ok(_draw(~length, ~from=Reventless.Secrets.characters(alphabet))),
  hash: input => Ok(NodeCrypto.sha256Hex(input)),
}
