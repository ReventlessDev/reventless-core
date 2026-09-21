// The demo dataset for the online-shop-hybrid example.
//
// This file holds *what* to seed: literal data plus the deterministic
// generation that turns it into entities. Every command it produces is a real
// plugin command value — `CatalogPlugin.AddProduct.command`,
// `OrderingPlugin.PlaceOrder.command`, and so on — so a renamed or re-shaped
// command breaks the build here rather than failing at runtime against a
// half-seeded store.
//
// The mapping from those command values onto GraphQL mutations lives in
// `DemoCommands.res`; the run itself lives in `DemoSeed.res`.

// A fixed seed and fixed literal data: two first runs against a fresh store
// produce identical rows, so a seeded store is a usable baseline for comparison.
// Dates are the exception: delivery windows follow the run's day
// (`deliveryWindowFor`). A follow-up run makes its own generator, seeded from its
// run date. Every generator below takes the one it draws from.
let firstRunRandom = ReventlessSeed.Seed.Random.make(~seed=0x5eed)

let productCount = 60
let customerCount = 20
let orderCount = 150

// ── Categories ──────────────────────────────────────────────────────────────

type category = {
  id: string,
  name: string,
  weight: int,
  nouns: array<string>,
  archive: bool,
  // Absent until the upload phase fills it with the served `/{prefix}/{key}`
  // ref, exactly as `product.productImage` is.
  categoryImage: option<string>,
}

let categories: array<category> = [
  {
    id: "cat-01",
    name: "Laptops",
    weight: 9,
    nouns: ["Notebook", "Ultrabook", "Workstation"],
    archive: false,
    categoryImage: None,
  },
  {
    id: "cat-02",
    name: "Phones",
    weight: 10,
    nouns: ["Handset", "Smartphone", "Phone"],
    archive: false,
    categoryImage: None,
  },
  {
    id: "cat-03",
    name: "Audio",
    weight: 9,
    nouns: ["Headphones", "Earbuds", "Speaker"],
    archive: false,
    categoryImage: None,
  },
  {
    id: "cat-04",
    name: "Cameras",
    weight: 7,
    nouns: ["Camera", "Lens", "Gimbal"],
    archive: false,
    categoryImage: None,
  },
  {
    id: "cat-05",
    name: "Wearables",
    weight: 7,
    nouns: ["Watch", "Tracker", "Band"],
    archive: false,
    categoryImage: None,
  },
  {
    id: "cat-06",
    name: "Home Office",
    weight: 8,
    nouns: ["Desk Lamp", "Monitor", "Keyboard"],
    archive: false,
    categoryImage: None,
  },
  {
    id: "cat-07",
    name: "Accessories",
    weight: 6,
    nouns: ["Cable", "Adapter", "Case"],
    archive: false,
    categoryImage: None,
  },
  // Archived at the end of the catalog phase — after its products exist, since
  // AddProduct rejects an archived category with CategoryNotFound.
  {
    id: "cat-08",
    name: "Clearance",
    weight: 4,
    nouns: ["Bundle", "Refurb Kit"],
    archive: true,
    categoryImage: None,
  },
]

let renamedCategoryId = "cat-06"
let renamedCategoryName = "Home & Office"

// ── Word pools ──────────────────────────────────────────────────────────────

let brands = ["Aurora", "Basalt", "Cirrus", "Dovetail", "Ember", "Fathom", "Granite", "Halcyon"]
let qualifiers = ["Pro", "Air", "Max", "Lite", "Studio", "Go", "Plus", ""]
let blurbs = ["refreshed", "best-selling", "entry-level", "flagship", "compact"]

