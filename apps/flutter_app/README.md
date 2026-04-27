# Flutter App

Flutter 跨平台应用入口。

## 常用命令

### 依赖重置（全端通用）

```bash
flutter clean
flutter pub get
```

### 各端全量重编译（在 `apps/flutter_app` 目录执行）

**macOS（Debug 运行）**

```bash
flutter clean
flutter pub get
cd macos && pod install && cd ..
flutter run -d macos
```

**macOS（Release 构建）**

```bash
flutter clean
flutter pub get
cd macos && pod install && cd ..
flutter build macos --release
```

**Windows（Debug 运行）**

```bash
flutter clean
flutter pub get
flutter run -d windows
```

**Windows（Release 构建）**

```bash
flutter clean
flutter pub get
flutter build windows --release
```

**Linux（Debug 运行）**

```bash
flutter clean
flutter pub get
flutter run -d linux
```

**Linux（Release 构建）**

```bash
flutter clean
flutter pub get
flutter build linux --release
```

**iOS（Debug 运行）**

```bash
flutter clean
flutter pub get
cd ios && pod install && cd ..
flutter run -d ios
```

**iOS（Release IPA）**

```bash
flutter clean
flutter pub get
cd ios && pod install && cd ..
flutter build ipa --release
```

**Android（Debug 运行）**

```bash
flutter clean
flutter pub get
flutter run -d android
```

**Android（Release APK）**

```bash
flutter clean
flutter pub get
flutter build apk --release
```

**Android（Release AAB）**

```bash
flutter clean
flutter pub get
flutter build appbundle --release
```

**Web（Release 构建）**

```bash
flutter clean
flutter pub get
flutter build web --release
```

## 测试

```bash
flutter test
```
