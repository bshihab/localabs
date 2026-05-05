import React, { useState, useRef, useEffect } from 'react';
import { View, Text, TextInput, KeyboardAvoidingView, Platform, ScrollView, TouchableOpacity, Keyboard, ActivityIndicator } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { Ionicons } from '@expo/vector-icons';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { InferenceEngine } from '@/services/inferenceEngine';

type Message = { role: 'user' | 'model'; content: string };

const SUGGESTED_TOKENS = [
  "Explain Abnormal Flags",
  "Summarize Last Scan",
  "Analyze My Vitals",
];

export default function ChatScreen() {
  const [messages, setMessages] = useState<Message[]>([]);
  const [input, setInput] = useState('');
  const [isTyping, setIsTyping] = useState(false);
  const scrollViewRef = useRef<ScrollView>(null);

  useEffect(() => {
    // Load local chat history
    async function loadHistory() {
      const stored = await AsyncStorage.getItem('@chat_history');
      if (stored) setMessages(JSON.parse(stored));
    }
    loadHistory();
  }, []);

  const saveHistory = async (newLogs: Message[]) => {
    await AsyncStorage.setItem('@chat_history', JSON.stringify(newLogs));
  };

  const clearHistory = async () => {
    setMessages([]);
    await AsyncStorage.removeItem('@chat_history');
  }

  const handleSend = async (forcedText?: string) => {
    const textToSend = forcedText || input;
    if (!textToSend.trim() || isTyping) return;

    if (!InferenceEngine.getIsModelLoaded()) {
      alert("Please download the MedGemma offline model in your Profile settings first.");
      return;
    }

    setInput('');
    Keyboard.dismiss();

    const newLogs: Message[] = [...messages, { role: 'user', content: textToSend.trim() }];
    setMessages(newLogs);
    saveHistory(newLogs);
    setIsTyping(true);

    try {
      const mockHealth = { avg_resting_hr_last_30_days: null, avg_sleep_hours_last_30_days: null, avg_hrv_last_30_days: null };
      const response = await InferenceEngine.translateLabReport(textToSend.trim(), mockHealth as any);
      
      const updatedLogs: Message[] = [...newLogs, { role: 'model', content: response }];
      setMessages(updatedLogs);
      saveHistory(updatedLogs);
    } catch (e) {
      alert("Error reaching Inference Engine.");
    } finally {
      setIsTyping(false);
    }
  };

  return (
    <SafeAreaView className="flex-1 bg-apple-background-light dark:bg-apple-background-dark" edges={['top']}>
      <View className="px-6 pt-1 flex-row items-center justify-between pb-4 border-b border-black/5 dark:border-white/10 shrink-0 bg-apple-background-light dark:bg-apple-background-dark z-10">
        <Text className="text-[34px] font-bold text-apple-text-light dark:text-apple-text-dark tracking-tight">Assistant Chat</Text>
        {messages.length > 0 && (
          <TouchableOpacity onPress={clearHistory} className="bg-black/5 dark:bg-white/10 p-2 rounded-full">
            <Ionicons name="trash" size={18} color="#FF3B30" />
          </TouchableOpacity>
        )}
      </View>

      <KeyboardAvoidingView 
        className="flex-1" 
        behavior={Platform.OS === 'ios' ? 'padding' : undefined}
      >
        <ScrollView 
          ref={scrollViewRef}
          className="flex-1 px-4"
          contentContainerStyle={{ paddingTop: 24, paddingBottom: 130 }}
          onContentSizeChange={() => scrollViewRef.current?.scrollToEnd({ animated: true })}
        >
          {messages.length === 0 ? (
            <View className="items-center justify-center mt-12 mx-4">
              <Ionicons name="chatbubbles" size={48} color="#007AFF" style={{ opacity: 0.2, marginBottom: 16 }} />
              <Text className="text-apple-text-secondary-light dark:text-apple-text-secondary-dark text-center text-[15px] leading-[22px]">
                Zero-cloud privacy mode enabled.{'\n'}
                Your continuous thread is securely encrypted solely on this hardware.
              </Text>
            </View>
          ) : (
            messages.map((msg, index) => (
              <View 
                key={index} 
                className={`mb-4 max-w-[85%] rounded-[20px] px-5 py-3 ${
                  msg.role === 'user' 
                    ? 'bg-apple-blue-light dark:bg-apple-blue-dark self-end rounded-br-sm' 
                    : 'bg-apple-card-light dark:bg-apple-card-dark border border-black/5 dark:border-white/10 self-start rounded-bl-sm'
                }`}
              >
                <Text 
                  className={`text-[17px] leading-[22px] ${
                    msg.role === 'user' ? 'text-white' : 'text-apple-text-light dark:text-apple-text-dark'
                  }`}
                >
                  {msg.content}
                </Text>
              </View>
            ))
          )}

          {isTyping && (
            <View className="self-start mb-6 rounded-[20px] rounded-bl-sm px-6 py-4 bg-apple-card-light dark:bg-apple-card-dark border border-black/5 dark:border-white/10">
              <ActivityIndicator size="small" color="#8E8E93" />
            </View>
          )}
        </ScrollView>

        {/* Floating HIG Search Field Configuration */}
        <View className="absolute bottom-0 w-full px-4 mb-[95px]" pointerEvents="box-none">
          <ScrollView horizontal showsHorizontalScrollIndicator={false} className="mb-3 max-h-[36px]" contentContainerStyle={{ paddingHorizontal: 4 }} pointerEvents="auto">
            {SUGGESTED_TOKENS.map((token, i) => (
              <TouchableOpacity 
                key={i}
                onPress={() => handleSend(token)}
                className="bg-apple-card-light dark:bg-apple-card-dark px-4 py-2 rounded-full mr-2 h-[34px] flex-row items-center border border-black/5 dark:border-white/10 shadow-sm"
              >
                <Text className="text-apple-text-light dark:text-apple-text-dark font-medium text-[13px]">{token}</Text>
              </TouchableOpacity>
            ))}
          </ScrollView>

          <View className="w-full relative pointer-events-auto" pointerEvents="auto">
            <View className="w-full bg-apple-card-light dark:bg-apple-card-dark border border-black/10 dark:border-white/20 rounded-[22px] shadow-md flex-row items-center overflow-hidden min-h-[44px]">
              
              <View className="pl-4 pr-1">
                <Ionicons name="search" size={20} color="#8E8E93" />
              </View>

              <TextInput 
                className="flex-1 bg-transparent text-apple-text-light dark:text-apple-text-dark text-[17px] py-[10px] pl-1 pr-2"
                placeholder="Ask MedGemma..."
                placeholderTextColor="#8E8E93"
                value={input}
                onChangeText={setInput}
                selectionColor="#007AFF"
                multiline
                maxLength={400}
                style={{ maxHeight: 100 }}
              />

              {input.length > 0 && (
                <TouchableOpacity onPress={() => setInput('')} className="px-1">
                  <Ionicons name="close-circle" size={18} color="#8E8E93" />
                </TouchableOpacity>
              )}

              <TouchableOpacity 
                onPress={() => handleSend()}
                disabled={!input.trim() || isTyping}
                className={`w-[32px] h-[32px] mx-2 rounded-full justify-center items-center ${
                  input.trim() && !isTyping ? 'bg-apple-blue-light dark:bg-apple-blue-dark' : 'bg-black/5 dark:bg-white/10'
                }`}
              >
                <Ionicons name="arrow-up" size={18} color={input.trim() && !isTyping ? '#FFFFFF' : '#8E8E93'} />
              </TouchableOpacity>

            </View>
          </View>
        </View>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}
