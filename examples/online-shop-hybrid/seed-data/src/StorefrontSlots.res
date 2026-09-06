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
  .sf-tile img { width: 100%; height: 100%; object-fit: cover; display: block; }
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
  .sf-media img { width: 100%; border-radius: 12px; object-fit: cover; }
  .sf-media figcaption { font-size: .8rem; opacity: .7; }

  .sf-summary { font-size: .8rem; opacity: .7; font-variant-numeric: tabular-nums; }
`

// ── The renderers ───────────────────────────────────────────────────────────

let register = (arg: Slots.registerArg): unit => {
  // From `register` rather than module scope, so importing this module has no
  // side effect. `sf-` prefixes so nothing here collides with the shell's own
  // class names; the id is what stops a hot reload appending the rules twice.
  Slots.ensureStyles(~id="storefront-slots", styles)

  let h = (tag, props, children) => Slots.h(arg.h, tag, props, children)

  // A category, as a picture with its name over it. Drawn wherever a view opens
  // as a gallery — in this shop, Categories.
  arg.slots.row(Slots.RowSlot.galleryTile, payload => {
    let picture = switch payload.image {
    | Some(image) => [h("img", {"src": image.src, "alt": image.alt}, [])]
    | None => []
    }
    h(
      "figure",
      {"className": "sf-tile", "onClick": payload.openRow, "role": "button"},
      picture->Array.concat([
        h("figcaption", Object.make(), [React.string(Slots.titleOf(payload))]),
      ]),
    )
  })

  // A product's card face: the picture, the name, the price, and whatever this
  // caller may actually start from here. `actions` is already filtered — an
  // empty list means this caller has nothing to offer on this row, not that the
  // shop has no commands.
  arg.slots.row(Slots.RowSlot.cardsFace, payload => {
    let src = payload.image->Option.mapOr("", image => image.src)
    let alt = payload.image->Option.mapOr("", image => image.alt)
    let price = Slots.Row.money(payload.row, "price")->Option.mapOr("", Slots.Format.money)
    h(
      "div",
      {"className": "sf-face"},
      [
        h("img", {"className": "sf-face-img", "src": src, "alt": alt}, []),
        h("div", {"className": "sf-face-name"}, [React.string(Slots.titleOf(payload))]),
        h("div", {"className": "sf-face-price"}, [React.string(price)]),
        h(
          "div",
          {"className": "sf-face-actions"},
          payload.actions
          ->Option.getOr([])
          ->Array.map(action =>
            h("button", {"key": action.label, "onClick": action.run}, [React.string(action.label)])
          ),
        ),
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
  arg.slots.row(Slots.RowSlot.detailMedia, payload =>
    switch payload.image {
    | None => h("div", {"className": "sf-media"}, [])
    | Some(image) =>
      let caption = switch Slots.Row.firstAttachment(payload.row, "productImages") {
      | Some((_altText, Some(caption))) =>
        [h("figcaption", Object.make(), [React.string(caption)])]
      | Some(_) | None => []
      }
      h(
        "div",
        {"className": "sf-media"},
        [h("img", {"src": image.src, "alt": image.alt}, [])]->Array.concat(caption),
      )
    }
  )

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
  arg.slots.row(Slots.RowSlot.trackerSummary, payload => {
    let placed = Slots.Row.text(payload.row, "placedAt")->Option.mapOr([], at => ["Placed " ++ Slots.Format.day(at)])
    let shipped = Slots.Row.text(payload.row, "shippedAt")->Option.mapOr([], at => ["shipped " ++ Slots.Format.day(at)])
    h(
      "span",
      {"className": "sf-summary"},
      [React.string(placed->Array.concat(shipped)->Array.join(" · "))],
    )
  })
}
