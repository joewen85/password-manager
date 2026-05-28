# Native Window Probe

Throwaway Android prototype for checking whether native Android input handling is
more stable than the Flutter home screen in foldable/window mode.

## Run

Build and install the debug app, then launch the probe activities directly:

```bash
cd apps/flutter_app
HTTP_PROXY=http://127.0.0.1:7890 \
HTTPS_PROXY=http://127.0.0.1:7890 \
ALL_PROXY=http://127.0.0.1:7890 \
flutter build apk --debug

~/Library/Android/sdk/platform-tools/adb install -r build/app/outputs/flutter-apk/app-debug.apk
~/Library/Android/sdk/platform-tools/adb shell am start \
  -a com.example.password_manager_app.NATIVE_WINDOW_PROBE \
  -n com.example.password_manager_app/.NativeWindowProbeActivity
```

If `adb` is already on `PATH`, plain `adb ...` is fine.

## Probe Variants

Run these in the same failing window size:

```bash
# adjustNothing + sticky showSoftInput retry
~/Library/Android/sdk/platform-tools/adb shell am start \
  -a com.example.password_manager_app.NATIVE_WINDOW_PROBE \
  -n com.example.password_manager_app/.NativeWindowProbeActivity

# adjustResize
~/Library/Android/sdk/platform-tools/adb shell am start \
  -a com.example.password_manager_app.NATIVE_WINDOW_PROBE_RESIZE \
  -n com.example.password_manager_app/.NativeWindowProbeResizeActivity

# adjustPan
~/Library/Android/sdk/platform-tools/adb shell am start \
  -a com.example.password_manager_app.NATIVE_WINDOW_PROBE_PAN \
  -n com.example.password_manager_app/.NativeWindowProbePanActivity

# adjustNothing without retry
~/Library/Android/sdk/platform-tools/adb shell am start \
  -a com.example.password_manager_app.NATIVE_WINDOW_PROBE_NOTHING \
  -n com.example.password_manager_app/.NativeWindowProbeNothingActivity
```

Recommended order: sticky, resize, pan, nothing. If sticky works but the others
fail, the system is closing IME after focus and app-layer retry can mitigate it.
If one of resize/pan/nothing works, use that `windowSoftInputMode` direction for
the Flutter Activity. If all variants fail, native rewrite alone is unlikely to
fix the problem without a device/IME/window-manager workaround.

## What To Check

1. Open the activity in Android window mode.
2. Resize it to the width where the Flutter search field currently loses the
   keyboard.
3. Tap the native search field.
4. Confirm whether the keyboard stays open.
5. Try the same after resizing across single-pane and two-pane widths.

The top line shows the current window size in dp, IME bottom inset, layout mode,
and whether the search field still has focus.

The lines below it show the latest probe events:

- `config`: Android reported a configuration/window-size change.
- `windowFocus`: the activity window gained or lost focus.
- `searchFocus`: the native search field gained or lost focus.
- `insets`: IME/window inset state changed.

If the keyboard closes again, note the last 2-3 event lines shown on screen.
They distinguish whether the close was caused by a search-focus loss, an
activity-window focus loss, a configuration resize, or only an IME inset reset.

## Decision

If the native probe keeps the keyboard open in the same window sizes where
Flutter fails, Android-native UI is a stronger candidate for the foldable/window
experience. If the native probe also loses the keyboard, the issue is likely
device/IME/window-manager specific rather than Flutter-specific.
