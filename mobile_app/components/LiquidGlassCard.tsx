import { View, StyleSheet, ViewProps } from 'react-native';
import React from 'react';
import { useColorScheme } from '@/hooks/use-color-scheme';

interface LiquidGlassCardProps extends ViewProps {
  children?: React.ReactNode;
}

export default function LiquidGlassCard({ children, style, ...props }: LiquidGlassCardProps) {
  const colorScheme = useColorScheme() ?? 'light';
  const isDark = colorScheme === 'dark';

  // Apple HIG Update: Liquid Glass is forbidden on static body content like cards.
  // We use standard iOS Elevated Inset Panels (#FFFFFF or #1C1C1E).
  return (
    <View 
      style={[
        styles.card, 
        { 
          backgroundColor: isDark ? '#1C1C1E' : '#FFFFFF',
          borderColor: isDark ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.04)',
        },
        style
      ]} 
      {...props}
    >
      {children}
    </View>
  );
}

const styles = StyleSheet.create({
  card: {
    borderRadius: 22,
    overflow: 'hidden',
    padding: 24,
    backgroundColor: '#ffffff', // iOS Standard Content White
    borderWidth: 1,
    borderColor: 'rgba(0,0,0,0.04)', // Ultra subtle inset stroke
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 6 },
    shadowOpacity: 0.04,
    shadowRadius: 12,
    elevation: 2,
  },
});
