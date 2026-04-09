# Dashboard Feature Notes

This note documents the current custom dashboard feature implemented in the
Flutter demo app.

It focuses on the working product slice, not the broader BLE investigation.

## Current Behavior

The dashboard is now driven by confirmed glasses events and real Android
notifications.

### Interaction loop

- `F5 02`:
  - if the dashboard is closed -> open dashboard and show the newest
    notification
  - if the dashboard is already open -> advance to the next notification
- `F5 03`:
  - no action
- `F5 00`:
  - close the dashboard and return to idle
- inactivity timeout:
  - if no further tilt-up happens within 5 seconds, the dashboard auto-closes
  - on timeout, the app also sends an exit command so the glasses clear the
    active screen

### Rendering behavior

Each dashboard card currently renders:

- current time
- notification source
- notification message

If there are no notifications available, the dashboard shows:

- `No notifications`

## Data Source

The dashboard is no longer using fixed sample strings.

Instead, it uses a small `DashboardNotification` model from
[lib/services/dashboard_service.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/dashboard_service.dart):

- `source`
- `message`

The dashboard feed is now populated from Android notifications.

## Android Notification Ingestion

Android notifications are captured through a minimal
`NotificationListenerService`:

- [android/app/src/main/kotlin/com/example/demo_ai_even/notifications/RecentNotificationsListenerService.kt](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/kotlin/com/example/demo_ai_even/notifications/RecentNotificationsListenerService.kt)

Recent entries are stored in a small rolling in-memory cache:

- [android/app/src/main/kotlin/com/example/demo_ai_even/notifications/NotificationFeedStore.kt](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/kotlin/com/example/demo_ai_even/notifications/NotificationFeedStore.kt)

Flutter reads that cached list through the existing method channel bridge:

- [android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleChannelHelper.kt](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/kotlin/com/example/demo_ai_even/bluetooth/BleChannelHelper.kt)

The dashboard service refreshes the feed from native before each open/advance:

- [lib/services/dashboard_service.dart](/c:/Users/EddieJohnson/projects/EvenDemoApp/lib/services/dashboard_service.dart)

This keeps the dashboard interaction loop unchanged while replacing the feed
source underneath it.

## Notification Ordering

- the native cache keeps a small rolling list of recent notifications
- newest notifications are stored first
- tilt-up cycles through the list in order
- after the last item, the current implementation wraps back to the start

## Current Setup Requirement

The app must have Android Notification Access enabled.

Without that permission:

- the notification listener will not receive notifications
- the dashboard will fall back to the empty state

The listener service is declared in:

- [android/app/src/main/AndroidManifest.xml](/c:/Users/EddieJohnson/projects/EvenDemoApp/android/app/src/main/AndroidManifest.xml)

## Current Limits

The dashboard is intentionally minimal.

Known limitations:

- some apps expose poor or restricted notification text, so the dashboard may
  still show `Open your phone for details`
- some app labels may still be imperfect depending on what Android exposes
- there is no filtering, grouping, or read/unread state yet
- there is no native settings UI for enabling Notification Access inside the app
- `F5 03` is intentionally a no-op to avoid accidental back-and-forth paging

## Why This Slice Matters

This is now a proven hands-free product loop on the glasses:

1. tilt up
2. see the latest notification
3. tilt up again to continue through the feed
4. double tap to close
5. or wait 5 seconds to auto-close

That makes the dashboard the first connected feature in this repo that is both:

- useful with real phone data
- driven by confirmed glasses gestures rather than only phone UI actions

## Likely Next Step

The most natural next step is to improve the notification feed itself without
changing the interaction loop, for example:

- filtering noisy apps
- truncation rules for long messages
- better source/title formatting
- explicit empty-state wording
