@@reventless.examples

let c1: CategoryId.t = CategoryId.makeFromString("c1")
let cat1: CategoryId.t = CategoryId.makeFromString("cat1")

let p1: CatalogSpec.ProductId.t = CatalogSpec.ProductId.makeFromString("p1")
let p2: CatalogSpec.ProductId.t = CatalogSpec.ProductId.makeFromString("p2")

let anyDescription: string = "x"
let bannerAlt: string = "banner"
let categoryRef: string = "cat1"
let consumerElectronics: string = "Consumer Electronics"
let electronics: string = "Electronics"
let frontAlt: string = "front"
let gamingLaptop: string = "Gaming Laptop"
let highEnd: string = "high-end"
let highEndLaptop: string = "high-end laptop"
let laptop: string = "Laptop"
let laptopDescription: string = "A laptop"
let order1: string = "order-1"
let order2: string = "order-2"
let sideImageRef: string = "/uploads/9c1f2a30-0b7e-4a11-9d33-6f0d2e5a8b41/p1-side.jpg"
let sku: string = "p-1"
let usd: string = "USD"

let categoryImage: Reventless.UploadableImage.t = "/uploads/cat/c1.svg"
let frontImage: Reventless.UploadableImage.t = "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg"
let sideImage: Reventless.UploadableImage.t = "/uploads/9c1f2a30-0b7e-4a11-9d33-6f0d2e5a8b41/p1-side.jpg"

let buchPrice: Reventless.Money.t = Reventless.Money.make(
  ~amount=1999.0,
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
