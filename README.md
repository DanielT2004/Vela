# Vela — AI Food Video Editor (iOS MVP)

Raw food footage in → a post-ready 9:16 TikTok out. A native iOS app that sends a creator's raw
video to **Gemini**, gets back a structured **Edit Plan (JSON)**, renders it as a fast three-layer
editing experience (Triage swipe deck → Living Timeline → Polish), and assembles the final cut with
**AVFoundation**.

This is an **MVP / testing build**: verbose logging is on at every step, and a local push
notification fires when Gemini finishes analyzing your video.

---

## Requirements

- **Xcode 16+** (built/verified on Xcode 26.5, iOS SDK 26)
- A **physical iPhone** running **iOS 17+** (the camera roll has your real food footage; the
  Simulator only has Apple's stock clips)
- A **Gemini API key** — free at <https://aistudio.google.com/apikey>

No third-party dependencies, no CocoaPods/SPM packages — everything is Apple-native.

---

## Setup (one-time)

1. **Add your API key**
   ```sh
   cp Secrets.example.xcconfig Secrets.xcconfig
   ```
   Open `Secrets.xcconfig` and paste your key after the `=`:
   ```
   GEMINI_API_KEY = AIza...your_key...
   ```
   `Secrets.xcconfig` is **gitignored** — your key never gets committed and is never hard-coded in
   Swift source. (It flows `Secrets.xcconfig → Info.plist → read at runtime`.)

2. **Open the project**
   ```sh
   open FoodEditor.xcodeproj
   ```

3. **Set your signing team** (needed to run on a real device)
   - Select the **FoodEditor** target → **Signing & Capabilities**
   - Team: pick your Apple ID (a free personal team is fine)
   - If the bundle id `com.vela.foodeditor` is taken, change it to something unique

4. **Run on your iPhone**
   - Plug in the phone, select it as the run destination, press **⌘R**
   - First run: on the phone, trust the developer cert under
     **Settings → General → VPN & Device Management**

> Leaving the key blank still builds and runs — the app just shows a friendly "add your key" message
> instead of analyzing.

---

## How to watch it work (MVP logging)

Keep Xcode's **console** open while you use the app. Every pipeline step prints with an emoji tag:

| Tag | Step |
|-----|------|
| `🎞️ video`    | picking and loading the raw clip (duration, resolution, size) |
| `🗜️ compress` | transcoding to 720p for faster upload (before/after size) |
| `📤 upload`    | uploading to the Gemini Files API |
| `⏳ poll`      | waiting for the file to become `ACTIVE` |
| `🤖 gemini`    | the request + the **raw JSON response** + the parsed Edit Plan |
| `🎬 assembly`  | building the final composition and exporting |
| `🔔 notif`     | the local "your edit is ready" notification |

When analysis finishes, a **local notification** is posted — so you can background the app during the
(potentially slow) Gemini call and get pinged when it's done.

---

## Build milestones (test at each ⛔)

The app is built in small, individually-testable milestones. The riskiest part — getting a good
Gemini response on your own footage — is split out and verified first.

- **M0** — Project skeleton + styled Home  ⬅️ *you are here*
- **M1** — Video retrieval (pick → play → log metadata)
- **M2** — Compression for speed (720p transcode, before/after size)
- **M3** — Gemini round-trip (print the raw response)
- **M4** — Parse Edit Plan + push notification ← **quality gate**
- **M5** — Segment display (thumbnails, tap-to-play)
- **M6** — Layer 1 Triage (swipe deck + Cut Tray)
- **M7** — Layer 2 Living Timeline + Hook Spotlight
- **M8** — Assembly & Export (9:16 MP4 → camera roll)
- **M9** — Polish layer + motion

---

## What's real vs. stubbed (MVP)

**Real:** camera-roll picking, on-device compression, Gemini Files-API analysis, the Edit Plan model
as the single source of truth, the three-layer editing UI, AVFoundation assembly/export (incl. the
voiceover composite), save to camera roll, verbose logging, the completion notification.

**Stubbed / out of scope (clearly marked `// TODO`):**
- Style-profile **learning** — Screen 9 is built as static UI; it does not learn yet
- Conversational AI **re-edit** in Polish — chips apply simple local edits, not a real model call
- TikTok OAuth / posting, accounts, payments, Android/web, a backend database
- Whisper transcription
- Recent-projects persistence on Home (placeholder tiles)

---

## Production note — API key & proxy

For local testing the app calls Gemini **directly from Swift** with the key in the gitignored
xcconfig. **This is fine for development but not for shipping** — a key embedded in (or shipped
alongside) the app can be extracted. Before any real release, move the Gemini call behind a small
server-side proxy that holds the key and forwards requests; the app then calls the proxy instead of
Google directly. The networking is isolated behind the `VideoAnalyzing` protocol so this is a
drop-in swap.

---

## Project structure

```
FoodEditor/
  App/            app entry, Info.plist
  DesignSystem/   palette, typography, food-tone gradients, shared components
  Models/         EditPlan (Codable contract), EditPlanStore (@Observable), AppRouter
  Services/       Gemini client, prompt constant, video library, thumbnails, notifications, logging
  Assembly/       Edit Plan → AVMutableComposition → MP4 export
  Views/          the 9 screens from the mockup
```
