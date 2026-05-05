// A lightweight global state to hold the translation result between Tabs

export interface StructuredReport {
  patientSummary: string;
  doctorQuestions: string;
  dietaryAdvice: string;
  medicalGlossary: string;
  medicationNotes: string;
  rawText: string;  // The full raw AI response as a fallback
}

export const GlobalState = {
  translationResult: null as string | null,
  structuredReport: null as StructuredReport | null,
};
