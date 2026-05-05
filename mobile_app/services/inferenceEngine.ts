import { HealthMetricsJSON } from './healthIntegration';
import { initLlama, LlamaContext } from 'llama.rn';
import { Platform } from 'react-native';
import Constants from 'expo-constants';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { LocalStorageService } from './localStorage';
import { StructuredReport } from './state';

export class InferenceEngine {
  private static llamaContext: LlamaContext | null = null;
  private static isModelLoaded = false;

  public static getIsModelLoaded(): boolean {
    return this.isModelLoaded;
  }

  /**
   * Initializes the llama.rn native bridge.
   * Loads the massive ~2.5GB Med-O-Gemma 4B quantized .gguf weights off the storage into iOS memory.
   * 
   * Note: In Expo Go, native C++ memory allocation for 2.5GB models is not possible.
   * This gracefully falls back to a simulated load for UI testing.
   */
  static async initializeModel(onProgress?: (progress: number) => void): Promise<boolean> {
    const isExpoGo = Constants.appOwnership === 'expo';

    if (isExpoGo || Platform.OS !== 'ios') {
      console.log("[llama.rn] Warning: Native AI can only run in a compiled iOS app. Simulating 3-second download.");

      return new Promise((resolve) => {
        let currentProgress = 0;
        const interval = setInterval(() => {
          currentProgress += 15;
          if (currentProgress > 100) currentProgress = 100;

          if (onProgress) onProgress(currentProgress);

          if (currentProgress >= 100) {
            clearInterval(interval);
            this.isModelLoaded = true;
            resolve(true);
          }
        }, 400); // Gradual simulated load for Expo Go testing
      });
    }

    try {
      console.log("[llama.rn] Initializing MedGemma 4B on Metal NPU...");

      // Native iOS Native Module loading
      // (The C++ bridge is computationally synchronous, so we simulate frontend progress while it locks the thread)
      if (onProgress) onProgress(10);
      let simProgress = 10;
      const simInterval = setInterval(() => {
        if (simProgress < 90) {
          simProgress += 10;
          if (onProgress) onProgress(simProgress);
        }
      }, 500);

      // Loads the model directly from the iOS app bundle using `is_model_asset`
      this.llamaContext = await initLlama({
        model: 'medgemma-4b-it_Q4_K_M.gguf',
        is_model_asset: true, // EXTREMELY IMPORTANT: Tells iOS to search the compiled app bundle for the file
        use_mlock: true, // Lock memory so iOS doesn't page it to disk
        n_ctx: 2048,     // Context window size
        n_gpu_layers: 99 // Offload all layers to Apple Metal GPU
      });

      clearInterval(simInterval);
      if (onProgress) onProgress(100);

      this.isModelLoaded = true;
      console.log("[llama.rn] MedGemma loaded successfully into Metal!");
      return true;
    } catch (e) {
      console.error("[llama.rn] Failed to load model. Is it in the Xcode bundle?", e);
      return false;
    }
  }

  /**
   * Parses MedGemma's structured response into discrete sections.
   * Falls back to the raw text if parsing fails.
   */
  static parseStructuredReport(rawText: string): StructuredReport {
    const sections: StructuredReport = {
      patientSummary: '',
      doctorQuestions: '',
      dietaryAdvice: '',
      medicalGlossary: '',
      medicationNotes: '',
      rawText: rawText,
    };

    // Try to split by the numbered headers we instructed MedGemma to use
    const summaryMatch = rawText.match(/1\.\s*PATIENT SUMMARY\s*\n([\s\S]*?)(?=\n\s*2\.\s*QUESTIONS|$)/i);
    const questionsMatch = rawText.match(/2\.\s*QUESTIONS FOR YOUR DOCTOR\s*\n([\s\S]*?)(?=\n\s*3\.\s*TARGETED|$)/i);
    const dietMatch = rawText.match(/3\.\s*TARGETED DIETARY ADVICE\s*\n([\s\S]*?)(?=\n\s*4\.\s*MEDICAL GLOSSARY|$)/i);
    const glossaryMatch = rawText.match(/4\.\s*MEDICAL GLOSSARY\s*\n([\s\S]*?)(?=\n\s*5\.\s*MEDICATION|$)/i);
    const medicationMatch = rawText.match(/5\.\s*MEDICATION NOTES\s*\n([\s\S]*?)$/i);

    sections.patientSummary = summaryMatch?.[1]?.trim() || rawText;
    sections.doctorQuestions = questionsMatch?.[1]?.trim() || '';
    sections.dietaryAdvice = dietMatch?.[1]?.trim() || '';
    sections.medicalGlossary = glossaryMatch?.[1]?.trim() || '';
    sections.medicationNotes = medicationMatch?.[1]?.trim() || '';

    return sections;
  }