let firstNames = [
  "Ada",
  "Bruno",
  "Chiara",
  "Diego",
  "Elif",
  "Farid",
  "Greta",
  "Hugo",
  "Iris",
  "Jonas",
  "Kaja",
  "Luca",
  "Maya",
  "Noor",
  "Olof",
  "Pia",
  "Rafael",
  "Sana",
  "Tomas",
  "Vera",
]
let lastNames = [
  "Almeida",
  "Beck",
  "Costa",
  "Duarte",
  "Engel",
  "Ferrer",
  "Gruber",
  "Haas",
  "Ivanov",
  "Jansen",
  "Klein",
  "Lindqvist",
  "Moreau",
  "Nagy",
  "Olsen",
  "Petrov",
  "Rossi",
  "Sandberg",
  "Tamm",
  "Vogel",
]
let streets = ["Bakergasse", "Cedar Lane", "Dockside Way", "Elm Row", "Foundry Street"]
let cities = ["Bruges", "Cortona", "Delft", "Espoo", "Freiburg", "Gdansk"]

// Real coordinates for each entry in `cities`, index-aligned, so the Customers
// map view drops each pin on the customer's actual city rather than at (0, 0).
let cityCoords: array<(float, float)> = [
  (51.2093, 3.2247), // Bruges
  (43.2749, 11.9853), // Cortona
  (52.0116, 4.3571), // Delft
  (60.2055, 24.6559), // Espoo
  (47.999, 7.8421), // Freiburg
  (54.352, 18.6466), // Gdansk
]

// ── Supplier feed ───────────────────────────────────────────────────────────

// Rows for the ImportProduct InboundTranslationSlice. The last one is
// deliberately invalid so the ImportProductAudit view shows both outcomes: it
// sends a currency symbol where the feed's contract says ISO 4217 code, which is
// the kind of shape an anti-corruption layer exists to stop at the boundary.
let supplierFeed: array<CatalogPlugin.ImportProduct.externalInput> = [
  {
    sku: "SKU-4410",
    title: "Fathom Dock 4-Port",
    desc: "Supplier-fed docking station.",
    unitPrice: 8990,
    currency: "USD",
    category: "cat-07",
  },
  {
    sku: "SKU-4411",
    title: "Cirrus Travel Charger",
    desc: "Supplier-fed 65W charger.",
    unitPrice: 4550,
    currency: "USD",
    category: "cat-07",
  },
  {
    sku: "SKU-4412",
    title: "Granite Laptop Sleeve",
    desc: "Supplier-fed protective sleeve.",
    unitPrice: 3200,
    currency: "USD",
    category: "cat-07",
  },
  {
    sku: "SKU-4413",
    title: "Halcyon Desk Riser",
    desc: "Supplier-fed monitor riser.",
    unitPrice: 12400,
    currency: "USD",
    category: "cat-06",
  },
  {
    sku: "SKU-4414",
    title: "Ember Cable Set",
    desc: "Rejected: currency is a symbol, not an ISO 4217 code.",
    unitPrice: 1900,
    currency: "US$",
    category: "cat-07",
  },
]

// Which rows survive the boundary is the slice's decision, so ask the slice
// rather than restating its rules here. Stating them twice is how this drifted
// once already: the translation stopped rejecting non-USD rows when `Money.t`
// gave the supplier's currency somewhere to live, and a copy of the old rule
// left here failed the seed's audit-view cross-check against correct behaviour.
let importedSkus =
  supplierFeed
  ->Array.filter(row => CatalogPlugin.ImportProduct_Translation.translate(row)->Result.isOk)
  ->Array.map(row => row.sku)

let expectedImportSuccesses = importedSkus->Array.length
let expectedImportFailures = supplierFeed->Array.length - expectedImportSuccesses

// ── Generation helpers ──────────────────────────────────────────────────────

let pad = (n: int, width: int): string => n->Int.toString->String.padStart(width, "0")

let pick = (xs: array<string>, ~random): string =>
  ReventlessSeed.Seed.Random.pickOr(random, ~fallback="", xs)

let address = (~random): string => {
  let number = ReventlessSeed.Seed.Random.int(random, ~min=1, ~max=180)
  `${number->Int.toString} ${pick(streets, ~random)}, ${pick(cities, ~random)}`
}

