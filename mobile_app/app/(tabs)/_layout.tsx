import { withLayoutContext } from 'expo-router';
import React from 'react';
import { Platform } from 'react-native';
import { createNativeBottomTabNavigator } from '@bottom-tabs/react-navigation';
import { Colors } from '@/constants/theme';
import { useColorScheme } from '@/hooks/use-color-scheme';

const { Navigator } = createNativeBottomTabNavigator();
const NativeTabs = withLayoutContext(Navigator);

export default function TabLayout() {
  const colorScheme = useColorScheme();

  return (
    <NativeTabs
      screenOptions={{
        tabBarActiveTintColor: Colors[colorScheme ?? 'light'].tint,
        headerShown: false,
        // The native bridge handles transulency natively, automatically gaining Liquid Glass on iOS 26+
        tabBarTranslucent: true,
      }}>
      <NativeTabs.Screen
        name="index"
        options={{
          title: 'Upload',
          tabBarIcon: () => ({ sfSymbol: 'doc.badge.plus' }),
        }}
      />
      <NativeTabs.Screen
        name="dashboard"
        options={{
          title: 'Dashboard',
          tabBarIcon: () => ({ sfSymbol: 'chart.bar.fill' }),
        }}
      />
      <NativeTabs.Screen
        name="chat"
        options={{
          title: 'Assistant',
          tabBarIcon: () => ({ sfSymbol: 'message.fill' }),
        }}
      />
      <NativeTabs.Screen
        name="history"
        options={{
          title: 'History',
          tabBarIcon: () => ({ sfSymbol: 'clock.fill' }),
        }}
      />
      <NativeTabs.Screen
        name="profile"
        options={{
          title: 'Profile',
          tabBarIcon: () => ({ sfSymbol: 'person.fill' }),
        }}
      />
    </NativeTabs>
  );
}
