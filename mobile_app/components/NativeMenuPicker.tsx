import React from 'react';
import { View, Text, useColorScheme } from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { NativeMenuPickerView } from '../modules/native-menu-picker';

interface Props {
  title: string;
  value: string;
  options: string[];
  onSelect: (val: string) => void;
  hasBottomBorder?: boolean;
}

export default function NativeMenuPicker({ title, value, options, onSelect, hasBottomBorder = true }: Props) {
  const colorScheme = useColorScheme();
  const isDark = colorScheme === 'dark';

  return (
    <View
      className={`flex-row justify-between items-center py-3.5 px-4 ${hasBottomBorder ? 'border-b border-black/5 dark:border-white/10' : ''}`}
    >
      <Text className="text-[17px] text-apple-text-light dark:text-apple-text-dark">{title}</Text>
      <View className="flex-row items-center">
        <NativeMenuPickerView
          options={options}
          selectedValue={value}
          onSelectOption={(event) => onSelect(event.nativeEvent.value)}
          style={{ height: 34, minWidth: 100 }}
        />
        <Ionicons
          name="chevron-expand"
          size={16}
          color={isDark ? 'rgba(235,235,245,0.3)' : 'rgba(60,60,67,0.3)'}
          style={{ marginLeft: 2 }}
        />
      </View>
    </View>
  );
}
