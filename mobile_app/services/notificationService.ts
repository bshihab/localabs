import * as Notifications from 'expo-notifications';
import { Platform } from 'react-native';

// Configure how notifications appear when the app is in the foreground
Notifications.setNotificationHandler({
  handleNotification: async () => ({
    shouldShowAlert: true,
    shouldPlaySound: true,
    shouldSetBadge: false,
  }),
});

export class NotificationService {
  /**
   * Requests permission from the user to send local push notifications.
   */
  static async requestPermissions(): Promise<boolean> {
    const { status: existingStatus } = await Notifications.getPermissionsAsync();
    let finalStatus = existingStatus;
    
    if (existingStatus !== 'granted') {
      const { status } = await Notifications.requestPermissionsAsync();
      finalStatus = status;
    }
    
    return finalStatus === 'granted';
  }

  /**
   * Schedules a recurring weekly notification to remind the user of their health review.
   */
  static async scheduleWeeklyReview() {
    const hasPermission = await this.requestPermissions();
    if (!hasPermission) return;

    // Cancel all previously scheduled notifications to avoid duplicates
    await Notifications.cancelAllScheduledNotificationsAsync();

    await Notifications.scheduleNotificationAsync({
      content: {
        title: "🩺 Your Weekly Health Review",
        body: "MedGemma has synthesized your Apple Health data. Tap to view your offline AI report!",
        data: { route: '/dashboard', action: 'weekly_review' },
      },
      trigger: {
        // Re-factored to conform perfectly to Expo's explicit TimeInterval trigger engine
        // 604800 seconds exactly equates to 7 Days (1 Week). 
        type: Notifications.SchedulableTriggerInputTypes.TIME_INTERVAL,
        seconds: 60 * 60 * 24 * 7,
        repeats: true,
      },
    });

    console.log("[Notifications] Weekly review successfully scheduled.");
  }

  /**
   * Completely purges the iOS background notification queue to disable the feature.
   */
  static async disableWeeklyReview() {
    await Notifications.cancelAllScheduledNotificationsAsync();
    console.log("[Notifications] Weekly review tracking successfully disabled.");
  }

  /**
   * Hardware poll to check if ANY alerts are currently queued in the OS.
   * Used to dynamically set the Switch toggle UI on app boot.
   */
  static async checkIsScheduled(): Promise<boolean> {
    const scheduled = await Notifications.getAllScheduledNotificationsAsync();
    return scheduled.length > 0;
  }

  /**
   * Schedules a test notification 5 seconds from now.
   * Useful for immediate verification during development.
   */
  static async testNotification() {
    const hasPermission = await this.requestPermissions();
    if (!hasPermission) return;

    await Notifications.scheduleNotificationAsync({
      content: {
        title: "🩺 Test: Weekly Health Review",
        body: "This is what your weekly Apple Health check-in will look like. Tap to generate it!",
        data: { route: '/dashboard', action: 'weekly_review' },
      },
      trigger: {
        type: Notifications.SchedulableTriggerInputTypes.TIME_INTERVAL,
        seconds: 5,
        repeats: false,
      },
    });
  }
}
