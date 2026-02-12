import React from 'react';
import Content from '@theme-original/Navbar/Content';
import VersionSwitcher from '../../../components/VersionSwitcher';

export default function ContentWrapper(props) {
  return (
    <>
      <Content {...props} />
      <VersionSwitcher />
    </>
  );
}
