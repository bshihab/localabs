import React, { useState, useEffect, useRef } from 'react';
import { View, Text, TextInput, TouchableOpacity, Switch, KeyboardAvoidingView, Platform, ScrollView, Dimensions, Alert, useColorScheme, StyleSheet } from 'react-native';
import { BlurView } from 'expo-blur';
import Animated, {
  FadeInRight,
  FadeOutLeft,
  useSharedValue,
  useAnimatedStyle,
  withSpring,
  interpolate,
  Extrapolation,
} from 'react-native-reanimated';
import { useRouter } from 'expo-router';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { Ionicons } from '@expo/vector-icons';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Picker } from '@react-native-picker/picker';
import AppleButton from '@/components/AppleButton';
import NativeMenuPicker from '@/components/NativeMenuPicker';
import { HistoricalDataService } from '@/services/healthIntegration';



const { height: screenHeight } = Dimensions.get('window');

// --- Conversion Helpers ---
function feetInchesToCm(feet: number, inches: number): number {
  return Math.round((feet * 12 + inches) * 2.54);
}

function cmToFeetInches(cm: number): { feet: number; inches: number } {
  const totalInches = Math.round(cm / 2.54);
  return { feet: Math.floor(totalInches / 12), inches: totalInches % 12 };
}

function lbsToKg(lbs: number): number {
  return Math.round(lbs * 0.453592);
}

function kgToLbs(kg: number): number {
  return Math.round(kg / 0.453592);
}

const PICKER_HEIGHT = 190;

// iOS-like spring config (matches UIKit's default spring)
const SPRING_CONFIG = {
  damping: 20,
  stiffness: 180,
  mass: 0.8,
  overshootClamping: false,
  restDisplacementThreshold: 0.01,
  restSpeedThreshold: 0.01,
};

// --- Inline Expanding Picker Row ---
function InlinePickerRow({
  title,
  displayValue,
  isExpanded,
  onToggle,
  hasBottomBorder = true,
  children,
}: {
  title: string;
  displayValue: string;
  isExpanded: boolean;
  onToggle: () => void;
  hasBottomBorder?: boolean;
  children: React.ReactNode;
}) {
  const colorScheme = useColorScheme();
  const isDark = colorScheme === 'dark';

  // Spring-driven expansion progress (0 = collapsed, 1 = expanded)
  const progress = useSharedValue(0);

  useEffect(() => {
    progress.value = withSpring(isExpanded ? 1 : 0, SPRING_CONFIG);
  }, [isExpanded]);

  const animatedContainerStyle = useAnimatedStyle(() => ({
    height: interpolate(progress.value, [0, 1], [0, PICKER_HEIGHT + 16], Extrapolation.CLAMP),
    opacity: interpolate(progress.value, [0, 0.3, 1], [0, 0.6, 1], Extrapolation.CLAMP),
    marginHorizontal: 8,
    marginBottom: interpolate(progress.value, [0, 1], [0, 8], Extrapolation.CLAMP),
    borderRadius: 12,
    overflow: 'hidden' as const,
  }));

  const chevronStyle = useAnimatedStyle(() => ({
    transform: [{ rotate: `${interpolate(progress.value, [0, 1], [0, 90], Extrapolation.CLAMP)}deg` }],
  }));

  return (
    <View className={hasBottomBorder ? 'border-b border-black/5 dark:border-white/10' : ''}>
      <TouchableOpacity
        className="flex-row justify-between items-center py-3.5 px-4"
        onPress={onToggle}
        activeOpacity={0.6}
      >
        <Text
          style={{ color: isExpanded ? (isDark ? '#0A84FF' : '#007AFF') : undefined }}
          className={isExpanded ? 'text-[17px] font-medium' : 'text-[17px] text-apple-text-light dark:text-apple-text-dark'}
        >
          {title}
        </Text>
        <View className="flex-row items-center">
          <Text
            className={`text-[17px] mr-2 ${
              displayValue && displayValue !== 'Not Set'
                ? 'text-apple-text-secondary-light dark:text-apple-text-secondary-dark'
                : 'text-apple-text-secondary-light/50 dark:text-apple-text-secondary-dark/50'
            }`}
          >
            {displayValue || 'Not Set'}
          </Text>
          <Animated.View style={chevronStyle}>
            <Ionicons
              name="chevron-forward"
              size={20}
              color={isExpanded ? (isDark ? '#0A84FF' : '#007AFF') : '#C7C7CC'}
            />
          </Animated.View>
        </View>
      </TouchableOpacity>
      <Animated.View style={animatedContainerStyle}>
        <BlurView
          intensity={isDark ? 50 : 70}
          tint={isDark ? 'dark' : 'light'}
          style={{
            flex: 1,
            borderRadius: 12,
            borderWidth: StyleSheet.hairlineWidth,
            borderColor: isDark ? 'rgba(255,255,255,0.15)' : 'rgba(0,0,0,0.08)',
            overflow: 'hidden',
          }}
        >
          <View
            style={{
              flex: 1,
              backgroundColor: isDark ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.025)',
            }}
          >
            {children}
          </View>
        </BlurView>
      </Animated.View>
    </View>
  );
}

