@@reventless.examples

let p1: CatalogSpec.ProductId.t = CatalogSpec.ProductId.makeFromString("p1")
let p2: CatalogSpec.ProductId.t = CatalogSpec.ProductId.makeFromString("p2")

let c1: CustomerId.t = CustomerId.makeFromString("c1")
let c2: CustomerId.t = CustomerId.makeFromString("c2")
let id: CustomerId.t = CustomerId.makeFromString("id")

let o1: OrderId.t = OrderId.makeFromString("o1")
let o2: OrderId.t = OrderId.makeFromString("o2")

let aliceEmail: string = "alice@x.y"
let aliceNewEmail: string = "alice2@x.y"
let anyEmail: string = "x@y"
let book: string = "Book"
let campaignRules: string = "campaign-rules"
let cirrusCharger: string = "Cirrus Charger"
let confirmationBody: string = "Thanks — we have your order o1 and will let you know when it ships."
let confirmationSubject: string = "Your order o1 is confirmed"
let confirmReference: string = "confirm:o1"
let contactChange: string = "ContactChange"
let cust1: string = "cust-1"
let customerRef: string = "c1"
let fathomDock: string = "Fathom Dock"
let laptop: string = "Laptop"
let mainStreet: string = "123 Main"
let orderPlacedSource: string = "OrderingDcbEventLog:OrderPlaced"
let orderRef: string = "o1"
let orderSubject: string = "Order"
let secretHash: string = "hash-of-the-secret"
let sesRef: string = "ses-123"
let suppressedReason: string = "address on the suppression list"
let viennaAddress: string = "Stephansplatz 1, Vienna"

let bookPrice: Reventless.Money.t = Reventless.Money.make(
  ~amount=9.99,
  ~currency=Reventless.Currency.EUR,
)

let dockPrice: Reventless.Money.t = Reventless.Money.make(
  ~amount=25.0,
  ~currency=Reventless.Currency.EUR,
)

let laptopChangedPrice: Reventless.Money.t = Reventless.Money.make(
  ~amount=899.99,
  ~currency=Reventless.Currency.EUR,
)

let laptopPrice: Reventless.Money.t = Reventless.Money.make(
  ~amount=999.99,
  ~currency=Reventless.Currency.EUR,
)

let twoBooksPrice: Reventless.Money.t = Reventless.Money.make(
  ~amount=19.98,
  ~currency=Reventless.Currency.EUR,
)

let epoch: Reventless.DateTime.t = "1970-01-01T00:00:00Z"

let placedTime: Reventless.DateTime.t = "2026-03-02T08:00:00Z"

let shippedTime: Reventless.DateTime.t = "2026-03-02T08:30:00Z"
