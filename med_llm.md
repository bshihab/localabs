Project: Lab-to-Language Health Companion App (Local AI Edition)

Core Goal: A privacy-first, cross-platform mobile application that translates complex medical lab results into empathetic language. By running the Med-Gemma model locally on the user's phone, it analyzes lab report images and correlates them with wearable data (via Apple Health/Google Health Connect) without sending sensitive medical queries to the cloud.

Key Architectural Drivers: Absolute Privacy & Cost-Efficiency

Privacy (Zero-Cloud Data) [Primary Driver]: Medical data (PHI) is highly sensitive. By processing the lab report and health data entirely on-device, the app eliminates the risk of data interception, bypasses complex HIPAA/GDPR cloud server compliance, and ensures data never leaves the phone unless explicitly backed up by the user.

Offline Capability & Zero Cloud Costs: While local inference introduces slight compute latency (e.g., 5-15 seconds for the smartphone CPU/NPU to process the image and generate the summary), it completely eliminates network latency and per-query API costs. For asynchronous tasks like translating lab results, this local processing time is highly acceptable and guarantees the app works perfectly even in airplane mode.

1. Frontend & On-Device AI Layer (Mobile App)

Framework: React Native or Flutter.

Health Data Integration: * HealthKit (iOS) / Health Connect (Android) APIs to securely pull historical health metrics (Resting Heart Rate, Sleep Stages, Step Count, HRV) directly on the device.

On-Device Inference Engine: Google AI Edge (LiteRT / MediaPipe LLM Inference API).

Function: Runs the quantized Med-Gemma 4B model completely offline. Modern smartphones with 6GB+ RAM can load the model directly into memory and execute it using the phone's CPU/NPU.

UI/UX Components:

Secure camera interface for scanning physical lab documents.

A "Translation Dashboard" that displays the simplified lab results alongside graphs of the user's relevant wearable data.

An offline conversational UI to ask follow-up questions about the results.

2. The Local Prompt Architecture (Med-Gemma Inference)

Input 1 (Vision): The raw image of the lab report passed directly to Med-Gemma's multimodal vision encoder on the device.

Input 2 (Text Context): A structured JSON of the user's recent wearable data pulled locally (e.g., {"avg_resting_hr_last_30_days": 85, "sleep_quality": "declining"}).

System Prompt: "You are an empathetic medical assistant. Analyze the provided lab report image and translate the results into patient-friendly language at a 9th-grade reading level. Correlate the findings with the provided wearable health data trends. Do not diagnose; advise consulting a physician."

Output: A structured JSON payload containing simplified_explanation, health_data_correlation, and suggested_questions_for_doctor.

3. Cloud & Backend Layer (Google Cloud Platform)

Note: The cloud layer is now drastically reduced to maximize privacy and reduce operational costs.

Authentication: Firebase Auth (Ensures secure, HIPAA-compliant user sign-ins).

Storage Backup: Cloud Firestore.

Function: Acts purely as an encrypted, opt-in backup for the user's translated summaries and chat history. The raw lab images and the active AI processing never leave the device.

4. Data Flow Summary

User takes a photo of a lab report via the App.

App securely queries local Apple Health/Health Connect for the last 30 days of data.

App bundles the Image + Health JSON and passes them to the local LiteRT/MediaPipe engine.

Local Med-Gemma executes entirely on the phone's hardware, generating the empathetic translation and health correlations (approx. 5-15s compute time).

App displays the result to the user (fully functional offline).

(Optional) App syncs the final text summary to Firestore for cross-device backup.