// --- Unit Toggle Pill ---
function UnitToggle({ useImperial, onToggle }: { useImperial: boolean; onToggle: () => void }) {
  const colorScheme = useColorScheme();
  const isDark = colorScheme === 'dark';

  return (
    <TouchableOpacity
      onPress={onToggle}
      activeOpacity={0.7}
      style={{
        flexDirection: 'row',
        backgroundColor: isDark ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.05)',
        borderRadius: 20,
        padding: 3,
        alignItems: 'center',
      }}
    >
      <View
        style={{
          paddingHorizontal: 10,
          paddingVertical: 5,
          borderRadius: 17,
          backgroundColor: useImperial
            ? isDark ? 'rgba(10,132,255,0.25)' : 'rgba(0,122,255,0.15)'
            : 'transparent',
        }}
      >
        <Text
          style={{
            fontSize: 12,
            fontWeight: '600',
            color: useImperial
              ? isDark ? '#0A84FF' : '#007AFF'
              : isDark ? 'rgba(235,235,245,0.4)' : 'rgba(60,60,67,0.4)',
          }}
        >
          Imperial
        </Text>
      </View>
      <View
        style={{
          paddingHorizontal: 10,
          paddingVertical: 5,
          borderRadius: 17,
          backgroundColor: !useImperial
            ? isDark ? 'rgba(10,132,255,0.25)' : 'rgba(0,122,255,0.15)'
            : 'transparent',
        }}
      >
        <Text
          style={{
            fontSize: 12,
            fontWeight: '600',
            color: !useImperial
              ? isDark ? '#0A84FF' : '#007AFF'
              : isDark ? 'rgba(235,235,245,0.4)' : 'rgba(60,60,67,0.4)',
          }}
        >
          Metric
        </Text>
      </View>
    </TouchableOpacity>
  );
}

