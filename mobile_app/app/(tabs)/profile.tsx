import { View, Text, ScrollView, Switch, TextInput } from 'react-native';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { useEffect, useState } from 'react';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useRouter } from 'expo-router';
import { NotificationService } from '@/services/notificationService';
import { InferenceEngine } from '@/services/inferenceEngine';
import LiquidGlassCard from '@/components/LiquidGlassCard';
import AppleButton from '@/components/AppleButton';

export default function ProfileScreen() {
  const router = useRouter();
  const [profile, setProfile] = useState<{ age?: string, biologicalSex?: string, medicalConditions?: string, medications?: string } | null>(null);
  const [medications, setMedications] = useState('');
  const [isModelLoaded, setIsModelLoaded] = useState(false);
  const [loadingProgress, setLoadingProgress] = useState(0);
  const [isNotificationsEnabled, setIsNotificationsEnabled] = useState(false);

  useEffect(() => {
    async function loadProfile() {
      const stored = await AsyncStorage.getItem('@user_profile');
      if (stored) {
        const data = JSON.parse(stored);
        setProfile(data);
        if (data.medications) setMedications(data.medications);
      }
    }
    loadProfile();
    
    // Check initial native AI boot state
    setIsModelLoaded(InferenceEngine.getIsModelLoaded());

    // Hardware poll the underlying Apple OS scheduler
    async function pollNotifications() {
      const active = await NotificationService.checkIsScheduled();
      setIsNotificationsEnabled(active);
    }
    pollNotifications();
  }, []);

  const handleToggleNotifications = async (value: boolean) => {
    // Instant optimistic UI response (No lag for the HIG Switch spring physics)
    setIsNotificationsEnabled(value);
    
    if (value) {
      await NotificationService.scheduleWeeklyReview();
    } else {
      await NotificationService.disableWeeklyReview();
    }
  };

  const handleLoadModel = async () => {
    await InferenceEngine.initializeModel((progress) => {
      setLoadingProgress(progress);
    });
    setIsModelLoaded(true);
  };

  return (
    <SafeAreaView className="flex-1 bg-apple-background-light dark:bg-apple-background-dark" edges={['top']}>
      <ScrollView className="flex-1 px-6 pt-4" contentContainerStyle={{ paddingBottom: 130 }}>
        <Text className="text-[34px] font-bold text-apple-text-light dark:text-apple-text-dark tracking-tight mb-8">Medical Profile</Text>
        
        <LiquidGlassCard style={{ marginBottom: 24, padding: 24 }}>
          <Text className="text-[13px] uppercase tracking-widest text-apple-blue-light dark:text-apple-blue-dark font-semibold mb-4">Offline AI Engine</Text>
          <Text className="text-apple-text-secondary-light dark:text-apple-text-secondary-dark text-[15px] mb-6 leading-[22px]">
            MedGemma requires a 2.5GB local weights file to analyze lab results entirely on-device without Apple iCloud.
          </Text>

          {isModelLoaded ? (
            <View className="bg-apple-blue-light/10 dark:bg-apple-blue-dark/20 p-4 rounded-[12px] flex-row items-center border border-apple-blue-light/20 dark:border-apple-blue-dark/20">
              <Text className="text-[20px] mr-3">✓</Text>
              <Text className="text-apple-blue-light dark:text-apple-blue-dark font-semibold text-[15px]">Model Loaded & Ready</Text>
            </View>
          ) : (
            <View>
              {loadingProgress > 0 && loadingProgress < 100 ? (
                <View className="mt-2 mb-4">
                   <View className="flex-row justify-between mb-2">
                     <Text className="text-apple-text-light dark:text-apple-text-dark font-semibold text-[13px]">Downloading Weights...</Text>
                     <Text className="text-apple-text-secondary-light dark:text-apple-text-secondary-dark font-semibold text-[13px]">{loadingProgress}%</Text>
                   </View>
                   <View className="w-full h-[8px] bg-black/5 dark:bg-white/10 rounded-full overflow-hidden">
                     <View style={{ width: `${loadingProgress}%` }} className="h-full bg-apple-blue-light dark:bg-apple-blue-dark rounded-full" />
                   </View>
                </View>
              ) : (
                <AppleButton
                  title="Download MedGemma 4B"
                  variant="primary"
                  onPress={handleLoadModel}
                />
              )}
            </View>
          )}
        </LiquidGlassCard>

        <LiquidGlassCard style={{ marginBottom: 24, padding: 24 }}>
          <Text className="text-[13px] uppercase tracking-widest text-apple-blue-light dark:text-apple-blue-dark font-semibold mb-4">Core Info</Text>
          
          <View className="flex-row justify-between mb-4 pb-4 border-b border-black/5 dark:border-white/10">
            <Text className="text-apple-text-light dark:text-apple-text-dark font-medium text-[17px]">Age</Text>
            <Text className="text-apple-text-secondary-light dark:text-apple-text-secondary-dark text-[17px] pr-2">{profile?.age || 'Not set'}</Text>
          </View>

          <View className="flex-row justify-between">
            <Text className="text-apple-text-light dark:text-apple-text-dark font-medium text-[17px]">Biological Sex</Text>
            <Text className="text-apple-text-secondary-light dark:text-apple-text-secondary-dark text-[17px] pr-2">{profile?.biologicalSex || 'Not set'}</Text>
          </View>
        </LiquidGlassCard>

        <LiquidGlassCard style={{ marginBottom: 24, padding: 24 }}>
          <Text className="text-[13px] uppercase tracking-widest text-apple-blue-light dark:text-apple-blue-dark font-semibold mb-4">Known Conditions</Text>
          <Text className="text-apple-text-light dark:text-apple-text-dark text-[17px] leading-[24px]">
            {profile?.medicalConditions || 'None reported.'}
          </Text>
        </LiquidGlassCard>

        <LiquidGlassCard style={{ marginBottom: 24, padding: 24 }}>
          <Text className="text-[13px] uppercase tracking-widest text-apple-blue-light dark:text-apple-blue-dark font-semibold mb-4">Current Medications</Text>
          <Text className="text-apple-text-secondary-light dark:text-apple-text-secondary-dark text-[15px] mb-4 leading-[22px]">
            List your daily medications so MedGemma can cross-reference them against your lab results for potential interactions.
          </Text>
          <TextInput
            className="bg-black/5 dark:bg-white/10 rounded-[16px] p-4 text-[17px] text-apple-text-light dark:text-apple-text-dark h-24"
            placeholder="e.g. Lisinopril 10mg, Metformin 500mg..."
            placeholderTextColor="#9CA3AF"
            multiline
            textAlignVertical="top"
            value={medications}
            onChangeText={async (text) => {
              setMedications(text);
              // Save medications to the user profile immediately
              try {
                const stored = await AsyncStorage.getItem('@user_profile');
                const existing = stored ? JSON.parse(stored) : {};
                existing.medications = text;
                await AsyncStorage.setItem('@user_profile', JSON.stringify(existing));
              } catch (e) { }
            }}
          />
        </LiquidGlassCard>

        <LiquidGlassCard style={{ marginBottom: 24, padding: 24 }}>
          <Text className="text-[13px] uppercase tracking-widest text-apple-blue-light dark:text-apple-blue-dark font-semibold mb-4">Weekly Offline Check-ins</Text>
          <Text className="text-apple-text-secondary-light dark:text-apple-text-secondary-dark text-[15px] mb-6 leading-[22px]">
            Allow MedGemma to schedule a purely local, offline notification once a week. Tap it to generate a smart review of your Apple Health data!
          </Text>
          
          <View className="flex-row justify-between items-center py-3 border-b border-black/5 dark:border-white/10 mb-4">
            <Text className="text-apple-text-light dark:text-apple-text-dark font-medium text-[17px]">Enable Weekly Reviews</Text>
            <Switch
              value={isNotificationsEnabled}
              onValueChange={handleToggleNotifications}
              trackColor={{ false: '#767577', true: '#34C759' }}
              ios_backgroundColor="#3e3e3e"
            />
          </View>

          <AppleButton
            title="Test 5-Second Alert"
            variant="secondary"
            onPress={() => {
              alert('A local notification will appear in 5 seconds. Minimize the app to see it!');
              NotificationService.testNotification();
            }}
          />
        </LiquidGlassCard>

        <AppleButton
          title="Edit Health Profile"
          variant="secondary"
          icon="pencil"
          onPress={() => {
            router.push('/onboarding');
          }}
          style={{ marginTop: 6, marginBottom: 16 }}
        />

        <AppleButton
          title="Reset App & Erase Data"
          variant="destructive"
          onPress={async () => {
             await AsyncStorage.removeItem('@user_profile');
             router.replace('/onboarding');
          }}
          style={{ marginBottom: 24 }}
        />
      </ScrollView>
    </SafeAreaView>
  );
}
