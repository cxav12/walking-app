# Walking App

## Sleep card (iPhone)

The Sleep card reads HealthKit sleep analysis after the user grants Sleep access. It stays on-device and is not uploaded with friend step sharing. Sessions are grouped across midnight or daytime; gaps over 90 minutes separate sessions. One source is chosen per session (detailed stages preferred), and overlapping sleep intervals are merged. The most recent session of at least three hours within 48 hours is the main sleep; shorter sessions are displayed as naps without a score. Sleep start and wake-up are inferred from the first and last asleep samples, not actual bedtime or alarm time. Missing recorded awake time stays unavailable.

The calculated score uses duration versus the adjustable sleep goal (70%), recorded sleep continuity (20%), and average start-time consistency versus up to seven prior main sleeps (10%, requiring at least three). Start-time differences wrap across midnight. Consistency can be disabled for changing shifts. Missing factors are excluded and weights renormalized. This is an app-specific score, not Apple's sleep score.