export default function OnboardingScreen() {
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const colorScheme = useColorScheme();
  const isDark = colorScheme === 'dark';
  const [step, setStep] = useState(0);

  // Form State
  const [age, setAge] = useState('');
  const [sex, setSex] = useState('');
  const [bloodType, setBloodType] = useState('');
  const [height, setHeight] = useState('');
  const [weight, setWeight] = useState('');
  const [wheelchair, setWheelchair] = useState('');
  const [smoking, setSmoking] = useState('');
  const [alcohol, setAlcohol] = useState('');
  const [familyHistory, setFamilyHistory] = useState('');
  const [cardiovascular, setCardiovascular] = useState('');
  const [metabolic, setMetabolic] = useState('');
  const [respiratory, setRespiratory] = useState('');
  const [conditions, setConditions] = useState('');
  const [agreed, setAgreed] = useState(false);

  // Unit system
  const [useImperial, setUseImperial] = useState(true);

  // Inline picker values (always stored in imperial internally)
  const [ageVal, setAgeVal] = useState(25);
  const [heightFeet, setHeightFeet] = useState(5);
  const [heightInches, setHeightInches] = useState(8);
  const [heightCm, setHeightCm] = useState(173);
  const [weightLbs, setWeightLbs] = useState(150);
  const [weightKg, setWeightKg] = useState(68);

  // Inline expansion state
  const [expandedPicker, setExpandedPicker] = useState<string | null>(null);

  const togglePicker = (picker: string) => {
    setExpandedPicker((prev) => (prev === picker ? null : picker));
  };

  // Sync imperial <-> metric when values change
  useEffect(() => {
    const cm = feetInchesToCm(heightFeet, heightInches);
    setHeightCm(cm);
  }, [heightFeet, heightInches]);

  useEffect(() => {
    setWeightKg(lbsToKg(weightLbs));
  }, [weightLbs]);

  // Update the display strings when picker values change
  useEffect(() => {
    setAge(ageVal.toString());
  }, [ageVal]);

  useEffect(() => {
    if (useImperial) {
      setHeight(`${heightFeet}'${heightInches}"`);
    } else {
      setHeight(`${heightCm} cm`);
    }
  }, [heightFeet, heightInches, heightCm, useImperial]);

  useEffect(() => {
    if (useImperial) {
      setWeight(`${weightLbs} lbs`);
    } else {
      setWeight(`${weightKg} kg`);
    }
  }, [weightLbs, weightKg, useImperial]);

  // Handle unit toggle
  const handleUnitToggle = () => {
    setUseImperial((prev) => {
      const next = !prev;
      if (next) {
        // Switching to imperial: convert current metric values
        const { feet, inches } = cmToFeetInches(heightCm);
        setHeightFeet(feet);
        setHeightInches(inches);
        setWeightLbs(kgToLbs(weightKg));
      } else {
        // Switching to metric: convert current imperial values
        setHeightCm(feetInchesToCm(heightFeet, heightInches));
        setWeightKg(lbsToKg(weightLbs));
      }
      return next;
    });
  };

  // Edit Profile Hydration Loop
  useEffect(() => {
    async function hydrateState() {
      const stored = await AsyncStorage.getItem('@user_profile');
      if (stored) {
        const data = JSON.parse(stored);
        if (data.age) {
          setAge(data.age);
          const parsed = parseInt(data.age);
          if (!isNaN(parsed)) setAgeVal(parsed);
        }
        if (data.biologicalSex) setSex(data.biologicalSex);
        if (data.bloodType) setBloodType(data.bloodType);
        if (data.height) setHeight(data.height);
        if (data.weight) setWeight(data.weight);
        if (data.wheelchair) setWheelchair(data.wheelchair);
        if (data.smoking) setSmoking(data.smoking);
        if (data.alcohol) setAlcohol(data.alcohol);
        if (data.familyHistory) setFamilyHistory(data.familyHistory);
        if (data.cardiovascular) setCardiovascular(data.cardiovascular);
        if (data.metabolic) setMetabolic(data.metabolic);
        if (data.respiratory) setRespiratory(data.respiratory);
        if (data.medicalConditions) setConditions(data.medicalConditions);
        if (data.useImperial !== undefined) setUseImperial(data.useImperial);

        // Hydrate picker values from stored height/weight
        if (data.heightFeet !== undefined) setHeightFeet(data.heightFeet);
        if (data.heightInches !== undefined) setHeightInches(data.heightInches);
        if (data.heightCm !== undefined) setHeightCm(data.heightCm);
        if (data.weightLbs !== undefined) setWeightLbs(data.weightLbs);
        if (data.weightKg !== undefined) setWeightKg(data.weightKg);

        // Skip the Welcome Splash Screen if they are just editing their profile!
        if (data.onboardingComplete) {
          setAgreed(true);
          setStep(1);
        }
      }
    }
    hydrateState();
  }, []);

  const handleFinish = async () => {
    if (!agreed) return;

    const userProfile = {
      age,
      biologicalSex: sex,
      bloodType,
      height,
      weight,
      wheelchair,
      smoking,
      alcohol,
      familyHistory,
      cardiovascular,
      metabolic,
      respiratory,
      medicalConditions: conditions,
      onboardingComplete: true,
      useImperial,
      heightFeet,
      heightInches,
      heightCm,
      weightLbs,
      weightKg,
    };

    await AsyncStorage.setItem('@user_profile', JSON.stringify(userProfile));

    // Once saved, navigate directly to the dashboard
    router.replace('/(tabs)');
  };

  const FeatureRow = ({ icon, title, subtitle }: { icon: keyof typeof Ionicons.glyphMap, title: string, subtitle: string }) => (
    <View className="flex-row items-start mb-8 w-full px-6">
      <View className="w-12 h-12 bg-apple-blue-light/10 dark:bg-apple-blue-dark/20 rounded-full items-center justify-center mr-4 mt-1">
        <Ionicons name={icon} size={24} color="#007AFF" />
      </View>
      <View className="flex-1">
        <Text className="text-[17px] font-semibold text-apple-text-light dark:text-apple-text-dark mb-1 tracking-tight">{title}</Text>
        <Text className="text-[15px] text-apple-text-secondary-light dark:text-apple-text-secondary-dark leading-[20px]">{subtitle}</Text>
      </View>
    </View>
  );

  // --- Display values ---
  const ageDisplay = age ? `Age ${age}` : 'Not Set';
  const heightDisplay = height || 'Not Set';
  const weightDisplay = weight || 'Not Set';

  return (
    <KeyboardAvoidingView
      behavior={Platform.OS === 'ios' ? 'padding' : 'height'}
      className="flex-1 bg-apple-background-light dark:bg-apple-background-dark"
    >
      <ScrollView contentContainerStyle={{ flexGrow: 1, justifyContent: 'flex-start' }}>

        {/* STEP 0: HIG Welcome Screen */}
        {step === 0 && (
          <View className="flex-1 justify-between pb-12" style={{ paddingTop: insets.top + 20 }}>
            <View className="items-center w-full">
              <Text className="text-[34px] font-bold text-apple-text-light dark:text-apple-text-dark tracking-tight mb-16 text-center px-4">
                Welcome to{'\n'}Med-Gemma
              </Text>

              <FeatureRow
                icon="shield-checkmark"
                title="Total Privacy"
                subtitle="Your medical data stays on your device. Zero clinical information is sent to the cloud by default."
              />
              <FeatureRow
                icon="flash"
                title="On-Device Intelligence"
                subtitle="Analyzes complex lab reports instantly using a locally running inference engine optimized for Apple Metal."
              />
              <FeatureRow
                icon="heart"
                title="Health Integration"
                subtitle="Cross-references your iPhone's vitals (HR, Sleep) against your paper lab reports."
              />
            </View>

            <View className="px-6 mt-10">
              <AppleButton
                title="Continue"
                variant="primary"
                onPress={() => setStep(1)}
              />
            </View>
          </View>
        )}

        {/* STEP 1: Basic Intake */}
        {step === 1 && (
          <Animated.View entering={FadeInRight} exiting={FadeOutLeft} className="w-full flex-1 px-6 pb-12 justify-between" style={{ paddingTop: insets.top + 30 }}>
            <View>
              {/* Header with unit toggle */}
              <View className="flex-row justify-between items-center mb-2">
                <Text className="text-left text-[13px] font-semibold tracking-widest text-apple-text-secondary-light/50 dark:text-apple-text-secondary-dark/50 uppercase">Step 1 of 3</Text>
                <UnitToggle useImperial={useImperial} onToggle={handleUnitToggle} />
              </View>
              <Text className="text-[34px] font-bold text-apple-text-light dark:text-apple-text-dark mb-6 tracking-tight">Health Details</Text>

              <AppleButton
                title="Sync with Apple Health"
                icon="heart"
                animateIcon="pulse"
                variant="secondary"
                onPress={async () => {
                  const data = await HistoricalDataService.getDemographics();
                  if (data.age) {
                    setAge(data.age.toString());
                    setAgeVal(typeof data.age === 'number' ? data.age : parseInt(data.age) || 25);
                  }
                  if (data.biologicalSex) setSex(data.biologicalSex);
                  if (data.bloodType) setBloodType(data.bloodType);
                  if (data.height) setHeight(data.height);
                  if (data.weight) setWeight(data.weight);
                  if ((data as any).wheelchair) setWheelchair((data as any).wheelchair);
                }}
                style={{ marginBottom: 32 }}
              />

              <View className="bg-apple-card-light dark:bg-apple-card-dark rounded-[10px] overflow-hidden border border-black/5 dark:border-white/10">

                {/* Age Picker */}
                <InlinePickerRow
                  title="Age"
                  displayValue={ageDisplay}
                  isExpanded={expandedPicker === 'age'}
                  onToggle={() => togglePicker('age')}
                >
                  <View style={{ height: 180 }}>
                    <Picker
                      selectedValue={ageVal}
                      onValueChange={(val) => setAgeVal(val)}
                      itemStyle={{ color: isDark ? '#FFF' : '#000', fontSize: 23 }}
                    >
                      {Array.from({ length: 120 }, (_, i) => i + 1).map((a) => (
                        <Picker.Item key={a} label={`${a} years`} value={a} />
                      ))}
                    </Picker>
                  </View>
                </InlinePickerRow>

                {/* Sex */}
                <NativeMenuPicker
                  title="Sex"
                  value={sex}
                  onSelect={setSex}
                  options={['Male', 'Female', 'Other']}
                />

                {/* Blood Type */}
                <NativeMenuPicker
                  title="Blood Type"
                  value={bloodType}
                  onSelect={setBloodType}
                  options={['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-']}
                />

                {/* Height Picker */}
                <InlinePickerRow
                  title="Height"
                  displayValue={heightDisplay}
                  isExpanded={expandedPicker === 'height'}
                  onToggle={() => togglePicker('height')}
                >
                  <View style={{ height: 180, flexDirection: 'row' }}>
                    {useImperial ? (
                      <>
                        <Picker
                          style={{ flex: 1 }}
                          selectedValue={heightFeet}
                          onValueChange={(val) => setHeightFeet(val)}
                          itemStyle={{ color: isDark ? '#FFF' : '#000', fontSize: 23 }}
                        >
                          {[3, 4, 5, 6, 7, 8].map((ft) => (
                            <Picker.Item key={ft} label={`${ft} ft`} value={ft} />
                          ))}
                        </Picker>
                        <Picker
                          style={{ flex: 1 }}
                          selectedValue={heightInches}
                          onValueChange={(val) => setHeightInches(val)}
                          itemStyle={{ color: isDark ? '#FFF' : '#000', fontSize: 23 }}
                        >
                          {[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11].map((inc) => (
                            <Picker.Item key={inc} label={`${inc} in`} value={inc} />
                          ))}
                        </Picker>
                      </>
                    ) : (
                      <Picker
                        style={{ flex: 1 }}
                        selectedValue={heightCm}
                        onValueChange={(val) => {
                          setHeightCm(val);
                          const { feet, inches } = cmToFeetInches(val);
                          setHeightFeet(feet);
                          setHeightInches(inches);
                        }}
                        itemStyle={{ color: isDark ? '#FFF' : '#000', fontSize: 23 }}
                      >
                        {Array.from({ length: 151 }, (_, i) => i + 100).map((cm) => (
                          <Picker.Item key={cm} label={`${cm} cm`} value={cm} />
                        ))}
                      </Picker>
                    )}
                  </View>
                </InlinePickerRow>

                {/* Weight Picker */}
                <InlinePickerRow
                  title="Weight"
                  displayValue={weightDisplay}
                  isExpanded={expandedPicker === 'weight'}
                  onToggle={() => togglePicker('weight')}
                >
                  <View style={{ height: 180 }}>
                    {useImperial ? (
                      <Picker
                        style={{ flex: 1 }}
                        selectedValue={weightLbs}
                        onValueChange={(val) => {
                          setWeightLbs(val);
                          setWeightKg(lbsToKg(val));
                        }}
                        itemStyle={{ color: isDark ? '#FFF' : '#000', fontSize: 23 }}
                      >
                        {Array.from({ length: 400 }, (_, i) => i + 50).map((w) => (
                          <Picker.Item key={w} label={`${w} lbs`} value={w} />
                        ))}
                      </Picker>
                    ) : (
                      <Picker
                        style={{ flex: 1 }}
                        selectedValue={weightKg}
                        onValueChange={(val) => {
                          setWeightKg(val);
                          setWeightLbs(kgToLbs(val));
                        }}
                        itemStyle={{ color: isDark ? '#FFF' : '#000', fontSize: 23 }}
                      >
                        {Array.from({ length: 200 }, (_, i) => i + 20).map((kg) => (
                          <Picker.Item key={kg} label={`${kg} kg`} value={kg} />
                        ))}
                      </Picker>
                    )}
                  </View>
                </InlinePickerRow>

                {/* Wheelchair */}
                <NativeMenuPicker
                  title="Wheelchair Use"
                  value={wheelchair}
                  onSelect={setWheelchair}
                  hasBottomBorder={false}
                  options={['No', 'Yes']}
                />
              </View>
            </View>

            <AppleButton
              title="Continue"
              disabled={!age || !sex}
              onPress={() => setStep(2)}
            />
          </Animated.View>
        )}

        {/* STEP 2: Conditions */}
        {step === 2 && (
          <Animated.View entering={FadeInRight} exiting={FadeOutLeft} className="w-full flex-1 px-6 pb-12 justify-between" style={{ paddingTop: insets.top + 30 }}>
            <ScrollView showsVerticalScrollIndicator={false}>
              <Text className="text-left text-[13px] font-semibold tracking-widest text-apple-text-secondary-light/50 dark:text-apple-text-secondary-dark/50 uppercase mb-2">Step 2 of 3</Text>
              <Text className="text-[34px] font-bold text-apple-text-light dark:text-apple-text-dark mb-6 tracking-tight">Clinical Details</Text>

              <View className="bg-apple-card-light dark:bg-apple-card-dark rounded-[10px] overflow-hidden border border-black/5 dark:border-white/10 mb-8">
                <NativeMenuPicker
                  title="Tobacco / E-Cig"
                  value={smoking}
                  onSelect={setSmoking}
                  options={['Never', 'Former', 'Current']}
                />
                <NativeMenuPicker
                  title="Alcohol Use"
                  value={alcohol}
                  onSelect={setAlcohol}
                  options={['None', 'Rarely', 'Occasionally', 'Daily']}
                />
                <NativeMenuPicker
                  title="Family History"
                  value={familyHistory}
                  onSelect={setFamilyHistory}
                  hasBottomBorder={false}
                  options={['None Known', 'Heart Disease', 'Diabetes', 'Cancer', 'Other']}
                />
              </View>

              <Text className="text-apple-text-light dark:text-apple-text-dark font-medium text-[17px] mb-2 px-2">Primary Systems</Text>
              <View className="bg-apple-card-light dark:bg-apple-card-dark rounded-[10px] overflow-hidden border border-black/5 dark:border-white/10 mb-8">
                <NativeMenuPicker
                  title="Cardiovascular"
                  value={cardiovascular}
                  onSelect={setCardiovascular}
                  options={['None', 'Hypertension', 'Arrhythmia', 'Heart Disease']}
                />
                <NativeMenuPicker
                  title="Metabolic"
                  value={metabolic}
                  onSelect={setMetabolic}
                  options={['None', 'Prediabetes', 'Diabetes', 'Thyroid Disorder']}
                />
                <NativeMenuPicker
                  title="Respiratory"
                  value={respiratory}
                  onSelect={setRespiratory}
                  hasBottomBorder={false}
                  options={['None', 'Asthma', 'COPD']}
                />
              </View>

              <Text className="text-apple-text-light dark:text-apple-text-dark font-medium text-[17px] mb-2 px-2">Other Context</Text>
              <TextInput
                className="bg-black/5 dark:bg-white/10 rounded-[16px] p-4 text-[17px] text-apple-text-light dark:text-apple-text-dark h-24 mb-6"
                placeholder="e.g. Chronic migraines, surgeries..."
                placeholderTextColor="#9CA3AF"
                multiline
                textAlignVertical="top"
                value={conditions}
                onChangeText={setConditions}
              />

              <View className="px-2">
                <Text className="text-apple-text-light dark:text-apple-text-dark font-medium text-[17px] mb-2">Complex Medical History?</Text>
                <AppleButton
                  title="Scan Medical Records PDF"
                  icon="document-text"
                  variant="secondary"
                  style={{ marginBottom: 32 }}
                  onPress={() => {
                    Alert.alert("Scanner Activated", "Camera module will natively mount here to ingest the multi-page History PDF.");
                  }}
                />
              </View>
            </ScrollView>

            <View className="flex-row space-x-4 justify-between mt-4">
              <AppleButton title="Back" variant="secondary" style={{ width: 100 }} onPress={() => setStep(1)} />
              <View className="flex-1 ml-4"><AppleButton title="Continue" variant="primary" onPress={() => setStep(3)} /></View>
            </View>
          </Animated.View>
        )}

        {/* STEP 3: Privacy & Safety */}
        {step === 3 && (
          <Animated.View entering={FadeInRight} exiting={FadeOutLeft} className="w-full flex-1 px-6 pb-12 justify-between" style={{ paddingTop: insets.top + 30 }}>
            <View>
              <View className="w-16 h-16 bg-apple-red-light/10 dark:bg-apple-red-dark/20 rounded-full items-center justify-center mb-6">
                <Ionicons name="warning" size={32} color="#FF3B30" />
              </View>
              <Text className="text-[34px] font-bold text-apple-text-light dark:text-apple-text-dark mb-4 tracking-tight">Privacy & Safety</Text>

              <View className="bg-apple-card-light dark:bg-apple-card-dark p-6 rounded-[24px] shadow-sm border border-black/5 dark:border-white/10 mb-8">
                <Text className="text-apple-text-light dark:text-apple-text-dark font-medium mb-4 text-[15px] leading-[22px]">
                  1. <Text className="font-semibold text-apple-blue-light dark:text-apple-blue-dark">100% On-Device:</Text> MedGemma runs entirely on your phone's processor. Your sensitive health data and photos are NEVER sent to the cloud unless you explicitly turn on backups.
                </Text>
                <Text className="text-apple-text-light dark:text-apple-text-dark font-medium text-[15px] leading-[22px]">
                  2. <Text className="font-semibold text-apple-red-light dark:text-apple-red-dark">Not a Doctor:</Text> MedGemma is an experimental AI. It hallucinates. It is not a substitute for professional medical advice, diagnosis, or treatment.
                </Text>
              </View>

              <View className="flex-row items-center mb-10 px-2 justify-between">
                <Text className="text-apple-text-light dark:text-apple-text-dark font-semibold text-[17px] flex-1 mr-4">
                  I understand and agree to the terms above.
                </Text>
                <Switch
                  value={agreed}
                  onValueChange={setAgreed}
                  trackColor={{ false: '#D1D5DB', true: '#34C759' }}
                />
              </View>
            </View>

            <AppleButton
              title="Complete Setup"
              disabled={!agreed}
              onPress={handleFinish}
            />
          </Animated.View>
        )}

      </ScrollView>
    </KeyboardAvoidingView>
  );
}
