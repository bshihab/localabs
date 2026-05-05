import React, { useRef, useState } from 'react';
import { View, Text, TouchableOpacity, Modal, Pressable, Platform, useColorScheme } from 'react-native';
import Animated, { FadeIn, FadeOut, ZoomIn, ZoomOut } from 'react-native-reanimated';
import { BlurView } from 'expo-blur';
import { Ionicons } from '@expo/vector-icons';

export interface MenuOption {
  label: string;
  value: string;
}

interface Props {
  title: string;
  value: string;
  options: MenuOption[];
  onSelect: (val: string) => void;
  hasBottomBorder?: boolean;
}

export default function LiquidGlassPopupMenu({ title, value, options, onSelect, hasBottomBorder = true }: Props) {
  const [isVisible, setIsVisible] = useState(false);
  const [layout, setLayout] = useState({ x: 0, y: 0, width: 0, height: 0 });
  const rowRef = useRef<View>(null);
  const colorScheme = useColorScheme();
  const isDark = colorScheme === 'dark';

  const handleOpen = () => {
    rowRef.current?.measureInWindow((x, y, width, height) => {
      setLayout({ x, y, width, height });
      setIsVisible(true);
    });
  };

  const handleSelect = (val: string) => {
    setIsVisible(false);
    onSelect(val);
  };

  return (
    <>
      <TouchableOpacity 
        ref={rowRef}
        activeOpacity={0.7}
        className={`flex-row justify-between items-center py-3.5 px-4 ${hasBottomBorder ? 'border-b border-black/5 dark:border-white/10' : ''}`}
        onPress={handleOpen}
      >
        <Text className="text-[17px] text-apple-text-light dark:text-apple-text-dark">{title}</Text>
        <View className="flex-row items-center">
          <Text className={`text-[17px] mr-2 ${value ? 'text-apple-text-secondary-light dark:text-apple-text-secondary-dark' : 'text-apple-text-secondary-light/50 dark:text-apple-text-secondary-dark/50'}`}>
            {value || 'Not Set'}
          </Text>
          <Ionicons name="chevron-forward" size={20} color="#C7C7CC" />
        </View>
      </TouchableOpacity>

      <Modal transparent visible={isVisible} animationType="none">
        <Pressable 
          className="flex-1 bg-black/10 dark:bg-black/30" 
          onPress={() => setIsVisible(false)}
        >
          {isVisible && (
            <Animated.View 
              entering={Platform.OS === 'ios' ? ZoomIn.duration(200).springify() : FadeIn}
              exiting={Platform.OS === 'ios' ? ZoomOut.duration(150) : FadeOut}
              style={{
                position: 'absolute',
                top: layout.y - 12, // Snaps identically over the host row
                right: 24, // Anchors to the right trailing edge
                width: 220, // Strict compact UIMenu width
                shadowColor: '#000',
                shadowOffset: { width: 0, height: 16 },
                shadowOpacity: 0.25,
                shadowRadius: 32,
              }}
            >
              <BlurView 
                intensity={80} 
                tint={isDark ? "dark" : "light"} 
                className="rounded-[14px] overflow-hidden border border-white/20 dark:border-white/10 bg-white/40 dark:bg-black/40"
              >
                {options.map((opt, idx) => (
                  <View key={opt.value}>
                    <TouchableOpacity 
                      activeOpacity={0.7}
                      onPress={() => handleSelect(opt.value)}
                      className={`flex-row items-center py-[10px] px-3.5 ${value === opt.value ? 'bg-black/5 dark:bg-white/10' : ''}`}
                    >
                      <View className="w-8 items-center justify-center -ml-2">
                        {value === opt.value && (
                          <Ionicons name="checkmark" size={17} color={isDark ? "#FFF" : "#000"} />
                        )}
                      </View>
                      <Text className={`text-[16px] text-apple-text-light dark:text-apple-text-dark`}>
                        {opt.label}
                      </Text>
                    </TouchableOpacity>
                    {idx !== options.length - 1 && (
                      <View className="h-[0.5px] bg-black/10 dark:bg-white/10 ml-[38px]" />
                    )}
                  </View>
                ))}
              </BlurView>
            </Animated.View>
          )}
        </Pressable>
      </Modal>
    </>
  );
}
