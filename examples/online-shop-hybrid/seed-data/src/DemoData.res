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

// A fixed seed and fixed literal data: two runs against a fresh store produce
// identical rows, so a seeded store is a usable baseline for comparison.
let random = ReventlessSeed.Seed.Random.make(~seed=0x5eed)

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
  {id: "cat-01", name: "Laptops", weight: 9, nouns: ["Notebook", "Ultrabook", "Workstation"], archive: false, categoryImage: None},
  {id: "cat-02", name: "Phones", weight: 10, nouns: ["Handset", "Smartphone", "Phone"], archive: false, categoryImage: None},
  {id: "cat-03", name: "Audio", weight: 9, nouns: ["Headphones", "Earbuds", "Speaker"], archive: false, categoryImage: None},
  {id: "cat-04", name: "Cameras", weight: 7, nouns: ["Camera", "Lens", "Gimbal"], archive: false, categoryImage: None},
  {id: "cat-05", name: "Wearables", weight: 7, nouns: ["Watch", "Tracker", "Band"], archive: false, categoryImage: None},
  {id: "cat-06", name: "Home Office", weight: 8, nouns: ["Desk Lamp", "Monitor", "Keyboard"], archive: false, categoryImage: None},
  {id: "cat-07", name: "Accessories", weight: 6, nouns: ["Cable", "Adapter", "Case"], archive: false, categoryImage: None},
  // Archived at the end of the catalog phase — after its products exist, since
  // AddProduct rejects an archived category with CategoryNotFound.
  {id: "cat-08", name: "Clearance", weight: 4, nouns: ["Bundle", "Refurb Kit"], archive: true, categoryImage: None},
]

let renamedCategoryId = "cat-06"
let renamedCategoryName = "Home & Office"

// ── Word pools ──────────────────────────────────────────────────────────────

let brands = ["Aurora", "Basalt", "Cirrus", "Dovetail", "Ember", "Fathom", "Granite", "Halcyon"]
let qualifiers = ["Pro", "Air", "Max", "Lite", "Studio", "Go", "Plus", ""]
let blurbs = ["refreshed", "best-selling", "entry-level", "flagship", "compact"]

