/***
The shop's own drawing, for the regions a hint can only point at.

A slot renderer draws one named region *inside* a standard view mode. The mode
keeps everything it owns — paging, the window sentence, the action offers, the
drill target, the live-update path — and this replaces what is drawn inside the
region. Every slot is optional: register none and the mode draws its own.

Every renderer here obeys the one rule that makes the seam safe: **it draws what
it was handed and reads nothing else.** No queries, no command names, no routes.
`openRow` and `actions` arrive already resolved against this deployment's
declarations, the caller's permissions and the row's lifecycle — a renderer that
re-derived any of them would get them wrong the first time a rule changed.

Which views these draw is not decided here. A region is offered by a *mode*, so
`ui-hints.json` deciding a view opens as a gallery is what puts a tile on the
screen — which is why an audience block choosing a different mode redraws the
same view for a different role without touching this file.

## How this is built

`ReventlessSlots` is the published contract, so the payload shapes and the slot
ids come from the package that defines them rather than being described again
here — a mistyped `gallery.tile` is a compile error, not a console warning
nobody reads. Its helpers carry everything that is not this shop's own decision:
reading a field out of the row's JSON, scaling money by what its currency
actually uses, the title precedence, and putting a stylesheet in the page once.
What is left below is the drawing, which is the only part that belongs to a
deployment.

Elements go through `ReventlessSlots.h`, which is the **shell's own**
`React.createElement`, handed over as an argument. That is the one thing worth
being careful about: React is what a slot module must not bring a second copy
of, because a foreign copy renders fine right until a hook lands on the wrong
dispatcher. Built through `h`, this module never imports `react` at all. JSX
would, so there is none here.

The compiled output imports `@rescript/runtime` and the contract package, which a
browser cannot resolve from a served file, so `scripts/bundle-slot-modules.mjs`
bundles it to one file and *that* is what the deployment declares.
`check:slots` fails the build if a bare specifier ever survives into the bundle —
including `react`, which would mean the second copy.
*/

module Slots = ReventlessSlots

// ── The shop's own tokens ───────────────────────────────────────────────────

let styles = `
  .sf-tile { position: relative; display: block; width: 100%; padding: 0;
    border: 0; border-radius: 12px; overflow: hidden; cursor: pointer;
    background: #1b1b1f; aspect-ratio: 4 / 3; }
  .sf-tile-img { width: 100%; height: 100%; object-fit: cover; display: block; }
  .sf-tile figcaption { position: absolute; inset: auto 0 0 0;
    padding: 1.5rem .75rem .6rem; font-size: 1rem; font-weight: 600; color: #fff;
    text-align: left; background: linear-gradient(to top, rgba(0,0,0,.72), transparent); }

  .sf-face { display: flex; flex-direction: column; gap: .5rem; height: 100%; }
  .sf-face-img { width: 100%; aspect-ratio: 1 / 1; object-fit: cover;
    border-radius: 10px; background: #f2f2f4; }
  .sf-face-name { font-weight: 600; line-height: 1.3; }
  .sf-face-price { font-variant-numeric: tabular-nums; opacity: .75; }
  .sf-face-actions { margin-top: auto; display: flex; gap: .5rem; flex-wrap: wrap; }

  .sf-media { display: grid; gap: .5rem; }
  .sf-media-img { width: 100%; border-radius: 12px; object-fit: cover;
    aspect-ratio: 1 / 1; }
  .sf-media figcaption { font-size: .8rem; opacity: .7; }

  /* "This row has no picture", which is a different statement from a broken
     image — and the one a half-entered catalogue should be making. Dashed so it
     reads as a placeholder rather than as content. */
  .sf-noimg { display: flex; align-items: center; justify-content: center;
    background: repeating-linear-gradient(45deg, #f4f4f5, #f4f4f5 8px, #ececef 8px, #ececef 16px);
    border: 1px dashed #c9c9cf; color: #6b6b76; font-size: .75rem;
    letter-spacing: .02em; }
  .sf-tile .sf-noimg { border: 0; }

  .sf-summary { font-size: .8rem; opacity: .7; font-variant-numeric: tabular-nums; }

  .sf-basket { display: flex; align-items: center; gap: .75rem; flex-wrap: wrap;
    padding: .6rem .9rem; margin-bottom: .75rem; border-radius: 12px;
    background: #1b1b1f; color: #fff; }
  .sf-basket-count { font-weight: 600; white-space: nowrap; }
  /* The names take the slack and the buttons keep their size, so a basket of
     twelve does not push checkout off the end of the bar. */
  .sf-basket-items { flex: 1 1 auto; min-width: 0; opacity: .8; font-size: .85rem;
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .sf-basket-total { font-variant-numeric: tabular-nums; font-weight: 600;
    white-space: nowrap; }
  .sf-basket-go { border: 0; border-radius: 999px; padding: .4rem 1.1rem;
    background: #fff; color: #1b1b1f; font-weight: 600; cursor: pointer; }
`