// An address paired with the coordinates of the city it names, so a customer's
// map pin lands on the same city that appears in its address text.
let locatedAddress = (~random): (string, float, float) => {
  let number = ReventlessSeed.Seed.Random.int(random, ~min=1, ~max=180)
  let cityIndex = ReventlessSeed.Seed.Random.int(random, ~min=0, ~max=cities->Array.length - 1)
  let city = cities->Array.get(cityIndex)->Option.getOr("")
  let (lat, lng) = cityCoords->Array.get(cityIndex)->Option.getOr((0.0, 0.0))
  (`${number->Int.toString} ${pick(streets, ~random)}, ${city}`, lat, lng)
}

// ── Products ────────────────────────────────────────────────────────────────

// Which shelf a product ends the seed run on. Three-valued rather than the
// categories' `archive: bool`, because a product has two ways off the shelf and
// they are not interchangeable — one comes back and the other does not.
type shelf = Listed | Archived | Discontinued

type product = {
  id: string,
  name: string,
  description: string,
  price: Reventless.Money.t,
  productImage: option<string>,
  categoryId: string,
  // Stated by the fixture rather than derived at seed time, so reading this file
  // answers "which products end up retired" without following the run.
  shelf: shelf,
}

// This dataset prices everything in euros. That is a *choice this data makes*
// rather than something the domain assumes — the commands accept any ISO
// currency, and the shop only looks single-currency because its seed is.
let currency = Reventless.Currency.EUR

// A deterministic demo image per product: a distinct fill colour derived from
// the product index plus the product name as a label. SVG is tiny, text-based
// (no repo binaries, no third-party service), and serves cleanly through both
// the AWS CloudFront read path and the local dev serve route. Uploaded at seed
// time so each product's `productImage` travels the real upload → store → serve loop
// instead of an external URL. Products with no upload keep no image.
let escapeXml = (s: string): string =>
  s
  ->String.replaceAll("&", "&amp;")
  ->String.replaceAll("<", "&lt;")
  ->String.replaceAll(">", "&gt;")

let productSvg = (~name: string, ~index: int): string => {
  let hue = mod(index * 47, 360)
  let bg = `hsl(${hue->Int.toString}, 62%, 52%)`
  let label = escapeXml(name)
  `<svg xmlns="http://www.w3.org/2000/svg" width="400" height="300" viewBox="0 0 400 300">` ++
  `<rect width="400" height="300" fill="${bg}"/>` ++
  `<text x="200" y="160" fill="#ffffff" font-family="sans-serif" font-size="22" font-weight="600" text-anchor="middle">${label}</text>` ++ `</svg>`
}

// The same deterministic scheme for a category, in a wide banner rather than the
// product tile's 4:3 — a category image is a section header, and two images that
// differ only in their label are hard to tell apart on a page carrying both. The
// hue offset keeps a category from sharing a colour with the product that
// happens to land on its index.
let categorySvg = (~name: string, ~index: int): string => {
  let hue = mod(index * 47 + 23, 360)
  let bg = `hsl(${hue->Int.toString}, 52%, 42%)`
  let label = escapeXml(name)
  `<svg xmlns="http://www.w3.org/2000/svg" width="600" height="200" viewBox="0 0 600 200">` ++
  `<rect width="600" height="200" fill="${bg}"/>` ++
  `<text x="300" y="112" fill="#ffffff" font-family="sans-serif" font-size="30" font-weight="600" text-anchor="middle">${label}</text>` ++ `</svg>`
}

