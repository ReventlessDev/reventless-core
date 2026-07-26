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
}

let categories: array<category> = [
  {id: "cat-01", name: "Laptops", weight: 9, nouns: ["Notebook", "Ultrabook", "Workstation"], archive: false},
  {id: "cat-02", name: "Phones", weight: 10, nouns: ["Handset", "Smartphone", "Phone"], archive: false},
  {id: "cat-03", name: "Audio", weight: 9, nouns: ["Headphones", "Earbuds", "Speaker"], archive: false},
  {id: "cat-04", name: "Cameras", weight: 7, nouns: ["Camera", "Lens", "Gimbal"], archive: false},
  {id: "cat-05", name: "Wearables", weight: 7, nouns: ["Watch", "Tracker", "Band"], archive: false},
  {id: "cat-06", name: "Home Office", weight: 8, nouns: ["Desk Lamp", "Monitor", "Keyboard"], archive: false},
  {id: "cat-07", name: "Accessories", weight: 6, nouns: ["Cable", "Adapter", "Case"], archive: false},
  // Archived at the end of the catalog phase — after its products exist, since
  // AddProduct rejects an archived category with CategoryNotFound.
  {id: "cat-08", name: "Clearance", weight: 4, nouns: ["Bundle", "Refurb Kit"], archive: true},
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
// deliberately invalid so the ImportProductAudit view shows both outcomes.
let supplierFeed: array<CatalogPlugin.ImportProduct.externalInput> = [
  {sku: "SKU-4410", title: "Fathom Dock 4-Port", desc: "Supplier-fed docking station.", unitPrice: 8990, currency: "USD", category: "cat-07"},
  {sku: "SKU-4411", title: "Cirrus Travel Charger", desc: "Supplier-fed 65W charger.", unitPrice: 4550, currency: "USD", category: "cat-07"},
  {sku: "SKU-4412", title: "Granite Laptop Sleeve", desc: "Supplier-fed protective sleeve.", unitPrice: 3200, currency: "USD", category: "cat-07"},
  {sku: "SKU-4413", title: "Halcyon Desk Riser", desc: "Supplier-fed monitor riser.", unitPrice: 12400, currency: "USD", category: "cat-06"},
  {sku: "SKU-4414", title: "Ember Cable Set", desc: "Rejected: non-USD supplier row.", unitPrice: 1900, currency: "EUR", category: "cat-07"},
]

let importedSkus =
  supplierFeed->Array.filter(row => row.currency == "USD")->Array.map(row => row.sku)

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

type product = {
  id: string,
  name: string,
  description: string,
  price: float,
  imageUrl: string,
  categoryId: string,
}

// A deterministic placeholder image per product: a distinct fill colour derived
// from the product index plus the product name as a label. SVG is tiny,
// text-based (no repo binaries, no third-party service), renders in `<img>`, and
// serves cleanly through both the AWS CloudFront read path and the local dev
// serve route. Uploaded at seed time (DemoSeed) so each product's `imageUrl`
// travels the real upload → store → serve loop instead of an external URL. The
// Image semantic thumbnails the served ref in the generated Products view.
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

let buildProducts = (): array<product> => {
  // Category share proportional to weight, so the catalog is lopsided the way a
  // real one is rather than eight even buckets.
  let totalWeight = categories->Array.reduce(0, (sum, c) => sum + c.weight)
  let products = []
  let n = ref(0)
  categories->Array.forEach(category => {
    let exact =
      Int.toFloat(category.weight) /. Int.toFloat(totalWeight) *. Int.toFloat(productCount)
    let share = Math.round(exact)->Int.fromFloat
    let share = share < 2 ? 2 : share
    for _ in 1 to share {
      if products->Array.length < productCount {
        n := n.contents + 1
        let qualifier = pick(qualifiers)
        let suffix = qualifier == "" ? "" : ` ${qualifier}`
        let name = `${pick(brands)} ${pick(category.nouns)}${suffix}`
        // Log-uniform over ~5..900 so the price axis has a long right tail
        // instead of clustering in the middle of a linear range.
        let low = Math.log(5.0)
        let high = Math.log(900.0)
        let raw = Math.exp(low +. ReventlessSeed.Seed.Random.float(random) *. (high -. low))
        let price = Math.round(raw *. 100.0) /. 100.0
        products->Array.push({
          id: `prd-${pad(n.contents, 3)}`,
          name,
          description: `${name} — ${pick(blurbs)} ${category.name->String.toLowerCase} pick.`,
          price,
          // Filled by DemoSeed's upload phase with the served `/{prefix}/{key}`
          // ref once the product's placeholder SVG is uploaded.
          imageUrl: "",
          categoryId: category.id,
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

let discountedPrice = (p: product): float => Math.round(p.price *. 0.85 *. 100.0) /. 100.0

// ── Customers ───────────────────────────────────────────────────────────────

type customer = {
  id: string,
  email: string,
  address: string,
  lat: float,
  lng: float,
}

let buildCustomers = (): array<customer> =>
  Array.fromInitializer(~length=customerCount, i => {
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
}

let buildOrders = (products: array<product>, customers: array<customer>): array<order> => {
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

  Array.fromInitializer(~length=orderCount, i => {
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
    let customerId =
      ReventlessSeed.Seed.Random.sampleWeighted(random, customerWeights, ~count=1)
      ->Array.get(0)
      ->Option.mapOr("cust-01", c => c.id)
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
    {id: `ord-${pad(i + 1, 3)}`, customerId, productIds, shippingMethod}
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
