// The attachments trait's conformance suite, bound to `ProductImages`.

module Binding = {
  type ref = string
  let refA = "/uploads/3e7b41c8-5a2d-4f60-8c19-77b0d4e6a912/p1.jpg"
  let refB = "/uploads/9c1f2a30-0b7e-4a11-9d33-6f0d2e5a8b41/p1-side.jpg"

  module Spec = ProductImages
  module Behavior = ProductImages_Behavior

  // Annotated: the slice consumes and emits same-named constructors.
  let created: array<ProductImages.consumedEvent> = [ProductAdded]
  let attachedC = (ref): ProductImages.consumedEvent => ProductImageAttached({productImage: ref})
  let removedC = (ref): ProductImages.consumedEvent => ProductImageRemoved({productImage: ref})
  let primarySetC = (ref): ProductImages.consumedEvent =>
    ProductPrimaryImageSet({productImage: ref})
  let altTextSetC = (ref, altText): ProductImages.consumedEvent =>
    ProductImageAltTextSet({productImage: ref, altText})

  let attach = ref => ProductImages.AttachProductImage({productId: "p1", productImage: ref})
  let remove = ref => ProductImages.RemoveProductImage({productId: "p1", productImage: ref})
  let setPrimary = ref => ProductImages.SetPrimaryProductImage({productId: "p1", productImage: ref})
  let setAltText = (ref, altText) =>
    ProductImages.SetProductImageAltText({productId: "p1", productImage: ref, altText})

  let attached = ref => ProductImages.ProductImageAttached({productId: "p1", productImage: ref})
  let removed = ref => ProductImages.ProductImageRemoved({productId: "p1", productImage: ref})
  let primarySet = ref => ProductImages.ProductPrimaryImageSet({productId: "p1", productImage: ref})
  let altTextSet = (ref, altText) =>
    ProductImages.ProductImageAltTextSet({productId: "p1", productImage: ref, altText})
  let notAttached = ProductImages.ProductImageNotAttached
}

module Conformance = TraitAttachments.Attachments_Conformance.Make(Binding)

Conformance.register()