// ── The renderers ───────────────────────────────────────────────────────────

let register = (arg: Slots.registerArg): unit => {
  // From `register` rather than module scope, so importing this module has no
  // side effect. `sf-` prefixes so nothing here collides with the shell's own
  // class names; the id is what stops a hot reload appending the rules twice.
  Slots.ensureStyles(~id="storefront-slots", styles)

  let h = (tag, props, children) => Slots.h(arg.h, tag, props, children)

  // The picture, or a panel that says there isn't one.
  //
  // An `<img>` with an empty `src` is a broken-image icon in every browser, and
  // that reads as a deployment that is broken rather than a row that has no
  // picture. A view whose rows mostly lack images — a shop mid-catalogue-entry —
  // would otherwise look like a fault.
  let picture = (~className: string, payload: Slots.rowPayload) =>
    switch payload.image {
    | Some(image) => h("img", {"className": className, "src": image.src, "alt": image.alt}, [])
    | None =>
      h(
        "div",
        {"className": className ++ " sf-noimg", "role": "img", "aria-label": "No image"},
        [h("span", Object.make(), [React.string("No image")])],
      )
    }

  // A category, as a picture with its name over it. Drawn wherever a view opens
  // as a gallery — in this shop, Categories.
  arg.slots.row(Slots.RowSlot.galleryTile, payload =>
    h(
      "figure",
      {"className": "sf-tile", "onClick": payload.openRow, "role": "button"},
      [
        picture(~className="sf-tile-img", payload),
        h("figcaption", Object.make(), [React.string(Slots.titleOf(payload))]),
      ],
    )
  )

  // A card face: the picture, a heading, and the one line of summary the row can
  // honestly offer.
  //
  // **Written against the row, not against Products.** A slot id is registered
  // once and drawn by every view that opens in that mode, so this face is what
  // Orders gets the moment a caller switches to Cards — and a face that assumed
  // a product showed an order a broken picture and a uuid. What it draws is
  // whatever the row turns out to carry.
  //
  // Actions are deliberately absent: the mode draws the action row underneath
  // the face, so rendering them here shows every offer twice.
  arg.slots.row(Slots.RowSlot.cardsFace, payload => {
    // An order has no name of its own, so its label falls back to its id. A uuid
    // is not a heading; when it was placed is the thing a person recognises.
    let heading = switch Slots.Row.text(payload.row, "placedAt") {
    | Some(at) => Slots.Format.isoDay(at)
    | None => Slots.titleOf(payload)
    }
    // What the row can say about itself: a product says its price, an order says
    // what was bought and how much of it. `firstProductName` is the name the
    // order *recorded* at placement, not the catalog's current one — so an order
    // still reads correctly after the product is renamed or withdrawn.
    let items = Slots.Row.array(payload.row, "productIds")->Option.map(ids =>
      switch (Slots.Row.text(payload.row, "firstProductName"), Array.length(ids)) {
      | (Some(name), 1) => name
      | (Some(name), n) => name ++ " + " ++ Int.toString(n - 1) ++ " more"
      | (None, 1) => "1 item"
      | (None, n) => Int.toString(n) ++ " items"
      }
    )
    let summary =
      [
        Slots.Row.money(payload.row, "price")->Option.map(Slots.Format.money),
        items,
      ]->Array.filterMap(line => line)
    h(
      "div",
      {"className": "sf-face"},
      [
        picture(~className="sf-face-img", payload),
        h("div", {"className": "sf-face-name"}, [React.string(heading)]),
        h("div", {"className": "sf-face-price"}, [React.string(summary->Array.join(" · "))]),
      ],
    )
  })

  // The media column of a product's detail page.
  //
  // **Only the primary picture, and that is not an oversight.** The row carries
  // the whole set in `productImages`, but each member holds a storage *ref* —
  // not a URL. Turning one into something an `<img>` can load means rebasing it
  // against this deployment's asset origins, which is the producer's job and
  // exactly the kind of reaching-past-the-payload that makes a renderer break
  // the first time the origins change. `image` is the one the view already
  // resolved, so it is the one that can honestly be drawn.
  //
  // Drawing the rest needs the payload to carry them resolved. That is a change
  // to the slot contract, not something to work around here.
  arg.slots.row(Slots.RowSlot.detailMedia, payload => {
    let caption = switch Slots.Row.firstAttachment(payload.row, "productImages") {
    | Some((_altText, Some(caption))) => [h("figcaption", Object.make(), [React.string(caption)])]
    | Some(_) | None => []
    }
    h(
      "div",
      {"className": "sf-media"},
      [picture(~className="sf-media-img", payload)]->Array.concat(caption),
    )
  })

  // The line beside an order's name on the tracker: when it was placed, and when
  // it shipped once it has.
  //
  // **`trackerSteps` is deliberately not registered**, though it is the slot this
  // file most obviously wants. The strip's steps come from the lifecycle's
  // *declared transitions* — the same graph the Lifecycles page reads — and the
  // payload does not carry them. Drawing the strip here would mean writing the
  // path out as a list, which drifts silently the day a transition is added and
  // is the one thing the tracker exists to avoid. The mode already draws it
  // correctly; leaving it alone is the point of a slot.
  // The basket: the rows a shopper picked out of the product grid, and the one
  // command that takes the lot.
  //
  // Drawn from `picked` rather than `selection`. The ids alone would leave this
  // with nothing to say — a list's window is replaced page by page, so a product
  // picked on page 1 is gone from `rows` by page 3, and naming what is in the
  // basket is the whole of this region's job.
  //
  // **No "Clear".** The payload carries no way to empty the selection — the
  // shipped bar is handed one, a slot is not. Rows can still be unpicked one at
  // a time from their checkboxes, so nothing is unreachable; drawing a button
  // that cannot work would be worse. Like the tracker strip below, this wants a
  // payload change rather than a workaround here.
  arg.slots.view(Slots.ViewSlot.listSelection, payload => {
    let picked = payload.picked->Option.getOr([])
    let prices = picked->Array.filterMap(p => Slots.Row.money(p.row, "price"))
    // A total only where one can be told truthfully. This catalogue prices in
    // more than one currency, so adding the numbers would produce a figure in no
    // currency at all. Shown when every picked row carries a price and they all
    // agree on the currency; omitted otherwise, rather than quietly summing
    // dollars into euros.
    let total = if Array.length(prices) != Array.length(picked) || Array.length(prices) == 0 {
      []
    } else {
      let (_, currency) = prices->Array.getUnsafe(0)
      if prices->Array.every(((_, c)) => c == currency) {
        [
          h(
            "span",
            {"className": "sf-basket-total"},
            [
              React.string(
                Slots.Format.money((
                  prices->Array.reduce(0.0, (sum, (amount, _)) => sum +. amount),
                  currency,
                )),
              ),
            ],
          ),
        ]
      } else {
        []
      }
    }
    h(
      "div",
      {"className": "sf-basket"},
      [
        h(
          "span",
          {"className": "sf-basket-count"},
          [React.string(Int.toString(Array.length(picked)) ++ " in basket")],
        ),
        h(
          "span",
          {"className": "sf-basket-items"},
          [React.string(picked->Array.map(Slots.titleOf)->Array.join(" · "))],
        ),
      ]
      ->Array.concat(total)
      ->Array.concat([
        h(
          "button",
          {"className": "sf-basket-go", "onClick": payload.run},
          [React.string("Checkout")],
        ),
      ]),
    )
  })

  arg.slots.row(Slots.RowSlot.trackerSummary, payload => {
    let placed = Slots.Row.text(payload.row, "placedAt")->Option.mapOr([], at => ["Placed " ++ Slots.Format.isoDay(at)])
    let shipped = Slots.Row.text(payload.row, "shippedAt")->Option.mapOr([], at => ["shipped " ++ Slots.Format.isoDay(at)])
    h(
      "span",
      {"className": "sf-summary"},
      [React.string(placed->Array.concat(shipped)->Array.join(" · "))],
    )
  })
}
