open JestGlobals

// A task bucket's name is emitted into S3, which lowercases it — so the rule
// these guard is that word boundaries have to survive that lowercasing, and that
// the name says which plugin's task owns the bucket. The runtime lookup key
// (`Task.bucketNames`) is a separate string and is deliberately untouched.

module Naming = Task_Builder

describe("kebabCase", () => {
  testSync("splits PascalCase humps", () =>
    expect(Naming.kebabCase("ImportProducts"))->toBe("import-products")
  )

  testSync("splits camelCase humps", () =>
    expect(Naming.kebabCase("productImages"))->toBe("product-images")
  )

  testSync("keeps an acronym together but splits the word after it", () =>
    expect(Naming.kebabCase("HTTPServerLog"))->toBe("http-server-log")
  )

  testSync("normalises kebab and snake input to one shape", () => {
    expect(Naming.kebabCase("product-imports"))->toBe("product-imports")
    expect(Naming.kebabCase("product_imports"))->toBe("product-imports")
  })

  testSync("drops empty segments rather than emitting a double dash", () =>
    expect(Naming.kebabCase("product--imports_"))->toBe("product-imports")
  )

  testSync("is idempotent", () =>
    expect(Naming.kebabCase(Naming.kebabCase("ImportProducts")))->toBe("import-products")
  )
})

describe("bucketResourceName", () => {
  testSync("qualifies a task's default bucket with its plugin", () =>
    expect(Naming.bucketResourceName(~plugin=Some("Catalog"), ~task="ImportProducts", ~bucketId=None))
    ->toBe("catalog-import-products")
  )

  testSync("appends a declared bucket id", () =>
    expect(
      Naming.bucketResourceName(
        ~plugin=Some("Catalog"),
        ~task="ImportProducts",
        ~bucketId=Some("product-imports"),
      ),
    )->toBe("catalog-import-products-product-imports")
  )

  // A task built outside any plugin has no ambient plugin to qualify with; the
  // name stays valid rather than growing an empty leading segment.
  testSync("omits the plugin segment when there is no ambient plugin", () =>
    expect(Naming.bucketResourceName(~plugin=None, ~task="ImportProducts", ~bucketId=None))->toBe(
      "import-products",
    )
  )

  // `aws:s3/bucket` and the `reventless:role=Bucket` tag already say what it is.
  testSync("carries no Bucket suffix", () =>
    expect(
      Naming.bucketResourceName(
        ~plugin=Some("Catalog"),
        ~task="ImportProducts",
        ~bucketId=None,
      )->String.endsWith("bucket"),
    )->toBe(false)
  )

  testSync("fits S3's limit once Pulumi's uniqueness suffix is added", () =>
    expect(
      Naming.bucketResourceName(
        ~plugin=Some("Catalog"),
        ~task="ImportProducts",
        ~bucketId=Some("product-imports"),
      )->String.length <= Naming.maxBucketNameLength,
    )->toBe(true)
  )

  // Truncating would silently collide two long names that share a prefix, so an
  // over-long name is the declaration's to fix and the error has to name it.
  testSync("throws rather than truncating an over-long name", () => {
    let threw = try {
      let _ = Naming.bucketResourceName(
        ~plugin=Some("SomeRatherLongPluginName"),
        ~task="AnEquallyLongRunningTaskName",
        ~bucketId=Some("with-a-verbose-bucket-identifier"),
      )
      false
    } catch {
    | _ => true
    }
    expect(threw)->toBe(true)
  })
})
