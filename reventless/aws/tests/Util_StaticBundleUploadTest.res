open Jest
open Expect

describe("Util_StaticBundleUpload.staleKeys", () => {
  test("deletes a key only once two deploys have not named it", () =>
    expect(
      Util_StaticBundleUpload.staleKeys(
        ~current=["index.html", "assets/c.js"],
        ~previous=["index.html", "assets/b.js"],
        ~beforePrevious=["index.html", "assets/a.js", "assets/b.js"],
      ),
    )->toEqual(["assets/a.js"])
  )

  test("keeps a key that came back after a deploy without it", () =>
    expect(
      Util_StaticBundleUpload.staleKeys(
        ~current=["assets/a.js"],
        ~previous=["assets/b.js"],
        ~beforePrevious=["assets/a.js"],
      ),
    )->toEqual([])
  )

  test("deletes nothing on the first two deploys", () =>
    expect(
      Util_StaticBundleUpload.staleKeys(~current=["a"], ~previous=[], ~beforePrevious=[]),
    )->toEqual([])
  )
})