// One listed product in `category`. The draws happen in a fixed order, so a
// generator seeded the same way names and prices the same products.
let makeProduct = (~random, ~id: string, ~category: category): product => {
  let qualifier = pick(qualifiers, ~random)
  let suffix = qualifier == "" ? "" : ` ${qualifier}`
  let name = `${pick(brands, ~random)} ${pick(category.nouns, ~random)}${suffix}`
  // Log-uniform over ~5..900 so the price axis has a long right tail
  // instead of clustering in the middle of a linear range.
  let low = Math.log(5.0)
  let high = Math.log(900.0)
  let raw = Math.exp(low +. ReventlessSeed.Seed.Random.float(random) *. (high -. low))
  // `ofMajor` is the rounding: it scales by the currency's exponent and
  // lands on a whole minor unit, which is what the hand-written
  // `Math.round(raw *. 100.0) /. 100.0` here used to approximate.
  let price = Reventless.Money.ofMajor(~amount=raw, ~currency)
  {
    id,
    name,
    description: `${name} — ${pick(blurbs, ~random)} ${category.name->String.toLowerCase} pick.`,
    price,
    // Absent until the upload phase fills it with the served `/{prefix}/{key}`
    // ref; products left without an upload keep no image.
    productImage: None,
    categoryId: category.id,
    shelf: Listed,
  }
}

let buildProducts = (~random, ~count=productCount, ~idPrefix="prd-", ()): array<product> => {
  // Category share proportional to weight, so the catalog is lopsided the way a
  // real one is rather than eight even buckets.
  let totalWeight = categories->Array.reduce(0, (sum, c) => sum + c.weight)
  let products = []
  let n = ref(0)
  categories->Array.forEach(category => {
    let exact = Int.toFloat(category.weight) /. Int.toFloat(totalWeight) *. Int.toFloat(count)
    let share = Math.round(exact)->Int.fromFloat
    let share = share < 2 ? 2 : share
    for _ in 1 to share {
      if products->Array.length < count {
        n := n.contents + 1
        let product = makeProduct(~random, ~id=`${idPrefix}${pad(n.contents, 3)}`, ~category)
        products->Array.push({
          ...product,
          // Exactly one of each, at low indices so the `sample` set (16 products)
          // exercises the same path the full one does. A retirement that only the
          // large data set shows is a retirement nobody checks.
          shelf: switch n.contents {
          | 4 => Archived
          | 8 => Discontinued
          | _ => Listed
          },
        })
      }
    }
  })
  products
}

// The first run's changes: one of each, so a single run still exercises every
// path. The bulk of the churn is a follow-up run's, on a later day.
let repricedProducts = (products: array<product>): array<product> =>
  products->Array.filterWithIndex((_, i) => i == 4)

let redescribedProducts = (products: array<product>): array<product> =>
  products->Array.filterWithIndex((_, i) => i == 9)

// The two ways off the shelf, read back off the fixture. Retired late in the run
// — after orders reference the products — for the reason the archived category
// is: a product withdrawn before anything points at it demonstrates nothing,
// where one withdrawn after shows an order still resolving a product the catalog
// no longer offers, which is the case the whole feature is for.
let archivedProducts = (products: array<product>): array<product> =>
  products->Array.filter(p => p.shelf == Archived)

let discontinuedProducts = (products: array<product>): array<product> =>
  products->Array.filter(p => p.shelf == Discontinued)

// The discount is applied to the minor units directly, so it cannot drift into
// float error on the way through a decimal and back.
let scaledPrice = (price: Reventless.Money.t, ~by: float): Reventless.Money.t =>
  Reventless.Money.make(~amount=Math.round(price.amount *. by), ~currency=price.currency)

let discountedPrice = (p: product): Reventless.Money.t => scaledPrice(p.price, ~by=0.85)

// ── Customers ───────────────────────────────────────────────────────────────

type customer = {
  id: string,
  email: string,
  address: string,
  lat: float,
  lng: float,
}

/**
The demo logins, as customers.

An order's `customerId` is the authenticated caller's id, so a demo login can
only have orders if a customer row exists under that exact id — which means the
id has to be one the platform being seeded actually mints. Locally that is the
`userId` a users.yaml entry declares; on a Cognito deployment it is the `sub` the
pool minted, and no literal can name it. So the owners are *resolved* against
the accounts file and the run's own bearer rather than written down here.

Their order counts are fixed and different on purpose. "The shopper sees no
other orders" is satisfied equally by correct scoping and by scoping that
matches nothing, so the check that means anything is an exact non-zero count per
owner, with a third party holding the rest.

**Every account that can open the storefront gets a row.** `merch` is here for
that reason and not because a merchandiser goes shopping: it holds `Shopper`
alongside `Merchandiser`, and `Merchandiser` is deliberately absent from
`Storefront.elevatedGroups`, so without a row of its own it logs in to an empty
*My Orders* and an empty *My Notifications* — indistinguishable at the screen
from the defect this whole resolution exists to prevent. `fulfil` needs no row:
it is elevated, so it reads across owners and its screens are full regardless.
*/
let demoShopperOrderCount = 5
let demoOperatorOrderCount = 3
let demoMerchandiserOrderCount = 2

