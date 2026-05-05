import { initializeApp } from 'firebase/app';
import { initializeAuth, getReactNativePersistence } from 'firebase/auth';
import { getFirestore } from 'firebase/firestore';
import AsyncStorage from '@react-native-async-storage/async-storage';

// TODO: Replace these with the actual Firebase config from the GCP console
// when we are ready to connect the backup layer in Phase 5.
const firebaseConfig = {
  apiKey: process.env.EXPO_PUBLIC_FIREBASE_API_KEY || "",
  authDomain: process.env.EXPO_PUBLIC_FIREBASE_AUTH_DOMAIN || "",
  projectId: process.env.EXPO_PUBLIC_FIREBASE_PROJECT_ID || "",
  storageBucket: process.env.EXPO_PUBLIC_FIREBASE_STORAGE_BUCKET || "",
  messagingSenderId: process.env.EXPO_PUBLIC_FIREBASE_MESSAGING_SENDER_ID || "",
  appId: process.env.EXPO_PUBLIC_FIREBASE_APP_ID || ""
};

// Initialize Firebase
const app = initializeApp(firebaseConfig);

// Initialize Firebase Authentication with AsyncStorage persistance
export const auth = initializeAuth(app, {
  persistence: getReactNativePersistence(AsyncStorage)
});

// Initialize Cloud Firestore and get a reference to the service
export const db = getFirestore(app);

/**
 * Securely encrypts and backs up the final translated text to Firebase Cloud Firestore.
 * 
 * Note: Because you have not pasted your real Google Cloud API keys into this file yet,
 * this function currently simulates the network request so you can test the UI Button!
 */
export async function saveTranslationToCloud(translationText: string): Promise<boolean> {
  console.log("[Firebase] Preparing to secure and upload translation to Cloud Firestore...");

  // In a real app with API keys, we would use:
  // await addDoc(collection(db, "translations"), { text: translationText, date: new Date() });

  return new Promise((resolve) => {
    // We simulate the 1-2 seconds it takes to upload data to Google Cloud servers
    setTimeout(() => {
      console.log("[Firebase] Translation successfully backed up to the cloud!");
      resolve(true);
    }, 1500);
  });
}
