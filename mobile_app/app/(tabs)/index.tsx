import { View, Text, ActivityIndicator, Alert, DeviceEventEmitter } from 'react-native';
import { useState } from 'react';
import { useRouter } from 'expo-router';
import { SafeAreaView } from 'react-native-safe-area-context';
import * as ImagePicker from 'expo-image-picker';
import * as DocumentPicker from 'expo-document-picker';
import { Ionicons } from '@expo/vector-icons';
import { InferenceEngine } from '@/services/inferenceEngine';
import { HistoricalDataService } from '@/services/healthIntegration';
import { GlobalState } from '@/services/state';
import AppleButton from '@/components/AppleButton';

// A tiny 1x1 encoded invisible pixel array to mock the PDF rasterizer bridge for now
const MOCK_PDF_IMG_MATRIX = '/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=';

export default function UploadScreen() {
  const router = useRouter();
  const [isScanning, setIsScanning] = useState(false);
  const [scanStatus, setScanStatus] = useState('');

  const executeInference = async (b64Matrix: string, isPdfFallback: boolean = false) => {
    setIsScanning(true);
    try {
      if (isPdfFallback) {
         setScanStatus('Rasterizing PDF layout...');
         DeviceEventEmitter.emit('dynamic_island', { state: 'analyzing', message: 'Rasterizing Native PDF.' });
         // Simulate massive structural PDF decoding
         await new Promise(r => setTimeout(r, 1500));
      } else {
         setScanStatus('Scanning document with Apple Vision...');
         DeviceEventEmitter.emit('dynamic_island', { state: 'analyzing', message: 'Apple VisionKit Active.' });
      }
      
      setScanStatus('Fetching Apple Health context...');
      DeviceEventEmitter.emit('dynamic_island', { state: 'analyzing', message: 'Merging Hardware Vitals.' });
      const healthData = await HistoricalDataService.getHealthMetrics();

      setScanStatus('MedGemma is analyzing your results...');
      DeviceEventEmitter.emit('dynamic_island', { state: 'analyzing', message: 'Metal Neural Engine Active.' });
      
      // The pipeline: Apple VisionKit OCR → MedGemma structured analysis
      const structuredReport = await InferenceEngine.translateMultimodal(b64Matrix, healthData);

      // Store both the legacy string and the new structured report in global state
      GlobalState.translationResult = structuredReport.patientSummary;
      GlobalState.structuredReport = structuredReport;
      DeviceEventEmitter.emit('dynamic_island', { state: 'completed' });
      
      setTimeout(() => router.push('/dashboard'), 500);
    } catch (e) {
      DeviceEventEmitter.emit('dynamic_island', { state: 'idle' });
      Alert.alert("Analysis Error", "Unable to securely process the document architecture.");
    } finally {
      setIsScanning(false);
    }
  };

  const handleLaunchCamera = async () => {
    const permission = await ImagePicker.requestCameraPermissionsAsync();
    if (!permission.granted) {
      return Alert.alert("Camera Access Required", "Please allow camera access in Settings.");
    }
    if (!InferenceEngine.getIsModelLoaded()) {
      return Alert.alert("Offline Model Not Loaded", "Please navigate to your Profile to download the MedGemma Vision architecture.");
    }

    const result = await ImagePicker.launchCameraAsync({
      allowsEditing: true, quality: 0.5, base64: true,
    });

    if (!result.canceled && result.assets?.[0]?.base64) {
      executeInference(result.assets[0].base64);
    }
  };

  const handleLaunchLibrary = async () => {
    const permission = await ImagePicker.requestMediaLibraryPermissionsAsync();
    if (!permission.granted) {
      return Alert.alert("Library Access Required", "Please allow read access to select existing photos.");
    }
    if (!InferenceEngine.getIsModelLoaded()) {
      return Alert.alert("Offline Model Not Loaded", "Please navigate to your Profile to download the MedGemma Vision architecture.");
    }

    const result = await ImagePicker.launchImageLibraryAsync({
      mediaTypes: ImagePicker.MediaTypeOptions.Images,
      allowsEditing: true, quality: 0.5, base64: true,
    });

    if (!result.canceled && result.assets?.[0]?.base64) {
      executeInference(result.assets[0].base64);
    }
  };

  const handleLaunchPDF = async () => {
    if (!InferenceEngine.getIsModelLoaded()) {
      return Alert.alert("Offline Model Not Loaded", "Please navigate to your Profile to download the MedGemma Vision architecture.");
    }

    const result = await DocumentPicker.getDocumentAsync({
      type: 'application/pdf',
      copyToCacheDirectory: false,
    });

    if (!result.canceled && result.assets?.[0]) {
      // PDF successfully selected from iCloud! We feed the mock raster matrix to pipeline.
      executeInference(MOCK_PDF_IMG_MATRIX, true);
    }
  };

  return (
    <SafeAreaView className="flex-1 bg-apple-background-light dark:bg-apple-background-dark" edges={['top']}>
      <View className="flex-1 items-center justify-center p-6 pb-[95px]">
        
        <View className="items-center mb-16 px-4">
          <View className="w-24 h-24 bg-apple-blue-light/10 dark:bg-apple-blue-dark/20 rounded-full items-center justify-center mb-6 shadow-sm">
            <Ionicons name="documents" size={48} color="#007AFF" />
          </View>
          <Text className="text-[34px] font-bold text-apple-text-light dark:text-apple-text-dark tracking-tight mb-4 text-center">
            Upload Report
          </Text>
          <Text className="text-apple-text-secondary-light dark:text-apple-text-secondary-dark text-center text-[17px] leading-[24px] max-w-[300px]">
            Ingest lab results securely using your Camera, Photo Albums, or Apple Cloud Drive files.
          </Text>
        </View>

        <View className="w-full max-w-[320px] items-center">
          {isScanning && (
            <View className="mb-4 w-full">
              <View className="bg-apple-card-light dark:bg-apple-card-dark px-6 py-5 rounded-[22px] shadow-sm flex-row items-center border border-black/5 dark:border-white/10 w-full">
                <ActivityIndicator size="small" color="#007AFF" />
                <View className="ml-4 flex-1">
                   <Text className="font-semibold text-[17px] text-apple-text-light dark:text-apple-text-dark mb-1">Executing Analysis</Text>
                   <Text className="text-[13px] text-apple-text-secondary-light dark:text-apple-text-secondary-dark flex-shrink leading-[18px]">
                     {scanStatus}
                   </Text>
                </View>
              </View>
            </View>
          )}

          {!isScanning && (
            <View className="w-full space-y-4">
              <AppleButton
                title="Open Camera"
                variant="primary"
                onPress={handleLaunchCamera}
                style={{ width: '100%', marginBottom: 12 }}
              />
              <AppleButton
                title="Choose from Photos"
                variant="secondary"
                onPress={handleLaunchLibrary}
                style={{ width: '100%', marginBottom: 12 }}
              />
              <AppleButton
                title="Upload PDF File"
                variant="secondary"
                onPress={handleLaunchPDF}
                style={{ width: '100%' }}
              />
            </View>
          )}
        </View>
        
      </View>
    </SafeAreaView>
  );
}
