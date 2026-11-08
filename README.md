# ProCam Reel Master

Local-only Android recorder + Instagram Reels optimizer. Native CameraX capture,
separate AAC mic track (Bluetooth/wired/built-in), FFT denoise on export.
No servers, no paid APIs, no FFmpeg during capture.

## Project layout

```
lib/
  main.dart                          dark shell
  core/theme.dart                    palette + size/time formatters
  models/clip.dart                   Clip / RecordingResult / MicDevice
  services/procam_engine.dart        MethodChannel + PlatformView bridge
  services/video_exporter.dart       FFmpeg command (Reels spec)
  screens/record_screen.dart         preview, grid, focus/EV, aspect, export sheet
  screens/gallery_screen.dart        thumbnails, size, 1-tap share, delete
  widgets/teleprompter_overlay.dart  draggable, auto-scroll, size/opacity
  widgets/grid_overlay.dart          3x3 grid (single CustomPainter)

android/app/src/main/
  AndroidManifest.xml                permissions + FileProvider + share queries
  res/xml/file_paths.xml
  kotlin/com/procam/reelmaster/
    MainActivity.kt                  channels + runtime permissions
    camera/CameraEngine.kt           CameraX Preview + VideoCapture
    camera/CameraPlatformView.kt     PreviewView inside Flutter (TextureView)
    audio/MicRecorder.kt             AudioRecord -> AAC, chosen input device
    audio/AudioRouteManager.kt       Bluetooth SCO / wired / USB / built-in
    media/ClipRepository.kt          scan, lazy thumbs, share intents
  build.gradle.kts                   CameraX 1.5.3, minSdk 24
```

## Build & run (Windows PowerShell)

```powershell
flutter doctor
flutter create --platforms=android --org com.procam --project-name procam_reel_master .
flutter pub get
flutter run -d <DEVICE_ID>          # flutter devices
```

Release APK (per-ABI, much smaller):

```powershell
flutter build apk --release --split-per-abi
adb install -r build\app\outputs\flutter-apk\app-arm64-v8a-release.apk
```

Requirements: Flutter 3.27+, JDK 17, Android SDK 35+, real device
(emulators usually lack 4K, SCO and a usable mic).

If `flutter create` generated a Groovy `android/app/build.gradle` instead of
`.kts`, keep the generated file and merge the `android {}` values + the CameraX
`dependencies` block from `build.gradle.kts` into it.

## Capture pipeline (why it stays cool on 3 GB)

- Only **Preview + VideoCapture** are bound. No `ImageAnalysis`, no preview
  frame copies, no OpenGL in Flutter.
- Recording is hardware H.264 through MediaCodec. Bitrate pinned:
  20 Mbps @ 1080p, 45 Mbps @ 4K. CameraX's default mic is bypassed.
- Audio is a second, tiny pipeline: `AudioRecord` (48 kHz mono) -> AAC-LC
  192 kbps in `MicRecorder.kt`, ~4 KB buffer, no per-frame allocations.
- Aspect switching rebinds use cases **only while idle**; it is rejected
  during a take so the encoder never restarts mid-recording.
- The teleprompter scrolls with a vsync `Ticker` and `jumpTo` - zero rebuilds
  per frame.

## Export pipeline (Reels spec)

`lib/services/video_exporter.dart` builds:

- `scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920`
  (crop-to-fill, no letterbox bars)
- `fps=30|60` constant frame rate
- `libx264`, High profile, `-b:v 18M -maxrate 20M -bufsize 36M`
- `-color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range tv`
- `afftdn=nr=12:nf=-35:tn=1` -> `highpass=90` -> `lowpass=12000` ->
  `loudnorm=I=-14:TP=-1.5:LRA=11` -> AAC 192 kbps mono
- `-movflags +faststart` so Instagram can read the moov atom instantly
- `-threads 4` caps x264 memory on low-RAM phones

`audioOffsetMs` from CameraX keeps lip-sync (audio is trimmed or delayed by the
measured start delta).

## Mic sources

`AudioRouteManager` lists real inputs (`TYPE_BUILTIN_MIC`, `WIRED_HEADSET`,
`USB_DEVICE/HEADSET`, `BLUETOOTH_SCO`) and calls
`AudioRecord.setPreferredDevice()` for the selected one. Bluetooth also raises
SCO mode. Denoise is applied at export, so the recorded master stays dry and
re-editable.

> Bluetooth SCO is 16 kHz-class audio. For voice reels a wired lav or the
> phone's built-in mic is usually cleaner; the app shows both so you can pick.

## Tuning

| Knob | File | Default |
|---|---|---|
| Reels bitrate | `video_exporter.dart` | 18 Mbps (max 20) |
| FPS | export sheet | 30 (60 on stronger phones) |
| Denoise strength | `afftdn=nr=` | 12 dB |
| Loudness | `loudnorm=I=` | -14 LUFS |
| Capture bitrate | `CameraEngine.kt` | 20 / 45 Mbps |
| Teleprompter speed | overlay panel | 26 px/s |

## Licences / size

`ffmpeg_kit_flutter_new_min_gpl` is LGPL-3.0 with GPL components (x264).
Shipping it makes the APK GPL-3.0. It adds roughly 15-25 MB per ABI; the
`--split-per-abi` build keeps each APK near that instead of bundling both.
Everything else is Apache-2.0 (CameraX, Flutter).

## Dropping into an existing app

1. Copy `lib/services`, `lib/widgets`, `lib/screens`, `lib/core`, `lib/models`
   into your project and fix relative imports if your tree differs.
2. Copy `android/app/src/main/kotlin/com/procam/reelmaster/**` into your
   package (rename the package, or keep the `com.procam.reelmaster` subpackage).
3. Merge `AndroidManifest.xml` permissions, `<queries>`, the `FileProvider`
   block and `res/xml/file_paths.xml`.
4. Merge the CameraX `dependencies` and `minSdk = 24` into your app Gradle file.
5. `flutter pub get` and run. `MainActivity` must register the
   `procam/engine`, `procam/engine_events` and `procam/files` channels.

`flutter create` only fills in missing scaffolding (Gradle wrapper, settings,
themes, launcher icons); it does not overwrite the existing `lib/` or `android/`
sources here. If your Flutter version does replace `MainActivity.kt`, restore it
from this repo before building.

## Known limits

- Export always targets the 1080x1920 Reels spec. The aspect chips change the
  *capture* framing (the 9:16 preview matches the Reels crop); a 16:9 master
  is recorded with the wider sensor crop and is still delivered as a Reel.
- Aspect ratio changes are instant while idle; switching during a take is
  blocked on purpose (restarting the encoder would corrupt the MP4).
- Bluetooth SCO is narrowband. Prefer a wired lav for the cleanest voice.
- Export is CPU-bound. A 60 s 1080p30 take takes roughly 40-80 s on a
  Snapdragon 6-series; keep the app foregrounded.
- `ffmpeg_kit_flutter_new_min_gpl` is the smallest build that still has x264 +
  `afftdn` + `loudnorm`. Do not swap it for `_min` (no libx264).
