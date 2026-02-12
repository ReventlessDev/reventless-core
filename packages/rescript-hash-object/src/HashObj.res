module Options = {
  type encoding =
    | @as("hex") Hex | @as("base64") Base64 | @as("buffer") Buffer | @as("latin1") Latin1
  type algorithm = | @as("md5") MD5 | @as("sha1") SHA1 | @as("sha256") SHA256 | @as("sha512") SHA512

  type t = {
    encoding?: encoding,
    algorithm?: algorithm,
  }
}

@module("hash-object") @default
external hashDict: (~dict: dict<string>, ~options: Options.t=?) => string = "default"
