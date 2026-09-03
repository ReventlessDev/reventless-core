// The attachments trait's conformance suite, bound to `CategoryImages` — the
// second host, which is what makes the trait's rules a contract rather than a
// description of one slice. It is also the bounded host, so the suite it binds
// is the smaller one: what the larger suite asserts about choosing between
// members is not skipped here, it is unreachable, because `SingleBinding` does
// not admit the commands that would reach it.

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
  let altTextSetC = (ref, altText): CategoryImages.consumedEvent =>
    CategoryImageAltTextSet({categoryImage: ref, altText})

  let attach = ref => CategoryImages.SetCategoryImage({categoryId: "c1", categoryImage: ref})
  let clear = CategoryImages.RemoveCategoryImage({categoryId: "c1"})
  let setAltText = altText => CategoryImages.SetCategoryImageAltText({categoryId: "c1", altText})

  let attached = ref => CategoryImages.CategoryImageAttached({categoryId: "c1", categoryImage: ref})
  let removed = ref => CategoryImages.CategoryImageRemoved({categoryId: "c1", categoryImage: ref})
  let altTextSet = (ref, altText) =>
    CategoryImages.CategoryImageAltTextSet({categoryId: "c1", categoryImage: ref, altText})
  let notAttached = CategoryImages.CategoryImageNotAttached
}

module Conformance = TraitAttachments.Attachments_Conformance.MakeSingle(Binding)

Conformance.register()