// Which account stands in for each demo owner: the accounts-file entry whose
// `demoOwner` names it, else the one with that username. Domain knowledge, and
// the reason this mapping is here rather than in the harness: the harness knows
// which account a run logged in as, not which of them this shop means by "the
// shopper".
let demoShopperUsername = "shopper"
let demoOperatorUsername = "admin"
let demoMerchandiserUsername = "merch"

// The `userId` values the local `users.example.yaml` declares. Kept only as the
// last arm of the resolution below, so a platform that supplies nothing still
// seeds the walkthrough it always did — locally the file and these agree, which
// is why local behaviour is unchanged.
let fallbackShopperId = "local-shopper"
let fallbackOperatorId = "local-admin"
let fallbackMerchandiserId = "local-merch"

/** Where a demo owner's id came from. */
type ownerSource =
  | // The accounts file declares a `userId` for that account — the id the
  // platform stamps, whichever account this run logged in as.
  AccountsFile
  | // The run authenticated AS that account, so its own bearer carries the id.
  // The only source on a platform that keeps no accounts file.
  Bearer
  | // Nothing on this platform supplied one.
  Fallback

type demoOwner = {role: string, username: string, id: string, source: ownerSource}

type owners = {shopper: demoOwner, operator: demoOwner, merchandiser: demoOwner}

/** The owners in report order — so a caller adding a fourth does not have to
    remember every place that walks them. */
let all = (o: owners): array<demoOwner> => [o.shopper, o.operator, o.merchandiser]

// One entry of the platform's accounts file, as the harness parses it.
type account = ReventlessSeed.Seed.Users.user

let resolveOwner = (
  ~role: string,
  ~username: string,
  ~fallback: string,
  ~accounts: array<account>,
  ~caller: account,
  ~callerId: option<string>,
): demoOwner => {
  let account = ReventlessSeed.Seed.Users.playing(accounts, username)
  let username = account->Option.mapOr(username, a => a.username)
  switch account->Option.flatMap(a => a.userId) {
  | Some(id) => {role, username, id, source: AccountsFile}
  | None =>
    switch caller.username == username ? callerId : None {
    | Some(id) => {role, username, id, source: Bearer}
    | None => {role, username, id: fallback, source: Fallback}
    }
  }
}

let resolveOwners = (
  ~accounts: array<account>,
  ~caller: account,
  ~callerId: option<string>,
): owners => {
  shopper: resolveOwner(
    ~role="shopper",
    ~username=demoShopperUsername,
    ~fallback=fallbackShopperId,
    ~accounts,
    ~caller,
    ~callerId,
  ),
  operator: resolveOwner(
    ~role="operator",
    ~username=demoOperatorUsername,
    ~fallback=fallbackOperatorId,
    ~accounts,
    ~caller,
    ~callerId,
  ),
  merchandiser: resolveOwner(
    ~role="merchandiser",
    ~username=demoMerchandiserUsername,
    ~fallback=fallbackMerchandiserId,
    ~accounts,
    ~caller,
    ~callerId,
  ),
}

/** One line per demo owner, naming the id it seeds under and where that came
    from. Silence is what turned an unreadable view into a browser-side mystery,
    so the resolution is stated on every run and not only when it goes wrong. */
