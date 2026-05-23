import { useEffect, useState } from 'react';
import useDocusaurusContext from '@docusaurus/useDocusaurusContext';

const BANNERS = {
  beta: {
    label: 'Beta',
    message:
      'You are viewing the BETA documentation. This version is stable but not yet released to production.',
    backgroundColor: '#f4b400',
  },
  alpha: {
    label: 'Alpha',
    message:
      'You are viewing the ALPHA documentation. This is an experimental version and may contain breaking changes.',
    backgroundColor: '#db4437',
  },
};

export default function VersionBanner() {
  const { siteConfig } = useDocusaurusContext();
  const baseUrl = siteConfig.baseUrl;
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

  // Target for the "View Latest Stable Docs" link — only shown when the stable
  // (latest) version is actually published, per the runtime manifest.
  const [stableHref, setStableHref] = useState(null);

  useEffect(() => {
    if (currentId === 'latest') return; // no banner, no fetch on the stable site
    let cancelled = false;
    fetch(`${rootBase}versions.json`)
      .then((r) => (r.ok ? r.json() : null))
      .then((manifest) => {
        const latest = manifest?.versions?.find((v) => v.id === 'latest');
        if (!cancelled && latest?.published) setStableHref(latest.path);
      })
      .catch(() => {
        /* no manifest — leave the stable link hidden */
      });
    return () => {
      cancelled = true;
    };
  }, [rootBase, currentId]);

  const banner = BANNERS[currentId];
  if (!banner) return null; // latest/local — no banner

  return (
    <div style={{
      backgroundColor: banner.backgroundColor,
      color: 'white',
      padding: '12px 20px',
      textAlign: 'center',
      fontWeight: 500,
      fontSize: '14px',
      position: 'sticky',
      top: 60,
      zIndex: 100,
      boxShadow: '0 2px 4px rgba(0,0,0,0.1)',
    }}>
      <strong>{banner.label} Version:</strong> {banner.message}
      {stableHref && (
        <>
          {' '}
          <a
            href={stableHref}
            style={{
              color: 'white',
              textDecoration: 'underline',
              fontWeight: 600,
            }}
          >
            View Latest Stable Docs →
          </a>
        </>
      )}
    </div>
  );
}
