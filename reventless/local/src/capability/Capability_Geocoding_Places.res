// The geocoder a dev platform provisions: it knows only the places a file lists,
// `.reventless/places.yaml` beside `accounts.yaml`. An address resolves when it
// names a listed place, as a whole or as its last comma-separated part, and lands
// on that place's point. Any other address answers `Unavailable` and stays queued,
// as with no geocoder at all: a made-up point would be a wrong location shown as a
// right one.

/** One listed place: what an address names, and where it is. */
@schema
type place = {
  place: string,
  point: Reventless.GeoPoint.t,
}

let placesSchema = S.array(placeSchema)

/** The file's name in `.reventless/`. */
let fileName = "places.yaml"

/** The template a platform package keeps beside itself, copied by `setup`. */
let templateName = "places.example.yaml"

/** Where the platform looks: `.reventless/places.yaml` in the directory it runs from. */
let defaultPath = (): string => NodePath.join([NodeProcess.cwd(), ".reventless", fileName])

/** Strict, as the accounts file is: one malformed entry refuses the file, since a
    place silently dropped reads as an address that stopped resolving. */
let parseString = (yamlText: string): result<array<place>, string> =>
  try {
    Ok(S.parseOrThrow(Reventless.AccountsManifest.parseYaml(yamlText), ~to=placesSchema))
  } catch {
  | JsExn(err) => Error(JsExn.message(err)->Option.getOr("YAML parse error"))
  | _ => Error("YAML parse error")
  }

let parseFile = (path: string): result<array<place>, string> =>
  try {
    parseString(NodeFs.readFileSync(path))
  } catch {
  | JsExn(err) => Error(JsExn.message(err)->Option.getOr(`Cannot read ${path}`))
  | _ => Error(`Cannot read ${path}`)
  }

let _normalize = (text: string): string =>
  text
  ->String.trim
  ->String.toLowerCase
  ->String.splitByRegExp(/\s+/)
  ->Array.filterMap(x => x)
  ->Array.join(" ")

/** The place an address names: the whole text first, then its last part. */
let find = (places: array<place>, ~text: string): option<place> => {
  let whole = _normalize(text)
  let last = text->String.split(",")->Array.at(-1)->Option.getOr("")->_normalize
  let named = key => places->Array.find(p => _normalize(p.place) == key)
  switch named(whole) {
  | Some(_) as found => found
  | None => last == "" ? None : named(last)
  }
}

/** A search over `places`, in the port every geocoder answers through. */
let search = (places: array<place>): Reventless.Geocoding.search =>
  async (~text) =>
    switch find(places, ~text) {
    | Some({place, point}) => Ok([{label: place, point, relevance: 1.0}])
    | None =>
      Error(Unavailable(`"${text->String.trim}" names no place in ${fileName}, so it stays queued`))
    }

/** The places in `path` (default: `.reventless/places.yaml`), or `None` when there is
    no such file. */
let load = (~path: string=defaultPath()): option<result<array<place>, string>> =>
  NodeFs.existsSync(path) ? Some(parseFile(path)) : None
