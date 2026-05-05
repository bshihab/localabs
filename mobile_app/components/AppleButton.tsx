import React, { useRef, useEffect } from 'react';
import { View, Text, StyleSheet, TouchableWithoutFeedback, Animated, ActivityIndicator, TouchableOpacityProps, useColorScheme } from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import LiquidGlassView from './NativeLiquidGlass';

interface AppleButtonProps extends TouchableOpacityProps {
  title: string;
  variant?: 'primary' | 'secondary' | 'destructive' | 'success';
  loading?: boolean;
  icon?: keyof typeof Ionicons.glyphMap;
  animateIcon?: 'pulse';
}

export default function AppleButton({ 
  title, 
  variant = 'primary', 
  loading = false,
  style, 
  disabled,
  onPress,
  ...props 
}: AppleButtonProps) {
  
  // Drives the physical HIG "squish" depth interpolation
  const colorScheme = useColorScheme();
  const isDark = colorScheme === 'dark';

  const scale = useRef(new Animated.Value(1)).current;
  const iconScale = useRef(new Animated.Value(1)).current;

  // Active Hardware Animation Loop
  useEffect(() => {
    if (props.animateIcon === 'pulse') {
      Animated.loop(
        Animated.sequence([
          Animated.timing(iconScale, { toValue: 1.3, duration: 400, useNativeDriver: true }),
          Animated.timing(iconScale, { toValue: 1, duration: 400, useNativeDriver: true }),
          Animated.delay(600)
        ])
      ).start();
    }
  }, [props.animateIcon]);

  const handlePressIn = () => {
    if (disabled || loading) return;
    Animated.spring(scale, {
      toValue: 0.96, // Apple standard highlight depth
      tension: 100,
      friction: 5,
      useNativeDriver: true, // Offload to UI thread
    }).start();
  };

  const handlePressOut = () => {
    if (disabled || loading) return;
    Animated.spring(scale, {
      toValue: 1, // Apple bounce-back physics
      tension: 100,
      friction: 5,
      useNativeDriver: true,
    }).start();
  };

  const getTintColor = () => {
    if (disabled && !loading) return isDark ? 'rgba(255, 255, 255, 0.05)' : 'rgba(0, 0, 0, 0.05)';
    switch (variant) {
      case 'primary': return isDark ? 'rgba(10, 132, 255, 0.15)' : 'rgba(0, 122, 255, 0.1)';
      case 'secondary': return isDark ? 'rgba(255, 255, 255, 0.12)' : 'rgba(0, 0, 0, 0.06)';
      case 'destructive': return isDark ? 'rgba(255, 69, 58, 0.15)' : 'rgba(255, 59, 48, 0.1)';
      case 'success': return isDark ? 'rgba(50, 215, 75, 0.15)' : 'rgba(52, 199, 89, 0.1)';
    }
  };

  const getTextColor = () => {
    if (disabled && !loading) return isDark ? '#6B7280' : '#9CA3AF'; // Solid Gray
    switch (variant) {
      case 'primary': return isDark ? '#0A84FF' : '#007AFF';
      case 'secondary': return isDark ? '#FFFFFF' : '#000000'; // Pure contrast for visibility!
      case 'destructive': return isDark ? '#FF453A' : '#FF3B30';
      case 'success': return isDark ? '#32D74B' : '#34C759';
    }
  };

  return (
    <TouchableWithoutFeedback 
      onPress={onPress} 
      onPressIn={handlePressIn} 
      onPressOut={handlePressOut}
      disabled={disabled || loading}
      {...props}
    >
      <Animated.View style={[styles.container, style, { transform: [{ scale }] }]}>
        {/* 1. Base Layer: The Native Liquid Glass Physics (Blurs background) */}
        <LiquidGlassView style={StyleSheet.absoluteFill} />
        
        {/* 2. Tint Layer: Apple HIG states the color tint must sit ON TOP of the glass */}
        <View style={[StyleSheet.absoluteFill, { backgroundColor: getTintColor() }]} />
        
        {/* 3. Interactive Layer */}
        <View style={styles.touchable}>
          {loading ? (
            <ActivityIndicator color={getTextColor()} />
          ) : (
            <View style={{ flexDirection: 'row', alignItems: 'center' }}>
              {props.icon && (
                <Animated.View style={{ transform: [{ scale: iconScale }] }}>
                  <Ionicons name={props.icon} size={20} color={getTextColor()} style={{ marginRight: 8 }} />
                </Animated.View>
              )}
              <Text style={[styles.text, { color: getTextColor() }]}>
                {title}
              </Text>
            </View>
          )}
        </View>
      </Animated.View>
    </TouchableWithoutFeedback>
  );
}

const styles = StyleSheet.create({
  container: {
    // Apple HIG: buttons should use capsule shape. Hit region 44x44 minimum.
    height: 56,
    borderRadius: 28, // Perfect capsule
    overflow: 'hidden', // Clips the Liquid Glass and Tint to the capsule shape
    width: '100%',
  },
  touchable: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 24,
  },
  text: {
    fontSize: 17, // iOS Standard Action Font Size
    fontWeight: '600', // Semibold is Apple's standard for primary buttons
    letterSpacing: -0.4,
  }
});
