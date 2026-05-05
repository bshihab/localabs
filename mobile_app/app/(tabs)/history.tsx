import { View, Text, ScrollView } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import LiquidGlassCard from '@/components/LiquidGlassCard';

export default function HistoryScreen() {
  return (
    <SafeAreaView className="flex-1 bg-apple-background-light dark:bg-apple-background-dark" edges={['top']}>
      <ScrollView className="flex-1 px-6 pt-4" contentContainerStyle={{ paddingBottom: 130 }}>
        <Text className="text-[34px] font-bold text-apple-text-light dark:text-apple-text-dark tracking-tight mb-6">Past Scans</Text>
        
        <LiquidGlassCard style={{ padding: 32, alignItems: 'center', marginTop: 40, opacity: 0.8 }}>
          <Text className="text-[20px] font-semibold text-apple-text-light dark:text-apple-text-dark mb-3 text-center tracking-tight">No scans yet</Text>
          <Text className="text-apple-text-secondary-light dark:text-apple-text-secondary-dark text-[15px] text-center leading-[22px]">
            When you scan and analyze a medical document, it will appear here safely stored on your device.
          </Text>
        </LiquidGlassCard>
      </ScrollView>
    </SafeAreaView>
  );
}
