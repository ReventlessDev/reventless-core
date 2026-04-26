// Self-test for spec-first-migrate.mjs.
//
// Exercises splitSource() across all 5 slice kinds with hand-crafted fixtures
// and verifies:
//   - each binding lands in the correct file (Spec vs Implementation)
//   - the implementation file gets the right `@@reventless.<kind>` annotation
//   - the spec file keeps `@@reventless.spec` and the file-header comments
//   - re-splitting the SAME input is byte-stable (idempotence on input)
//   - re-merging the two halves and re-splitting produces byte-stable output
//     (round-trip stability)
//
// Run: `node scripts/spec-first-migrate/spec-first-migrate.test.mjs`
// Exits non-zero on first failure.

import { splitSource, SLICE_KINDS } from './spec-first-migrate.mjs';
import { strict as assert } from 'node:assert';

let passed = 0;
let failed = 0;

function test(name, fn) {
  try {
    fn();
    process.stdout.write(`  ok  ${name}\n`);
    passed++;
  } catch (e) {
    process.stdout.write(`  FAIL ${name}\n`);
    process.stdout.write(`       ${e.message.replaceAll('\n', '\n       ')}\n`);
    failed++;
  }
}

function describe(name, fn) {
  process.stdout.write(`${name}\n`);
  fn();
}

// ----- Fixtures: minimal merged-form sources for each slice kind -----

const FIXTURES = {
  StateChangeSlice: `// AddCategory StateChangeSlice.
// Adds a new category iff one doesn't already exist.
@@reventless.spec

type state = {exists: bool}

let initialState = {exists: false}

@schema
type consumedEvent =
  | CategoryAdded

let evolve = (_state, event) =>
  switch event {
  | CategoryAdded => {exists: true}
  }

@schema
type command = AddCategory({categoryId: string, name: string})

@schema
type error = CategoryAlreadyExists

@schema
type event = CategoryAdded({categoryId: string, name: string})

let decide = (state, command) =>
  switch command {
  | AddCategory({categoryId, name}) =>
    if state.exists {
      Error(CategoryAlreadyExists)
    } else {
      Ok([CategoryAdded({categoryId, name})])
    }
  }
`,

  StateViewSlice: `// CategoriesView StateViewSlice.
@@reventless.spec

@schema
type state = {categoryId: string, name: string}

@schema
type consumedEvent =
  | CategoryAdded({categoryId: string, name: string})

let project = event =>
  switch event {
  | CategoryAdded({categoryId, name}) => [Set(categoryId, {categoryId, name})]
  }
`,

  AutomationSlice: `// AutoShipOrder AutomationSlice.
@@reventless.spec

@schema
type consumedEvent =
  | OrderPlaced({orderId: string})
  | OrderShipped({orderId: string})

@schema
type todoItem = {orderId: string}

@schema
type command = ShipOrder({orderId: string})

let collect = event =>
  switch event {
  | OrderPlaced({orderId}) => [(orderId, {orderId: orderId})]
  | OrderShipped(_) => []
  }

let resolve = event =>
  switch event {
  | OrderShipped({orderId}) => Some(orderId)
  | OrderPlaced(_) => None
  }

let process = (id, _item) => Some((id, ShipOrder({orderId: id})))

let maxRetries = 3
let heartbeatInterval = 60
let targetName = "ShipOrder"
`,

  InboundTranslationSlice: `// ImportProduct InboundTranslationSlice.
@@reventless.spec

@schema
type externalInput = {sku: string, title: string}

@schema
type command = AddProduct({productId: string, name: string})

let targetName = "AddProduct"

let translate = input =>
  Ok([(input.sku, AddProduct({productId: input.sku, name: input.title}))])
`,

  OutboundTranslationSlice: `// SendEmail OutboundTranslationSlice.
@@reventless.spec

@schema
type consumedEvent =
  | OrderPlaced({orderId: string, email: string})

@schema
type outboundItem = {orderId: string, email: string}

@schema
type inboundCommand = unit

let collect = event =>
  switch event {
  | OrderPlaced({orderId, email}) => [(orderId, {orderId, email})]
  }

let translate = async (_id, item) => {
  await EmailService.send(item.email, ~orderId=item.orderId)
  Ok(None)
}

let maxRetries = 3
let heartbeatInterval = 60
let targetName = None
`,
};

// ----- Tests -----

