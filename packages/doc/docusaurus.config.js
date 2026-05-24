// @ts-check
// `@type` JSDoc annotations allow editor autocompletion and type checking
// (when paired with `@ts-check`).
// There are various equivalent ways to declare your Docusaurus config.
// See: https://docusaurus.io/docs/api/docusaurus-config

import { themes as prismThemes } from "prism-react-renderer";
import { readFileSync } from "fs";
import { join } from "path";
import { execSync } from "child_process";

// Tracks which D2 diagram indices (per file) are sequence diagrams.
// Populated by d2PrependStyles, consumed by rehypeSequenceDiagramClass.
const sequenceDiagramTracker = new Map();

// Remark plugin that prepends shared D2 class definitions to every d2 code
// block before remark-d2 passes them to the d2 CLI.
//
// Why not use D2's native `...@file` import syntax in the markdown?
// The VS Code D2 preview extension writes code blocks to a temp file and calls
// d2 on it, so D2 resolves imports relative to the temp dir — unreachable from
// the project. By prepending here (before d2 ever sees the code) we get styled
// diagrams in Docusaurus without any import syntax in the markdown files.
// VS Code renders the same diagrams without the class styles (D2 silently
// ignores undefined classes), which means no errors and a functional preview.
function d2PrependStyles(opts = {}) {
  let styles = null;
  try {
    styles = readFileSync(opts.stylesPath, "utf8").trim();
  } catch (_) { /* file not found — skip silently */ }

  return (tree, file) => {
    if (!styles) return;
    let count = 0;
    const sequenceIndices = new Set();
    const walk = (node) => {
      if (node.type === "code" && node.lang === "d2") {
        if (node.value.includes("shape: sequence_diagram")) {
          sequenceIndices.add(count);
        }
        node.value = styles + "\n\n" + node.value;
        count++;
      }
      if (node.children) node.children.forEach(walk);
    };
    walk(tree);
    if (file.path) sequenceDiagramTracker.set(file.path, sequenceIndices);
  };
}

// Rehype plugin that adds class="sequence-diagram" to <img> elements that were
// generated from D2 sequence diagram code blocks. Uses sequenceDiagramTracker
// to know which diagram indices are sequence diagrams.
function rehypeSequenceDiagramClass() {
  return (tree, file) => {
    const sequenceIndices = (file.path && sequenceDiagramTracker.get(file.path)) ?? new Set();
    if (sequenceIndices.size === 0) return;
    let d2Count = 0;
    const walk = (node) => {
      if (
        node.type === "element" &&
        node.tagName === "img" &&
        typeof node.properties?.src === "string" &&
        node.properties.src.includes("/d2/")
      ) {
        if (sequenceIndices.has(d2Count)) {
          node.properties.className = [...(node.properties.className ?? []), "sequence-diagram"];
        }
        d2Count++;
      }
      if (node.children) node.children.forEach(walk);
    };
    walk(tree);
  };
}

