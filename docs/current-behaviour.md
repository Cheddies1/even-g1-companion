# Current Behaviour

This file describes what the app currently does from a user and runtime point of view.

It is intentionally separate from:
- [current-architecture.md](current-architecture.md): structure and ownership
- [protocol-reference.md](protocol-reference.md): raw vendor/demo protocol notes
- [investigation-notes.md](investigation-notes.md): exploratory findings and hypotheses

## Current mode summary

### Glance
- default and most mature mode
- Android notifications can auto-pop into the glasses
- tilt-up recalls or advances recent notifications
- double tap closes the current visible item

### Capture
- intended to record glasses mic audio and save WAV on phone
- partially implemented
- still needs focused device validation

### Navigate
- intended to surface Google Maps navigation guidance from notifications
- scaffolded, not polished

### Chat
- future mode only in this phase
- no end-to-end chat behavior yet

## Glance mode

Glance is currently the main working user-facing feature.

### Display format

Glance is text-only by design:

```text
14:32
--
AppName
Notification body
```

It deliberately does not use the bitmap dashboard path because text is much faster and better for ambient notification use.

### Current behavior

- new notifications can auto-pop into the glasses
- proactive auto-pop does not dismiss the phone notification
- deliberate tilt-up shows the most recent notification
- repeated tilt-up cycles through the feed
- when cycling deliberately:
  - the current item is dismissed on the phone
  - it is also removed from the local app queue
- `F5 00` closes the active Glance item
- timeout clears the active display after a short interval

### Current caveats

- some apps still expose poor notification text, so `Open your phone for details` can still appear
- heavy notification churn can still stress left/right synchronization
- new notifications are now queued if one is already visible, rather than interrupting the current display

### Current filtering

At notification-ingestion time, noisy system notifications are filtered out, including:
- `System UI`
- charging/battery churn

## Capture mode

Capture is the most important practical mode after Glance, but it is not yet fully proven.

### Intended behavior

- idle + tilt-up -> start recording
- recording + tilt-up -> stop and save
- recording + double tap -> stop and save
- idle + double tap -> no-op
- show a recording indicator while active
- show a short save confirmation after recording completes

### Current technical status

- native LC3 decode path exists
- decoded PCM can be written to a WAV recorder
- the Flutter/native bridge for capture is in place
- saved WAV files are published to the public Android recordings collection
- on the target phone this should appear as `Internal storage/Recordings/Even Companion`

### Current caveat

What still needs device confirmation is whether the glasses mic session stops cleanly in practice when Capture mode stops saving.

So:
- WAV save path now targets a normal user-visible recordings location
- real stop semantics are still an open validation item

## Navigate mode

Navigate is intentionally lean and notification-driven.

### Current intended behavior

- user switches app into Navigate mode on phone
- Google Maps notifications are ingested
- concise turn guidance is shown in the glasses
- ordinary Glance notifications are suppressed or deprioritized while navigating

### Current status

- the notification ingestion path is already available
- Maps detection is scaffolded
- formatting/normalization is still light

### Current caveat

Navigate v1 depends on how good Google Maps notifications are on the actual phone/device configuration.

## Background behaviour

The app is intended to keep functioning as a permanent companion app, not only while visible on screen.

Current foundation:
- Android foreground service
- persistent Android notification
- notification listener remains active
- mode state is reflected in the ongoing system notification

This is implemented narrowly, but it is already part of the current app shape.

## Notification ingestion

Current behavior:
- the app captures recent Android notifications
- recent notifications are cached natively
- Flutter hydrates from that feed and also receives pushed notification events
- phone-side dismissal by notification key is supported on a best-effort basis

This supports:
- Glance mode
- Navigate mode

## Current known problems / open edges

- Glance left/right synchronization still needs watching under rapid notification arrival
- some notification sources/messages still need smarter formatting
- Capture mode needs real device validation for start/stop/save reliability
- Navigate mode still needs human review against real Google Maps turn notifications
- Chat mode is not implemented yet
