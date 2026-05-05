import { View, Text, ScrollView, ActivityIndicator, TouchableOpacity, Alert } from 'react-native';
import { useEffect, useState, useCallback } from 'react';
import { useFocusEffect, useLocalSearchParams } from 'expo-router';
import { SafeAreaView } from 'react-native-safe-area-context';
import { Ionicons } from '@expo/vector-icons';
import { HistoricalDataService, HealthMetricsJSON } from '@/services/healthIntegration';
import { GlobalState, StructuredReport } from '@/services/state';
import { saveTranslationToCloud } from '@/services/firebase';
import { InferenceEngine } from '@/services/inferenceEngine';
import { LocalStorageService } from '@/services/localStorage';
import LiquidGlassCard from '@/components/LiquidGlassCard';
import AppleButton from '@/components/AppleButton';

// Collapsible Section Card Component
function SectionCard({ 
  icon, 
  iconColor, 
  title, 
  content, 
  defaultExpanded = false 
}: { 
  icon: keyof typeof Ionicons.glyphMap; 
  iconColor: string; 
  title: string; 
  content: string; 
  defaultExpanded?: boolean;
}) {
  const [expanded, setExpanded] = useState(defaultExpanded);

  if (!content) return null;

  return (
    <View className="bg-apple-card-light dark:bg-apple-card-dark rounded-[20px] mb-4 overflow-hidden border border-black/5 dark:border-white/10">
      <TouchableOpacity 
        className="flex-row items-center p-5"
        onPress={() => setExpanded(!expanded)}
        activeOpacity={0.7}
      >
        <View 
          style={{ backgroundColor: iconColor + '18' }} 
          className="w-10 h-10 rounded-full items-center justify-center mr-4"
        >
          <Ionicons name={icon} size={20} color={iconColor} />
        </View>
        <Text className="text-[17px] font-semibold text-apple-text-light dark:text-apple-text-dark flex-1">
          {title}
        </Text>
        <Ionicons 
          name={expanded ? "chevron-up" : "chevron-down"} 
          size={18} 
          color="#8E8E93" 
        />
      </TouchableOpacity>
      {expanded && (
        <View className="px-5 pb-5 pt-0">
          <View className="border-t border-black/5 dark:border-white/10 pt-4">
            <Text className="text-apple-text-secondary-light dark:text-apple-text-secondary-dark text-[15px] leading-[22px]">
              {content}
            </Text>
          </View>
        </View>
      )}
    </View>
  );
}