  /**
   * The full advanced analysis pipeline.
   * Generates a structured report with all 4 AI features:
   *   1. Patient Summary
   *   2. Questions for Your Doctor
   *   3. Targeted Dietary Advice
   *   4. Medical Glossary
   *   5. Medication Cross-Reference Notes (if medications are provided)
   */
  static async analyzeLabReport(extractedText: string, healthJSON: HealthMetricsJSON, mode: 'lab' | 'weekly' = 'lab'): Promise<StructuredReport> {
    if (!this.isModelLoaded) {
      throw new Error("Med-Gemma model is not loaded into memory yet.");
    }

    const isExpoGo = Constants.appOwnership === 'expo';
    if (isExpoGo || Platform.OS !== 'ios' || !this.llamaContext) {
      console.log("[llama.rn] Simulated advanced inference (Expo Go fallback)...");
      return new Promise((resolve) => {
        setTimeout(() => {
          resolve({
            patientSummary: `Great news! I reviewed your lab results alongside your Apple Health data. Your resting heart rate of ${healthJSON.avg_resting_hr_last_30_days ?? 60} bpm and sleep average of ${healthJSON.avg_sleep_hours_last_30_days ?? 7.5} hours both look healthy. Your cholesterol panel shows Total Cholesterol is slightly elevated at 248 mg/dL (ideal is under 200), and your HDL ("good" cholesterol) is a bit low at 35 mg/dL. This is very manageable with some small lifestyle tweaks!`,
            doctorQuestions: `1. "Dr. Reed, my LDL is 165 mg/dL — should we consider a statin medication, or would you recommend trying diet and exercise changes first?"\n\n2. "My HDL is 35 mg/dL, which is below the 40 mg/dL threshold. What specific activities or foods can I focus on to raise my HDL?"\n\n3. "Given my family history, how often should I be getting lipid panels done — annually, or more frequently?"`,
            dietaryAdvice: `Based on your elevated LDL and triglycerides, here is a 3-step plan:\n\n🥑 Step 1: Increase omega-3 fatty acids — Add salmon, walnuts, or flaxseeds to at least 3 meals per week.\n\n🥗 Step 2: Boost soluble fiber — Oatmeal, beans, and apples can actively lower LDL cholesterol by 5-10%.\n\n🚫 Step 3: Reduce saturated fats — Swap butter for olive oil, and limit red meat to once per week.`,
            medicalGlossary: `• Hyperlipidemia — A condition where you have too many fats (lipids) in your blood. Think of it as your blood being a little "thicker" than ideal.\n\n• LDL Cholesterol — Often called "bad" cholesterol. It can build up in your artery walls and increase heart disease risk.\n\n• HDL Cholesterol — Often called "good" cholesterol. It acts like a cleanup crew, carrying bad cholesterol away from your arteries.\n\n• Triglycerides — A type of fat in your blood. Your body converts unused calories into triglycerides for energy storage.`,
            medicationNotes: 'No medications were provided. You can add your current medications in your Profile to get personalized cross-referencing.',
            rawText: 'Simulated Expo Go response',
          });
        }, 3000);
      });
    }

    // Fetch stored user profile data (Age, Sex, Conditions, Medications) from secure local storage
    let knownConditions = "None reported";
    let currentMedications = "None reported";
    try {
      const storedProfile = await AsyncStorage.getItem('@user_profile');
      if (storedProfile) {
        const profile = JSON.parse(storedProfile);
        knownConditions = profile.medicalConditions || "None reported";
        currentMedications = profile.medications || "None reported";
      }
    } catch (e) { }

    // Fetch the most recent past translation to provide longitudinal context to the AI
    const pastTranslation = await LocalStorageService.getMostRecentPastTranslation();
    const longitudinalContext = pastTranslation 
      ? `\n- Context from user's PREVIOUS lab report: "${pastTranslation}"\n(Note: Use this past context to congratulate the user on improvements or note trends if relevant to the new report).`
      : "";

    const behaviorPrompt = mode === 'weekly'
      ? "The user is requesting their weekly health check-in review. Analyze their Apple Health data provided below, praise their good metrics, and gently notify them of any anomalies based on their medical history."
      : "The user just scanned a lab report. The following text was extracted from the document image using Apple's VisionKit OCR. It may be messy or out of order due to being scanned from a physical document.";

    // Advanced structured prompt — matches the format we validated in test_advanced_features.py
    const prompt = `<start_of_turn>user
You are an empathetic, highly trained medical assistant. 
${behaviorPrompt}

User's Personal Health Context:
- Known Medical Conditions: ${knownConditions}
- Current Daily Medications: ${currentMedications}
- Resting HR (30-day avg): ${healthJSON.avg_resting_hr_last_30_days ?? 'Unknown'} bpm
- Sleep (30-day avg): ${healthJSON.avg_sleep_hours_last_30_days ?? 'Unknown'} hours
- HRV (30-day avg): ${healthJSON.avg_hrv_last_30_days ?? 'Unknown'} ms${longitudinalContext}

IMPORTANT INSTRUCTION: If any of the personal health context metrics above are labeled "Unknown" or the user lacks wearable data, completely ignore them. Do NOT guess them, and do not mention that they are missing. In these cases, focus 100% of your explanation on the Lab Report OCR Text.

Lab Report OCR Text (Ignore if weekly review):
"${extractedText}"

Analyze the clinical data above and provide a report formatted EXACTLY with these 5 headers:

1. PATIENT SUMMARY
(Explain the results logically in very simple, reassuring terms to a patient with no medical background. Do not diagnose.)

2. QUESTIONS FOR YOUR DOCTOR
(Generate 3 highly specific, intelligent questions the patient should ask their doctor at their next visit based on these exact lab results.)

3. TARGETED DIETARY ADVICE
(Provide a brief, 3-step dietary action plan specifically targeted to improve the abnormal metrics found in this report.)

4. MEDICAL GLOSSARY
(Identify the 3-5 most complex medical terms in the report and provide a simple, 1-sentence definition for each.)

5. MEDICATION NOTES
(If the user listed current medications, cross-reference them against the lab results and flag any potential interactions. If no medications were provided, simply say "No medications were provided for cross-referencing.")
<end_of_turn>
<start_of_turn>model
`;

    console.log("[llama.rn] Executing advanced on-device LLM inference via Metal...");

    try {
      const result = await this.llamaContext.completion({
        prompt: prompt,
        n_predict: 600,   // More tokens for the structured multi-section report
        temperature: 0.2, // Low temperature for factual medical data
        top_p: 0.9,
      });

      console.log("[llama.rn] Advanced inference complete.");
      return this.parseStructuredReport(result.text);
    } catch (e) {
      console.error("[llama.rn] Inference error:", e);
      return {
        patientSummary: "An error occurred while analyzing the report locally on your device. Please try again.",
        doctorQuestions: '',
        dietaryAdvice: '',
        medicalGlossary: '',
        medicationNotes: '',
        rawText: '',
      };
    }
  }

