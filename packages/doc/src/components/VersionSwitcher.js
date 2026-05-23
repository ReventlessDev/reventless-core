import { useEffect, useState } from 'react';
import useDocusaurusContext from '@docusaurus/useDocusaurusContext';

// Fallback labels for the single-entry view rendered before the manifest loads
// (or in local dev, where there is no manifest at all).
const VERSION_META = {
  latest: { label: 'Latest' },
  beta: { label: 'Beta' },
  alpha: { label: 'Alpha' },
};

// Compact, navbar-native version switcher. Registered as the
// `custom-versionSwitcher` navbar item type (see theme/NavbarItem/ComponentTypes).
//
// The version list is driven by a runtime `versions.json` at the site root,
// emitted by the deploy workflow. Fetching it at runtime (rather than baking the
// list in at build time) means publishing a new version updates the switcher on
// every already-built version automatically — no rebuild of the others needed.
// Locally, where the manifest 404s, the switcher degrades to a single entry for
// the version being viewed.
export default function VersionSwitcher() {
  const { siteConfig } = useDocusaurusContext();
  const baseUrl = siteConfig.baseUrl;

  // Root path shared by every version sub-site (strip the version sub-path).
  const rootBase = baseUrl.replace(/(?:beta|alpha)\/$/, '');

  // Detect the version being viewed: prefer the build-injected customField,
  // then fall back to a baseUrl heuristic.
  const injected = siteConfig.customFields?.docsVersion;
  const currentId =
    injected && injected !== 'local'
      ? injected
      : baseUrl.includes('/beta/')
      ? 'beta'
      : baseUrl.includes('/alpha/')
      ? 'alpha'
      : 'latest';

  const [versions, setVersions] = useState(null);

  useEffect(() => {
    let cancelled = false;
    fetch(`${rootBase}versions.json`)
      .then((r) => (r.ok ? r.json() : null))
      .then((manifest) => {
        if (!cancelled && manifest?.versions) setVersions(manifest.versions);
      })
      .catch(() => {
        /* no manifest (local dev) — keep the single-entry fallback */
      });
    return () => {
      cancelled = true;
    };
  }, [rootBase]);

  // Until the manifest loads (or in local dev), show just the current version so
  // the control is never empty or pointing at undeployed paths.
  const list = versions ?? [
    {
      id: currentId,
      label: VERSION_META[currentId]?.label ?? currentId,
      path: rootBase + (currentId === 'latest' ? '' : `${currentId}/`),
      published: true,
    },
  ];

  const navigate = (selected) => {
    if (!selected) return;
    const origin = window.location.origin;
    if (selected.published) {
      // Preserve the current page within the docs when switching versions.
      const basePathRegex = /^\/reventless-core(?:\/beta|\/alpha)?\//;
      const pathAfterBase = window.location.pathname.replace(basePathRegex, '');
      window.location.href = `${origin}${selected.path}${pathAfterBase}`;
    } else {
      // Unpublished → land on the generated "not yet released" placeholder.
      window.location.href = `${origin}${selected.path}`;
    }
  };

  return (
    <select
      className="navbar__version-select"
      aria-label="Documentation version"
      value={currentId}
      onChange={(e) => navigate(list.find((v) => v.id === e.target.value))}
    >
      {list.map((v) => (
        <option key={v.id} value={v.id}>
          {v.published ? v.label : `${v.label} (coming soon)`}
        </option>
      ))}
    </select>
  );
}
