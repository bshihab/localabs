import { requireNativeViewManager } from 'expo-modules-core';
import * as React from 'react';
import { ViewProps } from 'react-native';

export type OnSelectEvent = {
  value: string;
};

export type NativeMenuPickerProps = {
  options: string[];
  selectedValue: string;
  onSelectOption?: (event: { nativeEvent: OnSelectEvent }) => void;
} & ViewProps;

const NativeView: React.ComponentType<NativeMenuPickerProps> =
  requireNativeViewManager('NativeMenuPicker');

export default function NativeMenuPickerView(props: NativeMenuPickerProps) {
  return <NativeView {...props} />;
}