let firstNames = [
  "Ada", "Bruno", "Chiara", "Diego", "Elif", "Farid", "Greta", "Hugo", "Iris", "Jonas",
  "Kaja", "Luca", "Maya", "Noor", "Olof", "Pia", "Rafael", "Sana", "Tomas", "Vera",
]
let lastNames = [
  "Almeida", "Beck", "Costa", "Duarte", "Engel", "Ferrer", "Gruber", "Haas", "Ivanov", "Jansen",
  "Klein", "Lindqvist", "Moreau", "Nagy", "Olsen", "Petrov", "Rossi", "Sandberg", "Tamm", "Vogel",
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
  {sku: "SKU-4410", title: "Fathom Dock 4-Port", desc: "Supplier-fed docking station.", unitPrice: 8990, currency: "USD", category: "cat-07"},
  {sku: "SKU-4411", title: "Cirrus Travel Charger", desc: "Supplier-fed 65W charger.", unitPrice: 4550, currency: "USD", category: "cat-07"},
  {sku: "SKU-4412", title: "Granite Laptop Sleeve", desc: "Supplier-fed protective sleeve.", unitPrice: 3200, currency: "USD", category: "cat-07"},
  {sku: "SKU-4413", title: "Halcyon Desk Riser", desc: "Supplier-fed monitor riser.", unitPrice: 12400, currency: "USD", category: "cat-06"},
  {sku: "SKU-4414", title: "Ember Cable Set", desc: "Rejected: currency is a symbol, not an ISO 4217 code.", unitPrice: 1900, currency: "US$", category: "cat-07"},
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

let pick = (xs: array<string>): string =>
  ReventlessSeed.Seed.Random.pickOr(random, ~fallback="", xs)

let address = (): string => {
  let number = ReventlessSeed.Seed.Random.int(random, ~min=1, ~max=180)
  `${number->Int.toString} ${pick(streets)}, ${pick(cities)}`
}

// An address paired with the coordinates of the city it names, so a customer's
// map pin lands on the same city that appears in its address text.
let locatedAddress = (): (string, float, float) => {
  let number = ReventlessSeed.Seed.Random.int(random, ~min=1, ~max=180)
  let cityIndex = ReventlessSeed.Seed.Random.int(random, ~min=0, ~max=cities->Array.length - 1)
  let city = cities->Array.get(cityIndex)->Option.getOr("")
  let (lat, lng) = cityCoords->Array.get(cityIndex)->Option.getOr((0.0, 0.0))
  (`${number->Int.toString} ${pick(streets)}, ${city}`, lat, lng)
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
  `<text x="200" y="160" fill="#ffffff" font-family="sans-serif" font-size="22" font-weight="600" text-anchor="middle">${label}</text>` ++
  `</svg>`
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
  `<text x="300" y="112" fill="#ffffff" font-family="sans-serif" font-size="30" font-weight="600" text-anchor="middle">${label}</text>` ++
  `</svg>`
}

let buildProducts = (~count=productCount, ()): array<product> => {
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
        let qualifier = pick(qualifiers)
        let suffix = qualifier == "" ? "" : ` ${qualifier}`
        let name = `${pick(brands)} ${pick(category.nouns)}${suffix}`
        // Log-uniform over ~5..900 so the price axis has a long right tail
        // instead of clustering in the middle of a linear range.
        let low = Math.log(5.0)
        let high = Math.log(900.0)
        let raw = Math.exp(low +. ReventlessSeed.Seed.Random.float(random) *. (high -. low))
        // `ofMajor` is the rounding: it scales by the currency's exponent and
        // lands on a whole minor unit, which is what the hand-written
        // `Math.round(raw *. 100.0) /. 100.0` here used to approximate.
        let price = Reventless.Money.ofMajor(~amount=raw, ~currency)
        products->Array.push({
          id: `prd-${pad(n.contents, 3)}`,
          name,
          description: `${name} — ${pick(blurbs)} ${category.name->String.toLowerCase} pick.`,
          price,
          // Absent until the upload phase fills it with the served `/{prefix}/{key}`
          // ref; products left without an upload keep no image.
          productImage: None,
          categoryId: category.id,
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

/** A little post-creation churn, so views are not uniformly "created once and
    never touched" and the price-change path through to Ordering is exercised. */
let repricedProducts = (products: array<product>): array<product> =>
  products->Array.filterWithIndex((_, i) => mod(i, 11) == 4)

let redescribedProducts = (products: array<product>): array<product> =>
  products->Array.filterWithIndex((_, i) => mod(i, 17) == 9)

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
let discountedPrice = (p: product): Reventless.Money.t =>
  Reventless.Money.make(~amount=Math.round(p.price.amount *. 0.85), ~currency=p.price.currency)

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
only have orders if a customer row exists under that exact id. These match the
`userId` values in `users.example.yaml`; changing one without the other gives a
shopper a working login and an empty shop.

Their order counts are fixed and different on purpose. "The shopper sees no
other orders" is satisfied equally by correct scoping and by scoping that
matches nothing, so the check that means anything is an exact non-zero count per
owner, with a third party holding the rest.
*/
let demoShopperId = "local-shopper"
let demoOperatorId = "local-admin"
let demoShopperOrderCount = 5
let demoOperatorOrderCount = 3

let demoCustomers: array<customer> = [
  {
    id: demoShopperId,
    email: "shopper@example.com",
    address: "Nordbahnstrasse 36, 1020 Vienna, Austria",
    lat: 48.2265,
    lng: 16.3897,
  },
  {
    id: demoOperatorId,
    email: "admin@example.com",
    address: "Praterstrasse 1, 1020 Vienna, Austria",
    lat: 48.2135,
    lng: 16.3849,
  },
]

let buildCustomers = (~count=customerCount, ()): array<customer> =>
  Array.fromInitializer(~length=count, i => {
    let first = firstNames->Array.get(mod(i, firstNames->Array.length))->Option.getOr("Ada")
    let last =
      lastNames->Array.get(mod(i * 7 + 3, lastNames->Array.length))->Option.getOr("Beck")
    let id = `cust-${pad(i + 1, 2)}`
    let (address, lat, lng) = locatedAddress()
    {
      id,
      email: `${first}.${last}@example.com`->String.toLowerCase,
      address,
      lat,
      lng,
    }
  })

let movedCustomers = (customers: array<customer>): array<customer> =>
  customers->Array.filterWithIndex((_, i) => mod(i, 6) == 2)

let deactivatedCustomers = (customers: array<customer>): array<customer> =>
  customers->Array.filterWithIndex((_, i) => mod(i, 9) == 5)

let newAddress = () => address()

// ── Orders ──────────────────────────────────────────────────────────────────

type order = {
  id: string,
  customerId: string,
  productIds: array<string>,
  shippingMethod: OrderingPlugin.PlaceOrder.shippingMethod,
  // The requested delivery slot, as one declared `DateRange` — not a guessed
  // `start*`/`end*` field pair. `None` for Pickup (collected in store) and for
  // the orders that name no preference, so the scheduler mode has both rows that
  // carry a bar and rows that do not.
  deliveryWindow: option<Reventless.DateRange.t>,
}

// A small fixed pool of slots so seeded windows are deterministic and a day grid
// has both morning and afternoon bars to lay out across two days.
let deliverySlots = [
  ("2026-03-02T09:00:00Z", "2026-03-02T12:00:00Z"),
  ("2026-03-02T14:00:00Z", "2026-03-02T17:00:00Z"),
  ("2026-03-03T09:00:00Z", "2026-03-03T12:00:00Z"),
  ("2026-03-03T14:00:00Z", "2026-03-03T17:00:00Z"),
]

let buildOrders = (
  products: array<product>,
  customers: array<customer>,
  ~count=orderCount,
  (),
): array<order> => {
  // Zipf over a fixed shuffle: a handful of products carry most of the demand
  // and the tail is long, so ProductDemand reads as a real leaderboard.
  let shuffled = ReventlessSeed.Seed.Random.sampleWeighted(
    random,
    products->Array.map(p => (p, 1.0)),
    ~count=products->Array.length,
  )
  let productWeights = ReventlessSeed.Seed.Random.zipfWeights(shuffled, ~exponent=1.1)
  // Milder skew on customers: a few repeat buyers, nobody with zero.
  let customerWeights = ReventlessSeed.Seed.Random.zipfWeights(customers, ~exponent=0.45)

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
    // The first orders belong to the demo logins, by index rather than by the
    // weighted draw, so their counts are exact rather than probable — an
    // acceptance check that asserts "5 orders" cannot be written against a Zipf
    // sample. Everything after them is distributed as before, over the generated
    // customers only, so neither demo owner picks up extra rows.
    let demoOwner = if i < demoShopperOrderCount {
      Some(demoShopperId)
    } else if i < demoShopperOrderCount + demoOperatorOrderCount {
      Some(demoOperatorId)
    } else {
      None
    }
    let customerId = switch demoOwner {
    | Some(id) => id
    | None =>
      ReventlessSeed.Seed.Random.sampleWeighted(random, customerWeights, ~count=1)
      ->Array.get(0)
      ->Option.mapOr("cust-01", c => c.id)
    }
    let productIds =
      ReventlessSeed.Seed.Random.sampleWeighted(random, productWeights, ~count=size)
      ->Array.map(p => p.id)
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
      let (start, end_) =
        deliverySlots
        ->Array.get(mod(i, deliverySlots->Array.length))
        ->Option.getOr(("2026-03-02T09:00:00Z", "2026-03-02T12:00:00Z"))
      Some(Reventless.DateRange.make(~start, ~end_)->Result.getOrThrow)
    }
    {id: `ord-${pad(i + 1, 3)}`, customerId, productIds, shippingMethod, deliveryWindow}
  })
}

/** The warehouse batch run: Standard orders are not the automation's business,
    so they sit in Placed until something dispatches them. Most are shipped;
    the rest stay Placed. */
let batchDispatched = (orders: array<order>): array<order> =>
  orders
  ->Array.filter(o => o.shippingMethod == Standard)
  ->Array.filterWithIndex((_, i) => mod(i, 5) != 0)

/** Cancellations are drawn only from orders still in Placed — Standard orders
    the batch skipped, and Pickup orders, which never ship. An Express order is
    already Shipped and could not be cancelled. */
let cancellable = (orders: array<order>, ~dispatched: array<string>): array<order> =>
  orders->Array.filter(o =>
    o.shippingMethod != Express && !(dispatched->Array.includes(o.id))
  )

let cancelled = (orders: array<order>): array<order> =>
  orders->Array.filterWithIndex((_, i) => mod(i, 3) == 1)
