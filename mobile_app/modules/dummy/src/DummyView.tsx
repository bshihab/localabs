import { requireNativeView } from 'expo';
import * as React from 'react';

import { DummyViewProps } from './Dummy.types';

const NativeView: React.ComponentType<DummyViewProps> =
  requireNativeView('Dummy');

export default function DummyView(props: DummyViewProps) {
  return <NativeView {...props} />;
}