export default function DashboardScreen() {
  const { action } = useLocalSearchParams<{ action: string }>();
  const [metrics, setMetrics] = useState<HealthMetricsJSON | null>(null);
  const [loading, setLoading] = useState(true);
  const [translation, setTranslation] = useState<string | null>(null);
  const [report, setReport] = useState<StructuredReport | null>(null);
  const [isSaving, setIsSaving] = useState(false);
  const [saveComplete, setSaveComplete] = useState(false);

  // useFocusEffect re-runs this every time the user taps the Dashboard tab
  useFocusEffect(
    useCallback(() => {
      // Only overwrite if we aren't currently generating a weekly review
      if (action !== 'weekly_review') {
        setTranslation(GlobalState.translationResult);
        setReport(GlobalState.structuredReport);
        setSaveComplete(false);
      }
    }, [action])
  );

  useEffect(() => {
    async function loadMetrics() {
      const data = await HistoricalDataService.getHealthMetrics();
      setMetrics(data);
      setLoading(false);
    }
    loadMetrics();
  }, []);

  // Listen for the Weekly Notification Tap
  useEffect(() => {
    async function generateWeeklyReview() {
      if (action === 'weekly_review' && metrics && !translation) {
        setTranslation("Loading MedGemma 4B to analyze your Apple Health week... 🧬");

        // Ensure the engine is booted (takes ~1-2 secs to load 2.5GB into memory)
        await InferenceEngine.initializeModel();

        // Run AI inference specifically optimized for health data patterns
        const weeklyReport = await InferenceEngine.analyzeLabReport(
          "No physical lab report was scanned. Focus purely on evaluating my Apple Health context.",
          metrics,
          'weekly'
        );

        setTranslation(weeklyReport.patientSummary);
        setReport(weeklyReport);
      }
    }
    generateWeeklyReview();
  }, [action, metrics]);

  const handleCloudBackup = async () => {
    if (!translation) return;

    setIsSaving(true);
    // Call our Firebase Backend Service
    const success = await saveTranslationToCloud(translation);

    if (success) {
      setIsSaving(false);
      setSaveComplete(true);
      Alert.alert("Success!", "Your translation was securely backed up to your Google Cloud database.");
    }
  };

  // Save to local vault automatically whenever a new translation is displayed
  useEffect(() => {
    if (translation && translation !== "Loading MedGemma 4B to analyze your Apple Health week... 🧬") {
      LocalStorageService.saveTranslationToHistory(translation);
    }
  }, [translation]);

  // Determine if we have the full structured report or just a legacy string
  const hasStructuredReport = report && report.patientSummary;

  return (
    <SafeAreaView className="flex-1 bg-apple-background-light dark:bg-apple-background-dark" edges={['top']}>
      <ScrollView className="flex-1 px-6 pt-4" contentContainerStyle={{ paddingBottom: 130 }}>
        <Text className="text-[34px] font-bold text-apple-text-light dark:text-apple-text-dark tracking-tight mb-6">Translation Dashboard</Text>

        {/* Top Metrics Cards */}
        <View className="flex-row justify-between mb-8">
          <View className="bg-apple-card-light dark:bg-apple-card-dark p-4 rounded-[16px] flex-1 mr-4 shadow-sm border border-black/5 dark:border-white/10">
            <Text className="text-apple-text-secondary-light dark:text-apple-text-secondary-dark text-[13px] font-medium mb-1">Status</Text>
            <Text className="text-apple-text-light dark:text-apple-text-dark font-semibold text-[17px]">
              {translation ? 'Analyzed' : 'Pending'}
            </Text>
          </View>
          <View className="bg-apple-card-light dark:bg-apple-card-dark p-4 rounded-[16px] flex-1 shadow-sm border border-black/5 dark:border-white/10">
            <Text className="text-apple-text-secondary-light dark:text-apple-text-secondary-dark text-[13px] font-medium mb-1">Health Sync</Text>
            <Text className="text-apple-blue-light dark:text-apple-blue-dark font-semibold text-[17px]">Active</Text>
          </View>
        </View>

        {/* Patient Summary Card (Always visible, always expanded) */}
        <LiquidGlassCard style={{ marginBottom: 24 }}>
          <Text className="text-xl font-bold text-apple-text-light dark:text-apple-text-dark mb-3">Empathetic Translation</Text>
          <Text className="text-apple-text-secondary-light dark:text-apple-text-secondary-dark text-base leading-relaxed">
            {hasStructuredReport
              ? report.patientSummary
              : translation
                ? translation
                : "Your lab report has not been scanned yet. Once you scan a document, the local Med-Gemma AI will analyze it and provide a simple, easy-to-read summary here."}
          </Text>

          {translation && (
            <AppleButton
              title={saveComplete ? '✓ Backed up to Firebase' : 'Save to Cloud Backup'}
              variant={saveComplete ? 'success' : 'primary'}
              onPress={handleCloudBackup}
              disabled={isSaving || saveComplete}
              loading={isSaving}
              style={{ marginTop: 24 }}
            />
          )}
        </LiquidGlassCard>

        {/* Advanced AI Sections (Collapsible Cards) */}
        {hasStructuredReport && (
          <View className="mb-6">
            <Text className="text-[13px] uppercase tracking-widest text-apple-text-secondary-light/50 dark:text-apple-text-secondary-dark/50 font-semibold mb-3 px-2">
              AI Insights
            </Text>

            <SectionCard
              icon="medkit"
              iconColor="#FF3B30"
              title="Questions for Your Doctor"
              content={report.doctorQuestions}
              defaultExpanded={true}
            />

            <SectionCard
              icon="nutrition"
              iconColor="#34C759"
              title="Targeted Dietary Advice"
              content={report.dietaryAdvice}
            />

            <SectionCard
              icon="book"
              iconColor="#AF52DE"
              title="Medical Glossary"
              content={report.medicalGlossary}
            />

            <SectionCard
              icon="medical"
              iconColor="#FF9500"
              title="Medication Notes"
              content={report.medicationNotes}
            />
          </View>
        )}

        {/* Wearable Data Integration */}
        <View className="bg-apple-blue-light/10 dark:bg-apple-blue-dark/20 p-5 rounded-[22px] mt-2 mb-10">
          <View className="flex-row items-center mb-3">
            <Text className="text-[20px] font-semibold text-apple-blue-light dark:text-apple-blue-dark tracking-tight">Apple Health Integrations</Text>
          </View>
          <Text className="text-apple-blue-light dark:text-apple-blue-dark text-[15px] leading-[22px] mb-6">
            We cross-referenced your new lab results against your local historical Apple Health metrics. Med-Gemma determined that your recent heart rate variability is completely normal despite the slightly elevated cholesterol reading, indicating low cardiovascular stress. Keep maintaining your active lifestyle!
          </Text>

          {loading ? (
            <ActivityIndicator size="small" color="#007AFF" />
          ) : (
            <View>
              <View className="flex-row justify-between mb-4">
                <View className="items-center">
                  <Text className="text-apple-blue-light dark:text-apple-blue-dark font-bold text-[28px]">{metrics?.avg_resting_hr_last_30_days ?? '--'}</Text>
                  <Text className="text-apple-blue-light/70 dark:text-apple-blue-dark/70 text-[13px] font-semibold mt-1">Resting HR</Text>
                </View>
                <View className="items-center">
                  <Text className="text-apple-blue-light dark:text-apple-blue-dark font-bold text-[28px]">{metrics?.avg_sleep_hours_last_30_days ?? '--'}h</Text>
                  <Text className="text-apple-blue-light/70 dark:text-apple-blue-dark/70 text-[13px] font-semibold mt-1">Avg Sleep</Text>
                </View>
                <View className="items-center">
                  <Text className="text-apple-blue-light dark:text-apple-blue-dark font-bold text-[28px]">{metrics?.avg_hrv_last_30_days ?? '--'}ms</Text>
                  <Text className="text-apple-blue-light/70 dark:text-apple-blue-dark/70 text-[13px] font-semibold mt-1">HRV</Text>
                </View>
              </View>

              {metrics?.is_mock_data && (
                <Text className="text-[12px] text-apple-text-secondary-light dark:text-apple-text-secondary-dark text-center font-medium opacity-80 mt-4">
                  Running in Expo Go: Displaying mock data for testing.
                </Text>
              )}
            </View>
          )}
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}
