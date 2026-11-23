# PDF-Studio – App-Quellen

Flutter-App (Android) mit nativem PDF-Export über pdfbox-android (`android/app/src/main/kotlin/.../MainActivity.kt`).

```bash
flutter pub get
flutter build apk --release --target-platform android-arm,android-arm64
```

Release-Signierung: `~/keys/pdf-studio-key.properties` (storeFile, storePassword, keyAlias, keyPassword).
Ohne diese Datei wird mit dem Debug-Schlüssel signiert. `./build_apk.sh "Hinweis"` baut und legt die APK in `../downloads/` ab.