describe('splitSource — basic structural checks per slice kind', () => {
  for (const [kindName, src] of Object.entries(FIXTURES)) {
    const cfg = SLICE_KINDS[kindName];

    test(`${kindName}: spec file keeps @@reventless.spec`, () => {
      const r = splitSource(src, kindName);
      assert.match(r.specOut, /^[\s\S]*?@@reventless\.spec\b/m);
    });

    test(`${kindName}: impl file uses @@reventless.${cfg.implKind.toLowerCase()}`, () => {
      const r = splitSource(src, kindName);
      assert.match(r.implOut, new RegExp('^' + cfg.implAttr.replace(/[.@]/g, '\\$&'), 'm'));
    });

    test(`${kindName}: every spec binding (when present in source) lands in spec file`, () => {
      const r = splitSource(src, kindName);
      for (const it of r.items) {
        if (it.kind === 'binding' && it.name && cfg.specBindings.has(it.name)) {
          assert.equal(it.target, 'spec', `binding "${it.name}" should target spec`);
        }
      }
    });

    test(`${kindName}: every impl binding (when present in source) lands in impl file`, () => {
      const r = splitSource(src, kindName);
      for (const it of r.items) {
        if (it.kind === 'binding' && it.name && cfg.implBindings.has(it.name)) {
          assert.equal(it.target, 'impl', `binding "${it.name}" should target impl`);
        }
      }
    });

    test(`${kindName}: header comments survive in spec file`, () => {
      const r = splitSource(src, kindName);
      const headerLine = src.split('\n')[0]; // "// <Name> <SliceKind>."
      assert.ok(r.specOut.includes(headerLine), `expected header "${headerLine}" in spec`);
    });

    test(`${kindName}: no spec-file binding leaks into impl file`, () => {
      const r = splitSource(src, kindName);
      // For each spec binding present in the source, assert its definition
      // text doesn't appear in the impl half.
      for (const name of cfg.specBindings) {
        if (!source_has_binding(src, name)) continue;
        // Look for a top-level definition of `name` in implOut.
        const defRe = binding_def_re(name);
        assert.ok(!defRe.test(r.implOut),
          `spec binding "${name}" leaked into impl file`);
      }
    });

    test(`${kindName}: no impl-file binding leaks into spec file`, () => {
      const r = splitSource(src, kindName);
      for (const name of cfg.implBindings) {
        if (!source_has_binding(src, name)) continue;
        const defRe = binding_def_re(name);
        assert.ok(!defRe.test(r.specOut),
          `impl binding "${name}" leaked into spec file`);
      }
    });

    test(`${kindName}: no warnings produced`, () => {
      const r = splitSource(src, kindName);
      assert.deepEqual(r.warnings, [], `expected no warnings`);
    });
  }
});

describe('splitSource — re-splitting the spec output is byte-stable', () => {
  for (const [kindName, src] of Object.entries(FIXTURES)) {
    test(`${kindName}: split(spec) === spec (no further work to do)`, () => {
      const r = splitSource(src, kindName);
      // The spec output, fed back through splitSource, should produce the
      // SAME spec output and an EMPTY impl body (no impl bindings to move).
      const r2 = splitSource(r.specOut, kindName);
      assert.equal(r2.specOut, r.specOut, 'spec output not stable across resplit');
      // The impl output of the second pass contains only the @@reventless.<kind> attribute.
      const cfg = SLICE_KINDS[kindName];
      assert.equal(r2.implOut.trim(), cfg.implAttr,
        `re-split impl should be empty (just the file attribute), got:\n${r2.implOut}`);
    });
  }
});

describe('splitSource — round-trip: split → re-merge → split is stable', () => {
  for (const [kindName, src] of Object.entries(FIXTURES)) {
    test(`${kindName}: round-trip stable`, () => {
      const r1 = splitSource(src, kindName);
      // Re-merge respecting the file-header convention: the comments BEFORE
      // @@reventless.spec must remain BEFORE the merged @@reventless.spec.
      const cfg = SLICE_KINDS[kindName];
      const { header, body: specBodyAfterAttr } = sliceAtFileAttr(r1.specOut, '@@reventless.spec');
      const implBody = stripFileAttr(r1.implOut, cfg.implAttr).trimStart();
      const remerged = header + '@@reventless.spec\n\n' + specBodyAfterAttr.trimStart() + (implBody ? '\n' + implBody : '');
      const r2 = splitSource(remerged, kindName);
      assert.equal(r2.specOut, r1.specOut, 'spec output drifted after round-trip');
      assert.equal(r2.implOut, r1.implOut, 'impl output drifted after round-trip');
    });
  }
});

// Helper: rough check whether `name` is defined at top-level in `src` as a let or type.
function source_has_binding(src, name) {
  const re = new RegExp('^(?:@[^\\n]*\\n)*\\s*(?:let|type)\\s+(?:rec\\s+)?' + escapeRegExp(name) + '(?![A-Za-z0-9_])', 'm');
  return re.test(src);
}

function binding_def_re(name) {
  return new RegExp('^(?:@[^\\n]*\\n)*\\s*(?:let|type)\\s+(?:rec\\s+)?' + escapeRegExp(name) + '(?![A-Za-z0-9_])', 'm');
}

function escapeRegExp(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function stripFileAttr(src, attr) {
  // Remove the first occurrence of `attr` as a standalone file attribute line.
  const re = new RegExp('^' + escapeRegExp(attr) + '\\s*\\n', 'm');
  return src.replace(re, '');
}

function sliceAtFileAttr(src, attr) {
  // Returns { header, body } where body is the content AFTER the attribute
  // line (and its trailing newline) and header is everything before it.
  const re = new RegExp('^' + escapeRegExp(attr) + '\\s*\\n', 'm');
  const m = src.match(re);
  if (!m) return { header: '', body: src };
  const idx = m.index;
  return { header: src.substring(0, idx), body: src.substring(idx + m[0].length) };
}

// ----- Summary -----

process.stdout.write('\n');
process.stdout.write(`${passed} passed, ${failed} failed\n`);
process.exit(failed > 0 ? 1 : 0);
