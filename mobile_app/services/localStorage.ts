import AsyncStorage from '@react-native-async-storage/async-storage';

const HISTORY_STORAGE_KEY = '@medgemma_history_vault';

export interface TranslationRecord {
  id: string;
  timestamp: number;
  translationText: string;
}

export const LocalStorageService = {
  /**
   * Saves a new translation to the secure local history vault.
   */
  saveTranslationToHistory: async (translationText: string): Promise<boolean> => {
    try {
      const existingData = await AsyncStorage.getItem(HISTORY_STORAGE_KEY);
      const history: TranslationRecord[] = existingData ? JSON.parse(existingData) : [];

      const newRecord: TranslationRecord = {
        id: Date.now().toString(),
        timestamp: Date.now(),
        translationText: translationText,
      };

      // Add to the beginning of the array so the newest is always first
      history.unshift(newRecord);

      // Keep only the last 10 records to prevent storage bloat
      if (history.length > 10) {
        history.pop();
      }

      await AsyncStorage.setItem(HISTORY_STORAGE_KEY, JSON.stringify(history));
      return true;
    } catch (e) {
      console.error('Failed to save to local history vault:', e);
      return false;
    }
  },

  /**
   * Retrieves the full translation history.
   */
  getTranslationHistory: async (): Promise<TranslationRecord[]> => {
    try {
      const existingData = await AsyncStorage.getItem(HISTORY_STORAGE_KEY);
      return existingData ? JSON.parse(existingData) : [];
    } catch (e) {
      console.error('Failed to get local history:', e);
      return [];
    }
  },

  /**
   * Gets the most recent past translation to provide context to the AI model.
   */
  getMostRecentPastTranslation: async (): Promise<string | null> => {
    const history = await LocalStorageService.getTranslationHistory();
    if (history.length > 0) {
      return history[0].translationText;
    }
    return null;
  }
};
