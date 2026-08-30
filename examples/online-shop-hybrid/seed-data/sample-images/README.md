# Sample images

Two small PNG files for **manually testing the product-image upload flow** — the
seed does not use them; they are here for you to upload by hand.

- `sample-product-a.png` — teal, headphones motif
- `sample-product-b.png` — amber, box motif

They are deliberately distinct from the seeded imagery, so it is obvious when an
upload has replaced a product's image. In a fresh seed the generated catalog
products carry a demo image while the supplier-feed imports carry none (their
`imageUrl` is absent) — the natural targets for a manual upload.

## The upload contract

1. `POST {uploadEndpoint}` with `{fileName, contentType}` → `{uploadUrl, storageRef}`.
2. `PUT {uploadUrl}` with the file bytes.
3. Attach the returned `storageRef` to the product via the `AttachProductImage` command
   (the first attachment becomes the primary; `SetPrimaryProductImage` picks another).

Locally the object store serves the bytes back at `/{prefix}/{key}`; on a deployed
AWS stack the bytes land in S3 and are read back through CloudFront.
