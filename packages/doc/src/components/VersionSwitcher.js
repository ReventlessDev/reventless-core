import React from 'react';
import useDocusaurusContext from '@docusaurus/useDocusaurusContext';

const versions = [
  { name: 'Latest', path: '/', badge: 'STABLE', badgeColor: '#0f9d58' },
  { name: 'Beta', path: '/beta/', badge: 'PRE-RELEASE', badgeColor: '#f4b400' },
  { name: 'Alpha', path: '/alpha/', badge: 'EXPERIMENTAL', badgeColor: '#db4437' },
];

export default function VersionSwitcher() {
  const { siteConfig } = useDocusaurusContext();
  const baseUrl = siteConfig.baseUrl;

  // Determine current version based on baseUrl
  let currentVersion = 'Latest';
  if (baseUrl.includes('/beta/')) {
    currentVersion = 'Beta';
  } else if (baseUrl.includes('/alpha/')) {
    currentVersion = 'Alpha';
  }

  return (
    <div style={{
      padding: '8px 12px',
      background: 'var(--ifm-navbar-background-color)',
      borderRadius: '6px',
      display: 'flex',
      alignItems: 'center',
      gap: '8px',
      fontSize: '14px',
    }}>
      <span style={{ fontWeight: 500 }}>Version:</span>
      <select
        value={currentVersion}
        onChange={(e) => {
          const selected = versions.find(v => v.name === e.target.value);
          if (selected) {
            const basePathRegex = /^\/reventless-core(\/beta|\/alpha)?\//;
            const currentPath = window.location.pathname;
            const pathAfterBase = currentPath.replace(basePathRegex, '');
            window.location.href = `${window.location.origin}/reventless-core${selected.path}${pathAfterBase}`;
          }
        }}
        style={{
          padding: '4px 8px',
          borderRadius: '4px',
          border: '1px solid var(--ifm-color-emphasis-300)',
          background: 'var(--ifm-background-color)',
          color: 'var(--ifm-font-color-base)',
          cursor: 'pointer',
        }}
      >
        {versions.map(v => (
          <option key={v.name} value={v.name}>
            {v.name} ({v.badge})
          </option>
        ))}
      </select>
    </div>
  );
}