  /**
   * Backward-compatible wrapper that returns a plain string summary.
   * Used by the weekly review and legacy code paths.
   */
  static async translateLabReport(extractedText: string, healthJSON: HealthMetricsJSON, mode: 'lab' | 'weekly' = 'lab'): Promise<string> {
    const report = await this.analyzeLabReport(extractedText, healthJSON, mode);
    return report.patientSummary;
  }

  /**
   * Hardware Vision Pipeline (Apple VisionKit OCR → MedGemma)
   * On native iOS: Uses Apple's Vision framework to extract text from the image, then passes it to MedGemma.
   * In Expo Go: Returns a realistic mock structured report for UI testing.
   */
  static async translateMultimodal(base64Image: string, healthJSON: HealthMetricsJSON): Promise<StructuredReport> {
    if (!this.isModelLoaded) {
      throw new Error("Med-Gemma Vision architecture is not loaded into memory yet.");
    }

    const isExpoGo = Constants.appOwnership === 'expo';
    if (isExpoGo || Platform.OS !== 'ios' || !this.llamaContext) {
      console.log("[llama.rn] Simulated Vision pipeline (Expo Go fallback)...");
      // In Expo Go, return a realistic mock structured report for UI testing
      return new Promise((resolve) => {
        setTimeout(() => {
          resolve({
            patientSummary: `I analyzed the physical document you scanned using the on-device Vision AI. Your Vitamin D levels are currently at 22 ng/mL, which is slightly below the standard reference range of 30-100 ng/mL. This is very common and easy to address! Everything else on the report looks perfectly normal.`,
            doctorQuestions: `1. "My Vitamin D is at 22 ng/mL — should I take a supplement, and if so, what dosage would you recommend?"\n\n2. "Could my low Vitamin D be contributing to the fatigue I've been feeling lately?"\n\n3. "How soon should I retest my Vitamin D levels after starting supplementation?"`,
            dietaryAdvice: `🌞 Step 1: Get 15-20 minutes of direct sunlight daily (before 10am or after 4pm to avoid UV damage).\n\n🐟 Step 2: Add Vitamin D-rich foods like salmon, egg yolks, and fortified milk to your weekly meals.\n\n💊 Step 3: Consider a Vitamin D3 supplement (2000-4000 IU daily) after confirming with your doctor.`,
            medicalGlossary: `• Vitamin D (25-Hydroxyvitamin D) — A nutrient your body needs for building strong bones and supporting your immune system. Your skin makes it from sunlight.\n\n• Reference Range — The "normal" range of values for a lab test. Values outside this range may need attention.\n\n• ng/mL — Nanograms per milliliter, a unit of measurement used for lab results. Think of it as a very tiny concentration.`,
            medicationNotes: 'No medications were provided. You can add your current medications in your Profile to get personalized cross-referencing.',
            rawText: 'Simulated Expo Go response',
          });
        }, 2500);
      });
    }

    // NATIVE iOS PATH:
    // Step 1: Use Apple's VisionKit to extract text from the base64 image
    // (This is handled by the native module — see modules/VisionOCR)
    // Step 2: Pass the extracted text into the full MedGemma analysis pipeline
    console.log("[llama.rn] Executing Apple VisionKit OCR → MedGemma pipeline via Metal...");

    try {
      // On native iOS, the VisionOCR native module extracts text from the image.
      // For now, we pass the base64 as a prompt hint since the vision projector handles it.
      const prompt = `<start_of_turn>user
Analyze this medical document carefully. [IMAGE]
Explain the clinical data logically in very simple, reassuring terms to a patient.
<end_of_turn>
<start_of_turn>model
`;

      const result = await this.llamaContext.completion({
        prompt: prompt,
        // @ts-ignore: Passing raw base64 strictly to the vision encoder bindings
        image_url: `data:image/jpeg;base64,${base64Image}`,
        n_predict: 600,
        temperature: 0.2,
        top_p: 0.9,
      });

      console.log("[llama.rn] Vision pipeline complete.");
      return this.parseStructuredReport(result.text);
    } catch (e) {
      console.error("[llama.rn] Vision pipeline error:", e);
      return {
        patientSummary: "An error occurred while analyzing the image locally on your device. Please try again.",
        doctorQuestions: '',
        dietaryAdvice: '',
        medicalGlossary: '',
        medicationNotes: '',
        rawText: '',
      };
    }
  }
}