// remark-d2 is ESM-only, so we load it via dynamic import in an async config.
async function createConfig() {
const d2 = (await import("remark-d2")).default;

// Which version this build represents ("latest" | "beta" | "alpha").
// `version-config.js` is written per-build by .github/workflows/deploy-docs.yml
// and is absent in local dev, where we treat the build as "local". Exposed via
// customFields so VersionSwitcher/VersionBanner can pre-select reliably instead
// of guessing from baseUrl.
let docsVersion = "local";
try {
  // @ts-ignore — version-config.js is generated at build time, absent locally.
  docsVersion = require("./version-config.js").version;
} catch (_) {
  // Local dev: no version-config.js. Derive from the current git branch so the
  // switcher reflects the branch you're previewing (main → latest, beta, alpha).
  // Any other branch (or no git) stays "local".
  try {
    const branch = execSync("git rev-parse --abbrev-ref HEAD", {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    if (branch === "main") docsVersion = "latest";
    else if (branch === "beta" || branch === "alpha") docsVersion = branch;
  } catch (_) {
    /* not a git checkout — leave as "local" */
  }
}
const d2StylesPath = join(process.cwd(), "d2", "reventless.d2");
const d2Opts = {
  linkPath: "/reventless-core/d2",
  defaultD2Opts: ["-t=100", "--dark-theme=200", "--pad=10", "--scale=0.8"],
};

// Copyright span: just the start year now, becoming a range (2026–YYYY) once the
// current year moves past it.
const COPYRIGHT_START_YEAR = 2026;
const copyrightYears = (() => {
  const now = new Date().getFullYear();
  return now > COPYRIGHT_START_YEAR ? `${COPYRIGHT_START_YEAR}–${now}` : `${COPYRIGHT_START_YEAR}`;
})();

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: "Reventless",
  tagline: "Ship Value Fast",
  favicon: "img/logo-icon-v2a-sticky.svg",

  // Geist is the brand wordmark font (rendered as real text in src/theme/Logo).
  headTags: [
    {
      tagName: "link",
      attributes: {rel: "preconnect", href: "https://fonts.googleapis.com"},
    },
    {
      tagName: "link",
      attributes: {
        rel: "preconnect",
        href: "https://fonts.gstatic.com",
        crossorigin: "anonymous",
      },
    },
  ],
  stylesheets: [
    "https://fonts.googleapis.com/css2?family=Geist:wght@400;600;700&display=swap",
  ],

  // Set the production url of your site here
  url: "https://reventlessdev.github.io",
  // Set the /<baseUrl>/ pathname under which your site is served
  // For GitHub pages deployment, it is often '/<projectName>/'
  baseUrl: "/reventless-core/",

  // GitHub pages deployment config.
  organizationName: "ReventlessDev", // Usually your GitHub org/user name.
  projectName: "reventless-core", // Usually your repo name.

  customFields: {
    // Consumed by VersionSwitcher/VersionBanner for current-version detection.
    docsVersion,
  },

  onBrokenLinks: "warn",
  onBrokenMarkdownLinks: "warn",

  // activate mermaid support
  // according to docusarus docs: https://docusaurus.io/docs/markdown-features/diagrams
  markdown: {
    mermaid: true,
  },

  themes: [
    "@docusaurus/theme-mermaid",
    [
      require.resolve("@easyops-cn/docusaurus-search-local"),
      {
        hashed: true,
        language: ["en"],
        indexDocs: true,
        indexBlog: true,
        // Parallel arrays: each docsDir (the plugin instance's `path`) maps to
        // the matching docsRouteBasePath (its `routeBasePath`). docsDir must be
        // set explicitly here because this site has no default `docs/` folder —
        // otherwise the build warns "docsDir doesn't exist".
        docsDir: ["docs-app", "docs-framework", "docs-infrastructure", "docs-tutorials"],
        docsRouteBasePath: ["app", "framework", "infrastructure", "tutorials"],
        // The index is generated in Docusaurus's postBuild hook, so search only
        // works after `docusaurus build` + `docusaurus serve`, never in `start`.
        removeDefaultStopWordFilter: true,
        highlightSearchTermsOnTargetPage: true,
      },
    ],
  ],

  // Even if you don't use internationalization, you can use this field to set
  // useful metadata like html lang. For example, if your site is Chinese, you
  // may want to replace "en" with "zh-Hans".
  i18n: {
    defaultLocale: "en",
    locales: ["en"],
  },

  plugins: [
    [
      "@docusaurus/plugin-content-docs",
      {
        // No id = this is the 'default' docs plugin instance.
        // Required so the search bar's useDocsData() hook can find it.
        path: "docs-app",
        routeBasePath: "app",
        sidebarPath: "./sidebars-app.js",
        remarkPlugins: [[d2PrependStyles, { stylesPath: d2StylesPath }], [d2, d2Opts]],
        rehypePlugins: [rehypeSequenceDiagramClass],
        editUrl:
          "https://github.com/ReventlessDev/reventless-core/tree/main/packages/doc/",
      },
    ],
    [
      "@docusaurus/plugin-content-docs",
      {
        id: "framework",
        path: "docs-framework",
        routeBasePath: "framework",
        sidebarPath: "./sidebars-framework.js",
        remarkPlugins: [[d2PrependStyles, { stylesPath: d2StylesPath }], [d2, d2Opts]],
        rehypePlugins: [rehypeSequenceDiagramClass],
        editUrl:
          "https://github.com/ReventlessDev/reventless-core/tree/main/packages/doc/",
      },
    ],
    [
      "@docusaurus/plugin-content-docs",
      {
        id: "infrastructure",
        path: "docs-infrastructure",
        routeBasePath: "infrastructure",
        sidebarPath: "./sidebars-infrastructure.js",
        remarkPlugins: [[d2PrependStyles, { stylesPath: d2StylesPath }], [d2, d2Opts]],
        rehypePlugins: [rehypeSequenceDiagramClass],
        editUrl:
          "https://github.com/ReventlessDev/reventless-core/tree/main/packages/doc/",
      },
    ],
    [
      "@docusaurus/plugin-content-docs",
      {
        id: "tutorials",
        path: "docs-tutorials",
        routeBasePath: "tutorials",
        sidebarPath: "./sidebars-tutorials.js",
        remarkPlugins: [[d2PrependStyles, { stylesPath: d2StylesPath }], [d2, d2Opts]],
        rehypePlugins: [rehypeSequenceDiagramClass],
        editUrl:
          "https://github.com/ReventlessDev/reventless-core/tree/main/packages/doc/",
      },
    ],
  ],

  presets: [
    [
      "classic",
      /** @type {import('@docusaurus/preset-classic').Options} */
      ({
        docs: false,
        blog: {
          showReadingTime: true,
          blogTitle: "Reventless Blog",
          blogDescription:
            "Release notes, design deep-dives, and case studies for the Reventless event-sourced CQRS framework",
          postsPerPage: 10,
          feedOptions: {
            type: ["rss", "atom"],
            xslt: true,
            title: "Reventless Blog",
            description:
              "Release notes, design deep-dives, and case studies for Reventless",
            copyright: `Copyright © ${copyrightYears} Reventless`,
          },
          editUrl:
            "https://github.com/ReventlessDev/reventless-core/tree/main/packages/doc/",
        },
        theme: {
          customCss: "./src/css/custom.css",
        },
      }),
    ],
  ],

  themeConfig:
    /** @type {import('@docusaurus/preset-classic').ThemeConfig} */
    ({
      // Replace with your project's social card
      //image: 'img/docusaurus-social-card.jpg',
      navbar: {
        title: "",
        // Logo (icon + wordmark) is rendered by the swizzled src/theme/Logo;
        // src is required by the navbar schema but unused by that component.
        logo: {
          alt: 'Reventless',
          src: 'img/logo-icon-v2a-sticky.svg',
        },
        items: [
          {
            type: "doc",
            docId: "index",
            position: "left",
            label: "Intro",
          },
          {
            type: "docSidebar",
            sidebarId: "tutorialsSidebar",
            docsPluginId: "tutorials",
            position: "left",
            label: "Tutorial",
          },
          {
            type: "docSidebar",
            sidebarId: "appSidebar",
            position: "left",
            label: "App Guide",
          },
          {
            type: "docSidebar",
            sidebarId: "infrastructureSidebar",
            docsPluginId: "infrastructure",
            position: "left",
            label: "Infrastructure",
          },
          {
            type: "docSidebar",
            sidebarId: "frameworkSidebar",
            docsPluginId: "framework",
            position: "left",
            label: "Contributing",
          },
          {
            to: "/blog",
            label: "Blog",
            position: "left",
          },
          {
            type: "custom-versionSwitcher",
            position: "right",
          },
          {
            href: "https://github.com/ReventlessDev/reventless-core",
            position: "right",
            className: "header-github-link",
            "aria-label": "GitHub repository",
          },
        ],
      },
      footer: {
        style: "dark",
        links: [
          {
            title: "App Developer Guide",
            items: [
              {
                label: "Get Started",
                to: "/app/get-started",
              },
              {
                label: "Components",
                to: "/app/component-overview",
              },
            ],
          },
          {
            title: "Developer Guides",
            items: [
              {
                label: "Contributing",
                to: "/framework",
              },
              {
                label: "Infrastructure",
                to: "/infrastructure",
              },
            ],
          },
          {
            title: "Resources",
            items: [
              {
                label: "ReScript",
                href: "https://rescript-lang.org/",
              },
              {
                label: "Pulumi",
                href: "https://www.pulumi.com/",
              },
              {
                label: "AWS Serverless",
                href: "https://aws.amazon.com/serverless/",
              },
            ],
          },
          {
            title: "More",
            items: [
              {
                label: "GitHub",
                href: "https://github.com/ReventlessDev/reventless-core",
              },
            ],
          },
        ],
        copyright: `Copyright © ${copyrightYears} Reventless`,
      },
      prism: {
        theme: prismThemes.github,
        darkTheme: prismThemes.dracula,
        additionalLanguages: ["rescript"],
      },
      mermaid: {
        options: {
          //maxTextSize: 50,
          // FIXME:
          themeCSS: `
            /* MESSAGES */
            .command > circle,
            rect[name="CommandSource"] {
              stroke: #66f;
              fill: #fff;
              r: 45px;
              }
            .command .nodeLabel,
            rect[name="CommandSource"] {
              color: #66f;
              }

            .event > circle {
              stroke: #fa0;
              fill:none;
              }
            .event .nodeLabel {
              color: #fa0;
              }

            /* REVENTLESS COMPONENTS */
            .aggregate > rect,
            rect[name="Aggregate"] {
              fill: #ff6;
              stroke: #333;
              }
            rect[name="Aggregate"] + text > tspan {
              color: #333;
            }

            .eventlog > rect,
            rect[name="CommandTopic"] {
              fill: #fa0;
              stroke: #333;
              }
            rect[name="CommandTopic"] + text > tspan {
              color: #333;
            }

            .eventlog > rect,
            rect[name="EventLog"] {
              fill: #fa0;
              stroke: #333;
              }
            rect[name="EventLog"] + text > tspan {
              color: #333;
            }

           .eventtopic > rect,
            rect[name="EventTopic"] {
              fill: #b97c01;
              stroke: #333;
              }
            rect[name="EventTopic"] + text > tspan {
              fill: #fff;
            }

            .readmodel > rect {
              fill: #9c5;
              stroke: #333;
              }
            .readmodel .nodeLabel {
              color: #333;
            }

            .eventlog > path {
              fill: #fa0;
              }
            .eventlog .nodeLabel {
              }

            .eventtopic > rect {
              fill: #b97c01;
              }
            .eventtopic .nodeLabel {
              }

            .eventtopic > rect {
              fill: #b97c01;
              }
            .eventtopic .nodeLabel {
              }

            .eventcollector > rect {
              fill: #bda677;
              }
            .eventcollector .nodeLabel {
              }

            .eventmapper > rect {
              fill: #99f;
              stroke: #fa0;
              }
            .eventmapper .nodeLabel {
              }

            .task > rect {
              fill: #f9f;
              stroke:#333;
              }
            .task .nodeLabel {
              color: #333;
            }

            .sideeffecthandler > rect {
              fill: #f9f;
              stroke: #ff0;
              }
            .sideeffecthandler .nodeLabel {
            }

            .commandtopic > rect {
              fill: #88ccff;
              /*fill: #fff;*/
              }
            .commandtopic .nodeLabel {
              /*color: #66f;*/
              }

            .commandgenerator > rect {
              fill: #88ccff;
              }
            .commandgenerator .nodeLabel {
              /*color: #66f;*/
              }

            .client > rect {
            /* TODO */
            }

            /* HELPER */
            .parameter > rect,
            rect[name="Behavior"] {
              fill: #f90;
              stroke: #f90;
            }
            .target > rect,
            .source > rect {
              stroke: none;
              fill: none;
            }
            `,
        },
      },
    }),
};

return config;
}

export default createConfig;