let describeOwner = (o: demoOwner): string => {
  let from = switch o.source {
  | AccountsFile => `the userId the accounts file records for "${o.username}"`
  | Bearer => `the bearer this run logged in with, as "${o.username}"`
  | Fallback => `a fallback literal — nothing on this platform names "${o.username}"`
  }
  `demo ${o.role}: ${o.id} (${from})`
}

/**
 * What is wrong with a resolution, phrased for someone who has not yet opened a
 * browser to find out.
 *
 * `Fallback` always warns, because a fallback IS the guess: nothing on the
 * platform named an id for that account, so the literal is right only where it
 * happens to match — and where it does not, the notification chain, the
 * projection and the owner resolver all work perfectly and produce a view that
 * is full for the seeder and empty for every human.
 *
 * Whether a literal "looks like" a platform's ids is deliberately not the test.
 * The only sample of that is the run's OWN id, which belongs to a different
 * account and so is supposed to differ — comparing the two would warn on every
 * correct run and stay quiet on some wrong ones.
 *
 * The second arm is the stale accounts file: the run holds the id the platform
 * actually minted for the account it logged in as, so a file that disagrees
 * about that one account is answerable rather than merely suspicious.
 */
let ownerWarning = (o: demoOwner, ~caller: account, ~callerId: option<string>): option<string> =>
  switch (o.source, callerId) {
  | (Fallback, _) =>
    let stamps = switch callerId {
    | Some(id) => ` This run's own bearer carries "${id}", which is what an id looks like here.`
    | None => ""
    }
    Some(
      `the demo ${o.role} fell back to the literal "${o.id}" — nothing on this platform names an ` ++
      `id for "${o.username}", so that is a guess.${stamps} Owner-scoped rows seeded under the ` ++
      `wrong id are invisible to every account on this deployment: record a userId for ` ++
      `"${o.username}" in the accounts file and re-seed.`,
    )
  | (AccountsFile, Some(id)) if caller.username == o.username && id != o.id =>
    Some(
      `the accounts file records userId "${o.id}" for "${o.username}", but the bearer this run ` ++
      `logged in with as that same account carries "${id}" — the file is stale, and the demo ` ++
      `${o.role}'s rows are being seeded under an id nobody holds.`,
    )
  | _ => None
  }

let demoCustomers = (owners: owners): array<customer> => [
  {
    id: owners.shopper.id,
    email: "shopper@example.com",
    address: "Nordbahnstrasse 36, 1020 Vienna, Austria",
    lat: 48.2265,
    lng: 16.3897,
  },
  {
    id: owners.operator.id,
    email: "admin@example.com",
    address: "Praterstrasse 1, 1020 Vienna, Austria",
    lat: 48.2135,
    lng: 16.3849,
  },
  {
    id: owners.merchandiser.id,
    email: "merch@example.com",
    address: "Taborstrasse 12, 1020 Vienna, Austria",
    lat: 48.2189,
    lng: 16.3812,
  },
]

// `~nameOffset` continues the name pools past the customers that already exist,
// and `~emailTag` keeps a later run's addresses from repeating an earlier run's.
let buildCustomers = (
  ~random,
  ~count=customerCount,
  ~idPrefix="cust-",
  ~nameOffset=0,
  ~emailTag="",
  (),
): array<customer> =>
  Array.fromInitializer(~length=count, i => {
    let n = i + nameOffset
    let first = firstNames->Array.get(mod(n, firstNames->Array.length))->Option.getOr("Ada")
    let last = lastNames->Array.get(mod(n * 7 + 3, lastNames->Array.length))->Option.getOr("Beck")
    let id = `${idPrefix}${pad(i + 1, 2)}`
    let (address, lat, lng) = locatedAddress(~random)
    {
      id,
      email: `${first}.${last}${emailTag}@example.com`->String.toLowerCase,
      address,
      lat,
      lng,
    }
  })

let movedCustomers = (customers: array<customer>): array<customer> =>
  customers->Array.filterWithIndex((_, i) => i == 2)

let deactivatedCustomers = (customers: array<customer>): array<customer> =>
  customers->Array.filterWithIndex((_, i) => i == 5)

let newAddress = (~random) => address(~random)

