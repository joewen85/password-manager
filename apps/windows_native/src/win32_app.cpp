#ifdef _WIN32
#include <windows.h>

namespace {

constexpr wchar_t kWindowClassName[] = L"PasswordManagerWindowsNativeWindow";

LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    switch (message) {
        case WM_DESTROY:
            PostQuitMessage(0);
            return 0;
        case WM_PAINT: {
            PAINTSTRUCT paint;
            HDC dc = BeginPaint(hwnd, &paint);
            const wchar_t text[] = L"Password Manager Windows Native";
            TextOutW(dc, 24, 24, text, static_cast<int>(wcslen(text)));
            EndPaint(hwnd, &paint);
            return 0;
        }
        default:
            return DefWindowProcW(hwnd, message, wparam, lparam);
    }
}

} // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int showCommand) {
    WNDCLASSW windowClass{};
    windowClass.lpfnWndProc = WindowProc;
    windowClass.hInstance = instance;
    windowClass.lpszClassName = kWindowClassName;
    windowClass.hCursor = LoadCursor(nullptr, IDC_ARROW);
    RegisterClassW(&windowClass);

    HWND hwnd = CreateWindowExW(
        0,
        kWindowClassName,
        L"Password Manager",
        WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        960,
        640,
        nullptr,
        nullptr,
        instance,
        nullptr
    );
    if (!hwnd) return 1;

    ShowWindow(hwnd, showCommand);
    MSG message{};
    while (GetMessageW(&message, nullptr, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    return 0;
}
#endif
