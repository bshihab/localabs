import { DarkTheme, DefaultTheme, ThemeProvider } from '@react-navigation/native';
import { Stack, useRouter, useSegments } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { useEffect } from 'react';
import AsyncStorage from '@react-native-async-storage/async-storage';
import * as Notifications from 'expo-notifications';
import 'react-native-reanimated';
import DynamicIslandTracker from '@/components/DynamicIslandTracker';
import './global.css';

import { useColorScheme } from '@/hooks/use-color-scheme';

export const unstable_settings = {
  anchor: '(tabs)',
};

export default function RootLayout() {
  const colorScheme = useColorScheme();
  const router = useRouter();
  const segments = useSegments();

  useEffect(() => {
    // 1. Handle deep linking from a Notification Tap
    const subscription = Notifications.addNotificationResponseReceivedListener(response => {
      const data = response.notification.request.content.data;
      if (data?.route && data?.action) {
        // Example: routes to '/dashboard' with '?action=weekly_review'
        router.push({ pathname: data.route as any, params: { action: String(data.action) } });
      }
    });

    // 2. Main Authentication Routing Guard
    async function verifyOnboarding() {
      // Wait for router payload to be fully mounted
      setTimeout(async () => {
        try {
          const profileStr = await AsyncStorage.getItem('@user_profile');
          const isNavigatingToTabs = segments[0] === '(tabs)';
          const isAtOnboarding = segments[0] === 'onboarding';

          if (!profileStr && !isAtOnboarding) {
            // First time user! Send to beautiful onboarding slider
            router.replace('/onboarding');
          }
        } catch (error) {
          console.error('Error checking profile routing', error);
        }
      }, 50);
    }
    
    verifyOnboarding();

    return () => {
      subscription.remove();
    };
  }, [segments]); // Re-run if they try to navigate around

  return (
    <ThemeProvider value={colorScheme === 'dark' ? DarkTheme : DefaultTheme}>
      <Stack screenOptions={{ headerShown: false }}>
        <Stack.Screen name="onboarding" options={{ animation: 'fade' }} />
        <Stack.Screen name="(tabs)" />
        <Stack.Screen name="modal" options={{ presentation: 'modal', headerShown: true }} />
      </Stack>
      <DynamicIslandTracker />
      <StatusBar style="auto" />
    </ThemeProvider>
  );
}
