/***
The shop's own drawing, for the regions a hint can only point at.

A slot renderer draws one named region *inside* a standard view mode. The mode
keeps everything it owns — paging, the window sentence, the action offers, the
drill target, the live-update path — and this replaces what is drawn inside the
region. Every slot is optional: register none and the mode draws its own.

Every renderer here obeys the one rule that makes the seam safe: **it draws what
it was handed and reads nothing else.** No queries, no command names, no routes.
`openRow`, `actions`, the pictures and the lifecycle steps all arrive already
resolved against this deployment's declarations, the caller's permissions and
the row's own state — a renderer that re-derived any of them would get them
wrong the first time a rule, an asset origin or a transition changed.

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
  .sf-media-more { display: flex; gap: .5rem; flex-wrap: wrap; }
  .sf-media-thumb { width: 4.5rem; height: 4.5rem; object-fit: cover;
    border-radius: 8px; }

  /* The strip runs left to right and the connector is drawn on each node after
     the first, reaching back to the one before it — so it colours with the node
     it leads into and no separate element has to be kept in step. */
  .sf-steps { display: flex; align-items: flex-start; gap: 0;
    list-style: none; margin: 0; padding: 0; }
  .sf-step { position: relative; flex: 1 1 0; min-width: 0; display: flex;
    flex-direction: column; align-items: center; gap: .35rem; }
  .sf-step + .sf-step::before { content: ""; position: absolute; z-index: 0;
    top: .45rem; right: 50%; left: -50%; height: 2px; background: #d6d6dc; }
  .sf-step-dot { position: relative; z-index: 1; box-sizing: border-box;
    width: 1rem; height: 1rem; border-radius: 50%; background: #d6d6dc;
    border: 2px solid #fff; }
  .sf-step-label { font-size: .75rem; text-align: center; color: #6b6b76;
    overflow-wrap: anywhere; }
  .sf-step.is-done .sf-step-dot, .sf-step.is-current .sf-step-dot { background: #1b1b1f; }
  .sf-step.is-done::before, .sf-step.is-current::before { background: #1b1b1f; }
  .sf-step.is-current .sf-step-dot { box-shadow: 0 0 0 3px rgba(27,27,31,.18); }
  .sf-step.is-current .sf-step-label { color: #1b1b1f; font-weight: 600; }

  /* A row that ended rather than arrived. Drawn on the line the strip would have
     used, so a list keeps one rhythm whether a row is on its way or done with —
     and as a chip rather than a stop, because a cancelled order is not standing
     anywhere on the path. It sits in a column flex item, so an inline-flex chip
     stretches the whole width of the row unless it says otherwise, and a pill as
     wide as the strip it replaced reads as a bar rather than as a state. */
  .sf-outcome { display: inline-flex; align-items: center; gap: .4rem;
    align-self: flex-start; width: fit-content;
    padding: .15rem .55rem; border-radius: 999px; background: #ececef;
    color: #4a4a52; font-size: .75rem; }
  .sf-outcome::before { content: ""; width: .4rem; height: .4rem;
    border-radius: 50%; background: #9a9aa2; }

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
  .sf-basket-clear { border: 0; background: transparent; color: inherit;
    font: inherit; opacity: .7; text-decoration: underline; cursor: pointer;
    padding: .4rem .5rem; white-space: nowrap; }
  .sf-basket-clear:hover { opacity: 1; }
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
    //
    // Two counts, and they are not the same question. "+ N more" counts the other
    // *lines*, because that is what is not being named; the bare fallback counts
    // `itemCount`, the summed quantity, because a shopper with no name to read
    // counts things rather than lines.
    let lineCount = Slots.Row.array(payload.row, "lines")->Option.map(Array.length)
    let itemCount = Slots.Row.float(payload.row, "itemCount")->Option.map(Float.toInt)
    let items = switch (Slots.Row.text(payload.row, "firstProductName"), lineCount, itemCount) {
    | (Some(name), Some(1), _) => Some(name)
    | (Some(name), Some(n), _) => Some(name ++ " + " ++ Int.toString(n - 1) ++ " more")
    | (Some(name), None, _) => Some(name)
    | (None, _, Some(1)) => Some("1 item")
    | (None, _, Some(n)) => Some(Int.toString(n) ++ " items")
    | (None, _, None) => None
    }
    let summary =
      [
        // A product's own money is its price; an order's is its total. A row
        // carries one or the other, so both are offered and whichever is there
        // is what shows.
        Slots.Row.money(payload.row, "price")->Option.map(Slots.Format.money),
        Slots.Row.money(payload.row, "total")->Option.map(Slots.Format.money),
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

  // The media column of a product's detail page: the whole set, primary first.
  //
  // Every member arrives already rebased for this deployment's asset origins,
  // which is what makes drawing them a renderer's business at all — the row's
  // own `productImages` hold storage *refs*, and turning one into something an
  // `<img>` can load is the producer's job.
  //
  // The captions are still the row's, because only the pictures are resolved.
  // They are paired by position and only when the two line up: a set whose
  // members were filtered on the way out would otherwise caption each picture
  // with its neighbour's words, which reads as correct and is not.
  arg.slots.row(Slots.RowSlot.detailMedia, payload => {
    let images = switch payload.images {
    | Some(images) if Array.length(images) > 0 => images
    | _ => payload.image->Option.mapOr([], image => [image])
    }
    let members = Slots.Row.array(payload.row, "productImages")->Option.getOr([])
    let captionAt = index =>
      Array.length(members) == Array.length(images)
        ? members
          ->Array.get(index)
          ->Option.flatMap(JSON.Decode.object)
          ->Option.flatMap(member => member->Dict.get("caption"))
          ->Option.flatMap(JSON.Decode.string)
          ->Option.flatMap(caption => caption == "" ? None : Some(caption))
        : None

    switch images {
    // No picture at all still says so, rather than leaving the column blank.
    | [] => h("div", {"className": "sf-media"}, [picture(~className="sf-media-img", payload)])
    | _ =>
      let first = images->Array.getUnsafe(0)
      let primary = [
        h(
          "figure",
          Object.make(),
          [
            h("img", {"className": "sf-media-img", "src": first.src, "alt": first.alt}, []),
          ]->Array.concat(
            switch captionAt(0) {
            | Some(caption) => [h("figcaption", Object.make(), [React.string(caption)])]
            | None => []
            },
          ),
        ),
      ]
      // The rest as thumbnails. A caption becomes the tooltip rather than a
      // second line — at this size the words would be wider than the picture.
      let rest = images->Array.slice(~start=1, ~end=Array.length(images))
      let more = Array.length(rest) == 0
        ? []
        : [
            h(
              "div",
              {"className": "sf-media-more"},
              rest->Array.mapWithIndex((image, index) =>
                h(
                  "img",
                  {
                    "className": "sf-media-thumb",
                    "src": image.src,
                    "alt": image.alt,
                    "key": image.src,
                    "title": captionAt(index + 1)->Option.getOr(image.alt),
                  },
                  [],
                )
              ),
            ),
          ]
      h("div", {"className": "sf-media"}, primary->Array.concat(more))
    }
  })

  // An order's progress along its own lifecycle.
  //
  // The steps arrive already ordered and already classified against where this
  // row stands, which is the whole reason this can be drawn: the order comes
  // from the commands' declared transitions, so a state added to the domain
  // appears here on its own. Writing the path out as a list would have drifted
  // the day someone added one, and that is the one thing a tracker exists not
  // to do — so nothing below names a state.
  //
  // An unrecognised `state` reads as upcoming rather than throwing. The strip
  // is a picture of where a row has got to, and a picture that renders one node
  // plainly is better than a region that renders nothing.
  // arg.slots.row(Slots.RowSlot.trackerSteps, payload =>
  //   switch payload.steps {
  //   // A row that LEFT the path has an outcome rather than a position on one, and
  //   // so does a view declaring no ordered lifecycle. Neither has a strip to draw
  //   // — but rendering nothing leaves a cancelled order looking like one still on
  //   // its way with the picture missing, so its own state is drawn as the end of
  //   // the line instead. Read off the row, so this still names no state: what a
  //   // row ended in is the row's to say.
  //   | None | Some([]) =>
  //     switch Slots.Row.text(payload.row, "lifecycle") {
  //     | None => React.null
  //     | Some(state) => h("span", {"className": "sf-outcome"}, [React.string(state)])
  //     }
  //   | Some(steps) =>
  //     h(
  //       "ol",
  //       {"className": "sf-steps"},
  //       steps->Array.map(step => {
  //         let current = step.state == "current"
  //         let stateClass = switch step.state {
  //         | "done" => " is-done"
  //         | "current" => " is-current"
  //         | _ => " is-upcoming"
  //         }
  //         h(
  //           "li",
  //           {
  //             "className": "sf-step" ++ stateClass,
  //             "key": step.key,
  //             "aria-current": current ? "step" : "false",
  //           },
  //           [
  //             h("span", {"className": "sf-step-dot"}, []),
  //             h("span", {"className": "sf-step-label"}, [React.string(step.label)]),
  //           ],
  //         )
  //       }),
  //     )
  //   }
  // )

  // The basket: the rows a shopper picked out of the product grid, and the one
  // command that takes the lot.
  //
  // Drawn from `picked` rather than `selection`. The ids alone would leave this
  // with nothing to say — a list's window is replaced page by page, so a product
  // picked on page 1 is gone from `rows` by page 3, and naming what is in the
  // basket is the whole of this region's job.
  //
  // "Clear" is drawn only where the payload carries one. A region offering no
  // picking is handed none, and a button that cannot work is worse than none.
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
      ->Array.concat(
        switch payload.clear {
        | Some(clear) => [
            h("button", {"className": "sf-basket-clear", "onClick": clear}, [React.string("Clear")]),
          ]
        | None => []
        },
      )
      ->Array.concat([
        h(
          "button",
          {"className": "sf-basket-go", "onClick": payload.run},
          [React.string("Checkout")],
        ),
      ]),
    )
  })

  // The line beside an order's name on the tracker: what is in it and what it
  // cost.
  //
  // Not when it was placed and when it shipped. A step of the strip carries `at`
  // — when the row reached that state — so each date is written over the state it
  // belongs to, where a reader is already looking for it. Printing them again
  // here would say the picture in words and leave this line saying nothing of its
  // own, which is the one thing a summary beside a picture must not do.
  arg.slots.row(Slots.RowSlot.trackerSummary, payload => {
    let items = switch Slots.Row.float(payload.row, "itemCount")->Option.map(Float.toInt) {
    | Some(1) => ["1 item"]
    | Some(n) => [Int.toString(n) ++ " items"]
    | None => []
    }
    let total = Slots.Row.money(payload.row, "total")->Option.mapOr([], m => [Slots.Format.money(m)])
    h(
      "span",
      {"className": "sf-summary"},
      [React.string(items->Array.concat(total)->Array.join(" · "))],
    )
  })
}
