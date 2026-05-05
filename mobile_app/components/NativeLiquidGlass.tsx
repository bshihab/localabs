import React from 'react';
import { LiquidGlassButtonView } from '../modules/liquid-glass-button';
import { ViewProps } from 'react-native';

export default function NativeLiquidGlass(props: ViewProps) {
  return <LiquidGlassButtonView {...props} />;
}
