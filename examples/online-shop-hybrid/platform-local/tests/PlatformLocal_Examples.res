@@reventless.examples

let cat1: CatalogPlugin.CategoryId.t = CatalogPlugin.CategoryId.makeFromString("cat1")

let p1: CatalogSpec.ProductId.t = CatalogSpec.ProductId.makeFromString("p1")
let p2: CatalogSpec.ProductId.t = CatalogSpec.ProductId.makeFromString("p2")

let o1: OrderingPlugin.OrderId.t = OrderingPlugin.OrderId.makeFromString("o1")

let c1: OrderingPlugin.CustomerId.t = OrderingPlugin.CustomerId.makeFromString("c1")

let book: string = "Book"
let bookDescription: string = "A good book"
let pen: string = "Pen"

let bookAndThreePensPrice: Reventless.Money.t = Reventless.Money.make(
  ~amount=1449.0,
  ~currency=Reventless.Currency.EUR,
)
let bookPrice: Reventless.Money.t = Reventless.Money.make(
  ~amount=999.0,
  ~currency=Reventless.Currency.EUR,
)
let penPrice: Reventless.Money.t = Reventless.Money.make(
  ~amount=150.0,
  ~currency=Reventless.Currency.EUR,
)
let threePensPrice: Reventless.Money.t = Reventless.Money.make(
  ~amount=450.0,
  ~currency=Reventless.Currency.EUR,
)
let twoBooksPrice: Reventless.Money.t = Reventless.Money.make(
  ~amount=1998.0,
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
