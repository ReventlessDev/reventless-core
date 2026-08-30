// The file-attachment trait's conformance suite, bound to `CategoryImages` — the
// second host, which is what makes the trait's rules a contract rather than a
// description of one slice.

module Binding = {
  type ref = string
  let refA = "/uploads/cat/c1.svg"
  let refB = "/uploads/cat/c1-banner.svg"

  module Spec = CategoryImages
  module Behavior = CategoryImages_Behavior

  // Annotated: the slice consumes and emits same-named constructors.
  let created: array<CategoryImages.consumedEvent> = [CategoryAdded]
  let attachedC = (ref): CategoryImages.consumedEvent => CategoryImageAttached({categoryImage: ref})
  let removedC = (ref): CategoryImages.consumedEvent => CategoryImageRemoved({categoryImage: ref})
  let primarySetC = (ref): CategoryImages.consumedEvent =>
    CategoryPrimaryImageSet({categoryImage: ref})
  let altTextSetC = (ref, altText): CategoryImages.consumedEvent =>
    CategoryImageAltTextSet({categoryImage: ref, altText})

  let attach = ref => CategoryImages.AttachCategoryImage({categoryId: "c1", categoryImage: ref})
  let remove = ref => CategoryImages.RemoveCategoryImage({categoryId: "c1", categoryImage: ref})
  let setPrimary = ref =>
    CategoryImages.SetPrimaryCategoryImage({categoryId: "c1", categoryImage: ref})
  let setAltText = (ref, altText) =>
    CategoryImages.SetCategoryImageAltText({categoryId: "c1", categoryImage: ref, altText})

  let attached = ref => CategoryImages.CategoryImageAttached({categoryId: "c1", categoryImage: ref})
  let removed = ref => CategoryImages.CategoryImageRemoved({categoryId: "c1", categoryImage: ref})
  let primarySet = ref =>
    CategoryImages.CategoryPrimaryImageSet({categoryId: "c1", categoryImage: ref})
  let altTextSet = (ref, altText) =>
    CategoryImages.CategoryImageAltTextSet({categoryId: "c1", categoryImage: ref, altText})
  let notAttached = CategoryImages.CategoryImageNotAttached
}

module Conformance = TraitFileAttachment.FileAttachment_Conformance.Make(Binding)

Conformance.register()
