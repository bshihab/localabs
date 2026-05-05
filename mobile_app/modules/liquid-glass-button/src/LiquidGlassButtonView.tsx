import { requireNativeViewManager } from 'expo-modules-core';
import * as React from 'react';
import { ViewProps } from 'react-native';

export type LiquidGlassButtonProps = ViewProps;

const NativeView: React.ComponentType<LiquidGlassButtonProps> = requireNativeViewManager('LiquidGlassButton');

export default function LiquidGlassButtonView(props: LiquidGlassButtonProps) {
  return <NativeView {...props} />;
}
