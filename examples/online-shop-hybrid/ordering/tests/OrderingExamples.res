@@reventless.examples

let p1: CatalogSpec.ProductId.t = CatalogSpec.ProductId.makeFromString("p1")
let p2: CatalogSpec.ProductId.t = CatalogSpec.ProductId.makeFromString("p2")

let c1: CustomerId.t = CustomerId.makeFromString("c1")
let id: CustomerId.t = CustomerId.makeFromString("id")

let o1: OrderId.t = OrderId.makeFromString("o1")
let o2: OrderId.t = OrderId.makeFromString("o2")

let aliceEmail: string = "alice@x.y"
let aliceNewEmail: string = "alice2@x.y"
let anyEmail: string = "x@y"
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

let dockPrice: Reventless.Money.t = Reventless.Money.make(
  ~amount=2500.0,
  ~currency=Reventless.Currency.EUR,
)

let laptopChangedPrice: Reventless.Money.t = Reventless.Money.make(
  ~amount=89999.0,
  ~currency=Reventless.Currency.EUR,
)

let laptopPrice: Reventless.Money.t = Reventless.Money.make(
  ~amount=99999.0,
  ~currency=Reventless.Currency.EUR,
)

let epoch: Reventless.DateTime.t = "1970-01-01T00:00:00Z"