// ── Orders ──────────────────────────────────────────────────────────────────

type order = {
  id: string,
  customerId: string,
  lineItems: array<OrderingPlugin.PlaceOrder.lineItem>,
  shippingMethod: OrderingPlugin.PlaceOrder.shippingMethod,
  // The requested delivery slot, as one declared `DateRange` — not a guessed
  // `start*`/`end*` field pair. `None` for Pickup (collected in store) and for
  // the orders that name no preference, so the scheduler mode has both rows that
  // carry a bar and rows that do not.
  deliveryWindow: option<Reventless.DateRange.t>,
}

// Slot hours (UTC), so a day grid has morning, afternoon and evening bars.
let deliverySlotHours = [(9, 12), (14, 17), (18, 21)]

let dayMs = 86400000.0

let startOfDay = (instant: float): float => Math.floor(instant /. dayMs) *. dayMs

// The requested slot for the i-th order, counted in days after the run's UTC day:
// 1–2 for Express, which ships at once, and 3–21 for Standard, which waits for a
// run to dispatch it. Never before that day — orders are placed when the seed
// runs, and a window before it would be a delivery requested for the past.
// Derived from the index, not drawn, so the shared random stream and everything
// sampled after it stay as they were.
let deliveryWindowFor = (
  i: int,
  ~today: float,
  ~shippingMethod: OrderingPlugin.PlaceOrder.shippingMethod,
): Reventless.DateRange.t => {
  let offset = switch shippingMethod {
  | Express => 1 + mod(i, 2)
  | Standard | Pickup => 3 + mod(i * 5, 19)
  }
  let day = startOfDay(today) +. Float.fromInt(offset) *. dayMs
  let (from, until) = deliverySlotHours->Array.getUnsafe(mod(i, Array.length(deliverySlotHours)))
  let at = hour => Date.fromTime(day +. Float.fromInt(hour) *. 3600000.0)->Date.toISOString
  Reventless.DateRange.make(~start=at(from), ~end_=at(until))->Result.getOrThrow
}

// The customer of each of the first orders: the demo logins, by index rather
// than by the weighted draw, so their counts are exact rather than probable — an
// acceptance check that asserts "5 orders" cannot be written against a Zipf
// sample.
let demoOrderCustomers = (owners: owners): array<string> =>
  Array.concat(
    Array.make(~length=demoShopperOrderCount, owners.shopper.id),
    Array.concat(
      Array.make(~length=demoOperatorOrderCount, owners.operator.id),
      Array.make(~length=demoMerchandiserOrderCount, owners.merchandiser.id),
    ),
  )

