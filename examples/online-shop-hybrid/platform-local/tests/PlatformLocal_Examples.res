@@reventless.examples

let cat1: CatalogPlugin.CategoryId.t = CatalogPlugin.CategoryId.makeFromString("cat1")

let p1: CatalogSpec.ProductId.t = CatalogSpec.ProductId.makeFromString("p1")
let p2: CatalogSpec.ProductId.t = CatalogSpec.ProductId.makeFromString("p2")

let o1: OrderingPlugin.OrderId.t = OrderingPlugin.OrderId.makeFromString("o1")

let c1: OrderingPlugin.CustomerId.t = OrderingPlugin.CustomerId.makeFromString("c1")

let book: string = "Book"
let bookDescription: string = "A good book"
let confirmationBody: string = "Thanks — we have your order o1 and will let you know when it ships."
let confirmationSubject: string = "Your order o1 is confirmed"
let confirmReference: string = "confirm:o1"
let customerRef: string = "c1"
let orderPlacedSource: string = "OrderingDcbEventLog:OrderPlaced"
let orderRef: string = "o1"
let orderSubject: string = "Order"
let pen: string = "Pen"

let bookAndThreePensPrice: Reventless.Money.t = Reventless.Money.make(
  ~amount=14.49,
  ~currency=Reventless.Currency.EUR,
)
let bookPrice: Reventless.Money.t = Reventless.Money.make(
  ~amount=9.99,
  ~currency=Reventless.Currency.EUR,
)
let penPrice: Reventless.Money.t = Reventless.Money.make(
  ~amount=1.5,
  ~currency=Reventless.Currency.EUR,
)
let threePensPrice: Reventless.Money.t = Reventless.Money.make(
  ~amount=4.5,
  ~currency=Reventless.Currency.EUR,
)
let twoBooksPrice: Reventless.Money.t = Reventless.Money.make(
  ~amount=19.98,
  ~currency=Reventless.Currency.EUR,
)

let oneBookLine: OrderingPlugin.PlaceOrder.orderLine = {
  productId: p1,
  name: book,
  quantity: 1,
  unitPrice: bookPrice,
  lineTotal: bookPrice,
}
let threePensLine: OrderingPlugin.PlaceOrder.orderLine = {
  productId: p2,
  name: pen,
  quantity: 3,
  unitPrice: penPrice,
  lineTotal: threePensPrice,
}
let twoBooksLine: OrderingPlugin.PlaceOrder.orderLine = {
  productId: p1,
  name: book,
  quantity: 2,
  unitPrice: bookPrice,
  lineTotal: twoBooksPrice,
}