// `~reserved` names the customer of each of the first orders; every order after
// them is drawn over `~customerIds`, so a reserved customer picks up no extra rows.
let buildOrders = (
  ~random,
  ~productIds: array<string>,
  ~customerIds: array<string>,
  ~reserved: array<string>=[],
  ~count=orderCount,
  ~idPrefix="ord-",
  ~today: float,
  (),
): array<order> => {
  // Zipf over a fixed shuffle: a handful of products carry most of the demand
  // and the tail is long, so ProductDemand reads as a real leaderboard.
  let shuffled = ReventlessSeed.Seed.Random.sampleWeighted(
    random,
    productIds->Array.map(id => (id, 1.0)),
    ~count=productIds->Array.length,
  )
  let productWeights = ReventlessSeed.Seed.Random.zipfWeights(shuffled, ~exponent=1.1)
  // Milder skew on customers: a few repeat buyers, nobody with zero.
  let customerWeights = ReventlessSeed.Seed.Random.zipfWeights(customerIds, ~exponent=0.45)

  Array.fromInitializer(~length=count, i => {
    let sizeRoll = ReventlessSeed.Seed.Random.float(random)
    let size = if sizeRoll < 0.5 {
      1
    } else if sizeRoll < 0.75 {
      2
    } else if sizeRoll < 0.9 {
      3
    } else {
      4
    }
    let customerId = switch reserved->Array.get(i) {
    | Some(id) => id
    | None =>
      ReventlessSeed.Seed.Random.sampleWeighted(random, customerWeights, ~count=1)
      ->Array.get(0)
      ->Option.getOr("cust-01")
    }
    // Mostly one of a thing, occasionally two or three — enough that the demo's
    // totals differ from one another rather than all being a single unit price.
    let lineItems = ReventlessSeed.Seed.Random.sampleWeighted(
      random,
      productWeights,
      ~count=size,
    )->Array.map(productId => {
      let quantityRoll = ReventlessSeed.Seed.Random.float(random)
      let quantity = if quantityRoll < 0.7 {
        1
      } else if quantityRoll < 0.92 {
        2
      } else {
        3
      }

      (
        {
          productId: CatalogSpec.ProductId.make(productId),
          quantity,
        }: OrderingPlugin.PlaceOrder.lineItem
      )
    })
    // Drives the whole downstream lifecycle: Express is auto-shipped by the
    // AutoShipOrder automation, Standard waits for the batch dispatch, Pickup
    // never ships. This split is what gives the board three columns.
    let methodRoll = ReventlessSeed.Seed.Random.float(random)
    let shippingMethod: OrderingPlugin.PlaceOrder.shippingMethod = if methodRoll < 0.35 {
      Express
    } else if methodRoll < 0.8 {
      Standard
    } else {
      Pickup
    }
    // A delivered order asks for a slot ~60% of the time; Pickup never does.
    let windowRoll = ReventlessSeed.Seed.Random.float(random)
    let deliveryWindow = if shippingMethod == Pickup || windowRoll < 0.4 {
      None
    } else {
      Some(deliveryWindowFor(i, ~today, ~shippingMethod))
    }
    {id: `${idPrefix}${pad(i + 1, 3)}`, customerId, lineItems, shippingMethod, deliveryWindow}
  })
}

// ── Shipping and cancelling ─────────────────────────────────────────────────

// An order still waiting in `Placed`, as a run sees it: the first run from the
// orders it just built, a follow-up from the Orders view.
type placedOrder = {
  id: string,
  shippingMethod: OrderingPlugin.PlaceOrder.shippingMethod,
  deliveryWindow: option<Reventless.DateRange.t>,
}

let placedOf = (o: order): placedOrder => {
  id: o.id,
  shippingMethod: o.shippingMethod,
  deliveryWindow: o.deliveryWindow,
}

// How many days ahead of its window a Standard order ships.
let shipLeadDays = 3

/** The warehouse run: the Standard orders whose window opens within
    `shipLeadDays` of `today`, plus every other one of those without a window.
    Express is the automation's business and Pickup never ships. Run on a later
    day, the same rule ships what an earlier run left waiting. */
let dueForShipping = (placed: array<placedOrder>, ~today: float): array<string> => {
  let standard = placed->Array.filter(o => o.shippingMethod == Standard)
  let horizon = startOfDay(today) +. Float.fromInt(shipLeadDays + 1) *. dayMs
  let windowDue =
    standard->Array.filter(o =>
      o.deliveryWindow->Option.mapOr(false, w => Reventless.DateRange.millis(w.start) < horizon)
    )
  let unscheduled =
    standard
    ->Array.filter(o => o.deliveryWindow->Option.isNone)
    ->Array.filterWithIndex((_, i) => mod(i, 2) == 0)
  Array.concat(windowDue, unscheduled)->Array.map(o => o.id)
}

/** Up to `max` cancellations, drawn only from orders still in Placed that this
    run is not shipping. An Express order is already Shipped and could not be
    cancelled. */
let cancellations = (placed: array<placedOrder>, ~shipping: array<string>, ~max: int): array<
  string,
> =>
  placed
  ->Array.filter(o => o.shippingMethod != Express && !(shipping->Array.includes(o.id)))
  ->Array.filterWithIndex((_, i) => mod(i, 3) == 1)
  ->Array.slice(~start=0, ~end=max)
  ->Array.map(o => o.id)
