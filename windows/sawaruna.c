// Sawaruna for Windows
// Copyright (C) 2026 Yoshiki Nakamura
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.
//
// "Sawaruna" and the Sawaruna logo are trademarks of Yoshiki Nakamura.
// The license above does not grant permission to use the name or the logo as a trademark (see TRADEMARKS.md).
//
// How it works
// - While guarding, low-level keyboard and mouse hooks watch input. They run on their own thread,
//   so a busy UI never delays them, and they are re-installed every 20 seconds in case Windows dropped them.
// - Windows marks input created by software (SendInput and similar) with an "injected" flag.
//   Input without that flag came from a physical device: a person touched the PC.
// - On the first human touch, Sawaruna locks the PC with LockWorkStation and checks that it locked.
// - The hooks exist only from "Start guarding" until the lock. They only read the injected flag and
//   the event type. They never read which key was pressed or where the mouse is.
// - No networking code.

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <wtsapi32.h>
#include <stdio.h>
#include <wchar.h>

#define APP_VERSION L"0.1"

#define IDI_APP       1
#define IDI_IDLE      2
#define IDI_ARMING    3
#define IDI_ARMED     4

#define WM_APP_TRAY   (WM_APP + 1)
#define WM_APP_HUMAN  (WM_APP + 2)
#define WM_APP_START  (WM_APP + 3)

// messages to the hook thread
#define HT_ON         (WM_APP + 10)
#define HT_OFF        (WM_APP + 11)

#define T_ARM         1   // 3 seconds without a human touch -> guarding
#define T_VERIFY      2   // check that the lock really happened
#define T_WTS         3   // retry the lock/unlock notification registration
#define T_TRAY        4   // retry adding the tray icon
#define HOTKEY_ID     1

#define CMD_TOGGLE    101
#define CMD_HOTKEY    102
#define CMD_GUIDE     103
#define CMD_QUIT      104

#define ARM_MS        3000
#define VERIFY_MS     1000
#define LOCK_CHECKS   6     // about 6 seconds in total
#define REHOOK_MS     20000

enum State { ST_IDLE, ST_ARMING, ST_ARMED, ST_LOCKING };

static HINSTANCE g_inst;
static HWND g_hwnd;
static volatile LONG g_state = ST_IDLE;   // read by the hook thread
static UINT g_taskbarCreated;
static BOOL g_ja;
static BOOL g_hotkeyAvailable;
static BOOL g_layoutUsesHotkey;           // AltGr+L types a character on an installed layout
static BOOL g_wtsRegistered;
static int g_lockChecks;
static BOOL g_noticePending;
static wchar_t g_touchTime[16];
static NOTIFYICONDATAW g_nid;
static BOOL g_trayAdded;

static DWORD g_hookThreadId;
static HANDLE g_hookReady;
static volatile LONG g_hookOk;

// ---------- text (Japanese or English) ----------
#define T(ja, en) (g_ja ? (ja) : (en))

// ---------- settings (HKCU\Software\Sawaruna) ----------
static DWORD reg_get(const wchar_t *name, DWORD def) {
    DWORD v = def, size = sizeof(v);
    if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Sawaruna", name, RRF_RT_REG_DWORD, NULL, &v, &size) != ERROR_SUCCESS)
        return def;
    return v;
}
static void reg_set(const wchar_t *name, DWORD v) {
    HKEY k;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Sawaruna", 0, NULL, 0, KEY_SET_VALUE, NULL, &k, NULL) == ERROR_SUCCESS) {
        RegSetValueExW(k, name, 0, REG_DWORD, (const BYTE *)&v, sizeof(v));
        RegCloseKey(k);
    }
}
// 1 = on, 0 = off. Without a saved choice it is on, unless the keyboard layout needs AltGr+L for a character.
static BOOL hotkey_enabled(void) {
    DWORD v = reg_get(L"Hotkey", 2);
    if (v == 2) return !g_layoutUsesHotkey;
    return v == 1;
}

// On Windows, AltGr is Ctrl+Alt. On layouts such as Polish, AltGr+L types a letter (ł).
static BOOL layout_uses_altgr_l(void) {
    HKL list[32];
    int n = GetKeyboardLayoutList(32, list);
    BYTE ks[256];
    ZeroMemory(ks, sizeof(ks));
    ks[VK_CONTROL] = ks[VK_LCONTROL] = 0x80;
    ks[VK_MENU] = ks[VK_RMENU] = 0x80;
    for (int i = 0; i < n; i++) {
        wchar_t buf[8];
        UINT sc = MapVirtualKeyExW('L', MAPVK_VK_TO_VSC, list[i]);
        int r = ToUnicodeEx('L', sc, ks, buf, 8, 4 /* do not change keyboard state */, list[i]);
        if (r > 0 && buf[0] >= 0x20) return TRUE;
    }
    return FALSE;
}

// ---------- lock state ----------
// When the session is locked, the input desktop is Winlogon (or cannot be opened at all).
static BOOL session_locked(void) {
    HDESK d = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
    if (!d) return TRUE;
    wchar_t name[64] = L"";
    DWORD len = 0;
    GetUserObjectInformationW(d, UOI_NAME, name, sizeof(name), &len);
    CloseDesktop(d);
    return _wcsicmp(name, L"Default") != 0;
}

// ---------- hooks (on their own thread) ----------
// Keep these callbacks tiny: Windows removes a low-level hook that takes too long.
static BOOL swallow_now(void) {
    LONG s = g_state;
    return s == ST_ARMED || s == ST_LOCKING;   // block a person's input from the touch until the lock
}
static LRESULT CALLBACK kb_proc(int code, WPARAM wp, LPARAM lp) {
    if (code == HC_ACTION) {
        const KBDLLHOOKSTRUCT *k = (const KBDLLHOOKSTRUCT *)lp;
        if (!(k->flags & (LLKHF_INJECTED | LLKHF_LOWER_IL_INJECTED))) {
            PostMessageW(g_hwnd, WM_APP_HUMAN, 0, 0);
            // let key releases through, so no key stays "held down"
            if (swallow_now() && wp != WM_KEYUP && wp != WM_SYSKEYUP) return 1;
        }
    }
    return CallNextHookEx(NULL, code, wp, lp);
}
static LRESULT CALLBACK ms_proc(int code, WPARAM wp, LPARAM lp) {
    if (code == HC_ACTION) {
        const MSLLHOOKSTRUCT *m = (const MSLLHOOKSTRUCT *)lp;
        if (!(m->flags & (LLMHF_INJECTED | LLMHF_LOWER_IL_INJECTED))) {
            PostMessageW(g_hwnd, WM_APP_HUMAN, 0, 0);
            BOOL release = wp == WM_LBUTTONUP || wp == WM_RBUTTONUP || wp == WM_MBUTTONUP || wp == WM_XBUTTONUP;
            if (swallow_now() && !release) return 1;
        }
    }
    return CallNextHookEx(NULL, code, wp, lp);
}

static DWORD WINAPI hook_thread(LPVOID arg) {
    (void)arg;
    HHOOK kb = NULL, ms = NULL;
    UINT_PTR rehook = 0;
    MSG m;
    PeekMessageW(&m, NULL, WM_USER, WM_USER, PM_NOREMOVE);   // create this thread's message queue
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST);
    SetEvent(g_hookReady);
    while (GetMessageW(&m, NULL, 0, 0) > 0) {
        if (m.message == HT_ON) {
            if (!kb) kb = SetWindowsHookExW(WH_KEYBOARD_LL, kb_proc, g_inst, 0);
            if (!ms) ms = SetWindowsHookExW(WH_MOUSE_LL, ms_proc, g_inst, 0);
            InterlockedExchange(&g_hookOk, kb && ms);
            if (!rehook) rehook = SetTimer(NULL, 0, REHOOK_MS, NULL);
            SetEvent(g_hookReady);
        } else if (m.message == HT_OFF) {
            if (rehook) { KillTimer(NULL, rehook); rehook = 0; }
            if (kb) { UnhookWindowsHookEx(kb); kb = NULL; }
            if (ms) { UnhookWindowsHookEx(ms); ms = NULL; }
            SetEvent(g_hookReady);
        } else if (m.message == WM_TIMER && m.hwnd == NULL && rehook && m.wParam == rehook) {
            // Windows can remove a low-level hook without telling anyone. Install fresh ones, then drop the old ones.
            HHOOK nkb = SetWindowsHookExW(WH_KEYBOARD_LL, kb_proc, g_inst, 0);
            HHOOK nms = SetWindowsHookExW(WH_MOUSE_LL, ms_proc, g_inst, 0);
            if (nkb) { if (kb) UnhookWindowsHookEx(kb); kb = nkb; }
            if (nms) { if (ms) UnhookWindowsHookEx(ms); ms = nms; }
        } else {
            DispatchMessageW(&m);
        }
    }
    if (kb) UnhookWindowsHookEx(kb);
    if (ms) UnhookWindowsHookEx(ms);
    return 0;
}
static BOOL hooks_on(void) {
    ResetEvent(g_hookReady);
    if (!PostThreadMessageW(g_hookThreadId, HT_ON, 0, 0)) return FALSE;
    if (WaitForSingleObject(g_hookReady, 3000) != WAIT_OBJECT_0) return FALSE;
    return g_hookOk;
}
static void hooks_off(void) {
    ResetEvent(g_hookReady);
    if (PostThreadMessageW(g_hookThreadId, HT_OFF, 0, 0))
        WaitForSingleObject(g_hookReady, 3000);
    InterlockedExchange(&g_hookOk, 0);
}

// ---------- tray ----------
static HICON load_small_icon(int id) {
    return (HICON)LoadImageW(g_inst, MAKEINTRESOURCEW(id), IMAGE_ICON,
                             GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), LR_DEFAULTCOLOR);
}
static const wchar_t *status_text(void) {
    switch (g_state) {
    case ST_ARMING:  return T(L"準備中：手を離すと見張りが始まります", L"Getting ready: let go to start");
    case ST_ARMED:   return T(L"見張り中", L"Guarding");
    case ST_LOCKING: return T(L"ロックしています", L"Locking");
    default:         return T(L"待機中（何も見ていません）", L"Idle (watching nothing)");
    }
}
static void tray_update(void) {
    int id = IDI_IDLE;
    if (g_state == ST_ARMING) id = IDI_ARMING;
    if (g_state == ST_ARMED || g_state == ST_LOCKING) id = IDI_ARMED;
    HICON old = g_nid.hIcon;
    g_nid.hIcon = load_small_icon(id);
    swprintf(g_nid.szTip, ARRAYSIZE(g_nid.szTip), L"Sawaruna: %ls", status_text());
    g_nid.uFlags = NIF_ICON | NIF_TIP | NIF_MESSAGE;
    if (g_trayAdded) Shell_NotifyIconW(NIM_MODIFY, &g_nid);
    if (old && old != g_nid.hIcon) DestroyIcon(old);
}
static void tray_add(void) {
    if (g_nid.hIcon) DestroyIcon(g_nid.hIcon);
    ZeroMemory(&g_nid, sizeof(g_nid));
    g_nid.cbSize = sizeof(g_nid);
    g_nid.hWnd = g_hwnd;
    g_nid.uID = 1;
    g_nid.uFlags = NIF_ICON | NIF_TIP | NIF_MESSAGE;
    g_nid.uCallbackMessage = WM_APP_TRAY;
    g_nid.hIcon = load_small_icon(IDI_IDLE);
    wcscpy(g_nid.szTip, L"Sawaruna");
    g_trayAdded = Shell_NotifyIconW(NIM_ADD, &g_nid);
    if (g_trayAdded) { KillTimer(g_hwnd, T_TRAY); tray_update(); }
    else SetTimer(g_hwnd, T_TRAY, 2000, NULL);   // Explorer may not be ready yet at sign-in
}
static void tray_notice(const wchar_t *title, const wchar_t *text, DWORD icon) {
    if (!g_trayAdded) return;
    NOTIFYICONDATAW n = g_nid;
    n.uFlags = NIF_INFO;
    n.dwInfoFlags = icon;
    wcsncpy(n.szInfoTitle, title, ARRAYSIZE(n.szInfoTitle) - 1);
    wcsncpy(n.szInfo, text, ARRAYSIZE(n.szInfo) - 1);
    Shell_NotifyIconW(NIM_MODIFY, &n);
}

// ---------- shortcut (Ctrl+Alt+L) ----------
static void hotkey_apply(void) {
    UnregisterHotKey(g_hwnd, HOTKEY_ID);
    g_hotkeyAvailable = FALSE;
    if (hotkey_enabled())
        g_hotkeyAvailable = RegisterHotKey(g_hwnd, HOTKEY_ID, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, 'L');
}

// ---------- guarding ----------
static void set_state(LONG s) { InterlockedExchange(&g_state, s); }

static void stop_guard(void) {
    KillTimer(g_hwnd, T_ARM);
    KillTimer(g_hwnd, T_VERIFY);
    set_state(ST_IDLE);
    hooks_off();
    SetThreadExecutionState(ES_CONTINUOUS);
    tray_update();
}

static void start_guard(void) {
    if (g_state != ST_IDLE) return;
    if (!hooks_on()) {
        hooks_off();
        MessageBoxW(NULL,
            T(L"見張りを始められませんでした。セキュリティソフトがマウスとキーボードの見張りを止めている可能性があります。PC を再起動してから、もう一度お試しください。",
              L"Could not start guarding. Security software may be blocking Sawaruna from watching the mouse and keyboard. Restart the PC and try again."),
            L"Sawaruna", MB_ICONWARNING | MB_OK | MB_TOPMOST);
        return;
    }
    // Keep the PC awake for the AI agent while guarding (the display may still turn off)
    SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED);
    set_state(ST_ARMING);
    SetTimer(g_hwnd, T_ARM, ARM_MS, NULL);
    tray_update();
    if (GetSystemMetrics(SM_REMOTESESSION))
        tray_notice(T(L"リモート デスクトップで接続中です", L"You are connected through Remote Desktop"),
                    T(L"リモート デスクトップからの操作は、人が触ったものとして扱われ、ロックされます。",
                      L"Input over Remote Desktop counts as a person touching the PC and will lock it."), NIIF_WARNING);
}

static void lock_confirmed(void) {
    g_noticePending = TRUE;
    stop_guard();
}

static void lock_failed(void) {
    stop_guard();
    MessageBoxW(NULL,
        T(L"この PC をロックできなかったため、見張りを終了しました。\nWindows ロゴ キー + L でロックしてください。それでもロックできない場合は、管理者の設定でロックが無効になっている可能性があります。",
          L"Sawaruna could not lock this PC, so guarding has stopped.\nPress Windows logo key + L to lock it. If that does not work either, locking may be turned off by your administrator."),
        L"Sawaruna", MB_ICONWARNING | MB_OK | MB_TOPMOST | MB_SETFOREGROUND);
}

static void lock_now(void) {
    SYSTEMTIME t;
    set_state(ST_LOCKING);           // the hook thread starts blocking input now
    BOOL ok = LockWorkStation();     // lock first; everything else can wait
    GetLocalTime(&t);
    swprintf(g_touchTime, ARRAYSIZE(g_touchTime), L"%02d:%02d:%02d", t.wHour, t.wMinute, t.wSecond);
    if (!ok) { lock_failed(); return; }
    g_lockChecks = 0;
    SetTimer(g_hwnd, T_VERIFY, VERIFY_MS, NULL);
    tray_update();
}

// ---------- menu ----------
static void show_menu(void) {
    HMENU m = CreatePopupMenu();
    AppendMenuW(m, MF_STRING | MF_GRAYED, 0, status_text());
    AppendMenuW(m, MF_SEPARATOR, 0, NULL);
    if (g_state == ST_ARMING || g_state == ST_ARMED)
        AppendMenuW(m, MF_STRING, CMD_TOGGLE, T(L"見張りをやめる", L"Stop guarding"));
    else
        AppendMenuW(m, MF_STRING | (g_state == ST_IDLE ? 0 : MF_GRAYED), CMD_TOGGLE, T(L"見張りを始める", L"Start guarding"));
    AppendMenuW(m, MF_SEPARATOR, 0, NULL);
    AppendMenuW(m, MF_STRING | (hotkey_enabled() ? MF_CHECKED : 0), CMD_HOTKEY,
                T(L"ショートカット Ctrl+Alt+L を使う", L"Use the Ctrl+Alt+L shortcut"));
    if (hotkey_enabled() && !g_hotkeyAvailable)
        AppendMenuW(m, MF_STRING | MF_GRAYED, 0, T(L"Ctrl+Alt+L はほかのアプリが使っています", L"Ctrl+Alt+L is already used by another app"));
    else if (!hotkey_enabled() && g_layoutUsesHotkey && reg_get(L"Hotkey", 2) == 2)
        AppendMenuW(m, MF_STRING | MF_GRAYED, 0, T(L"このキーボード配列では Ctrl+Alt+L が文字の入力に使われるため、オフにしています",
                                                    L"Off because this keyboard layout uses Ctrl+Alt+L to type a character"));
    AppendMenuW(m, MF_SEPARATOR, 0, NULL);
    AppendMenuW(m, MF_STRING, CMD_GUIDE, T(L"使い方と安全性", L"How it works & safety"));
    AppendMenuW(m, MF_STRING | MF_GRAYED, 0, L"Sawaruna for Windows " APP_VERSION);
    AppendMenuW(m, MF_SEPARATOR, 0, NULL);
    AppendMenuW(m, MF_STRING, CMD_QUIT, T(L"Sawaruna を終了", L"Quit Sawaruna"));

    POINT p;
    GetCursorPos(&p);
    SetForegroundWindow(g_hwnd);
    TrackPopupMenu(m, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, p.x, p.y, 0, g_hwnd, NULL);
    PostMessageW(g_hwnd, WM_NULL, 0, 0);
    DestroyMenu(m);
}

static void first_run(void) {
    if (reg_get(L"FirstRunDone", 0)) return;
    reg_set(L"FirstRunDone", 1);
    wchar_t text[1400];
    const wchar_t *step1 = hotkey_enabled() && g_hotkeyAvailable
        ? T(L"1. Ctrl+Alt+L を押すか、Sawaruna のアイコンから「見張りを始める」を選びます。Sawaruna をもう一度開いても見張りが始まります。\n",
            L"1. Press Ctrl+Alt+L, or choose \"Start guarding\" from the Sawaruna icon. Opening Sawaruna again also starts guarding.\n")
        : T(L"1. Sawaruna のアイコンから「見張りを始める」を選びます。Sawaruna をもう一度開いても見張りが始まります。\n",
            L"1. Choose \"Start guarding\" from the Sawaruna icon. Opening Sawaruna again also starts guarding.\n");
    swprintf(text, ARRAYSIZE(text), L"%ls%ls%ls",
        T(L"Sawaruna は画面右下の通知領域にいます（見当たらないときは「^」を押してください）。\n\n",
          L"Sawaruna is in the notification area at the bottom right of the screen (if you don't see it, select the ^ arrow).\n\n"),
        step1,
        T(L"2. 3秒間、手を離します。音が鳴り、アイコンが変わったら見張りが始まります。\n"
          L"3. だれかがマウスやキーボードに触ると、すぐに PC がロックされます。解除はいつものパスワードや PIN です。ロックすると見張りは終了します。\n\n"
          L"AI エージェントなどのソフトが送る操作は無視します。押したキーの内容は読まず、記録もしません。\n"
          L"ほかのアプリで Ctrl+Alt+L を使う場合は、メニューでオフにできます。",
          L"2. Keep your hands off for 3 seconds. When a sound plays and the icon changes, guarding has started.\n"
          L"3. If anyone touches the mouse or keyboard, the PC locks right away. Sign in as usual with your password or PIN. Guarding ends when the PC locks.\n\n"
          L"Input sent by software, such as an AI agent, is ignored. Keystrokes are never read or recorded.\n"
          L"If another app uses Ctrl+Alt+L, you can turn the shortcut off from the menu."));
    MessageBoxW(NULL, text, L"Sawaruna", MB_ICONINFORMATION | MB_OK | MB_TOPMOST);
}

static void wts_register(void) {
    g_wtsRegistered = WTSRegisterSessionNotification(g_hwnd, NOTIFY_FOR_THIS_SESSION);
    if (g_wtsRegistered) KillTimer(g_hwnd, T_WTS);
    else SetTimer(g_hwnd, T_WTS, 2000, NULL);   // the service may not be ready yet at sign-in
}

// ---------- window ----------
static LRESULT CALLBACK wnd_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == g_taskbarCreated && g_taskbarCreated) { tray_add(); return 0; }
    switch (msg) {
    case WM_APP_TRAY:
        if (lp == WM_RBUTTONUP || lp == WM_LBUTTONUP || lp == WM_CONTEXTMENU) show_menu();
        return 0;
    case WM_APP_HUMAN:
        if (g_state == ST_ARMING) SetTimer(h, T_ARM, ARM_MS, NULL);   // a person is still touching: wait again
        else if (g_state == ST_ARMED) lock_now();
        return 0;
    case WM_APP_START:
        if (g_state == ST_IDLE) start_guard();
        return 0;
    case WM_HOTKEY:
        if (GetAsyncKeyState(VK_RMENU) & 0x8000) return 0;   // AltGr+L, not Ctrl+Alt+L
        if (g_state == ST_IDLE) start_guard();
        else if (g_state == ST_ARMING) stop_guard();            // pressed by mistake: press again to cancel
        return 0;
    case WM_TIMER:
        if (wp == T_ARM && g_state == ST_ARMING) {
            KillTimer(h, T_ARM);
            set_state(ST_ARMED);
            tray_update();
            MessageBeep(MB_ICONASTERISK);
        } else if (wp == T_VERIFY && g_state == ST_LOCKING) {
            if (session_locked()) { KillTimer(h, T_VERIFY); lock_confirmed(); }
            else if (++g_lockChecks >= LOCK_CHECKS) { KillTimer(h, T_VERIFY); lock_failed(); }
            else if (g_lockChecks == 2 || g_lockChecks == 4) LockWorkStation();   // try again
        } else if (wp == T_WTS) {
            wts_register();
        } else if (wp == T_TRAY) {
            tray_add();
        }
        return 0;
    case WM_WTSSESSION_CHANGE:
        if (wp == WTS_SESSION_LOCK) {
            if (g_state == ST_LOCKING) lock_confirmed();                        // Sawaruna locked it
            else if (g_state == ST_ARMING || g_state == ST_ARMED) {
                if (session_locked()) stop_guard();                             // the user locked it
            }
        } else if (wp == WTS_SESSION_UNLOCK && g_noticePending) {
            wchar_t text[200];
            g_noticePending = FALSE;
            swprintf(text, ARRAYSIZE(text), T(L"%ls に、だれかがこの PC に触れました。見張りは終了しています。",
                                              L"Someone touched this PC at %ls. Guarding has ended."), g_touchTime);
            tray_notice(T(L"人の操作を検知したのでロックしました", L"Human touch detected. Locked"), text, NIIF_WARNING);
        }
        return 0;
    case WM_COMMAND:
        switch (LOWORD(wp)) {
        case CMD_TOGGLE:
            if (g_state == ST_ARMING || g_state == ST_ARMED) stop_guard(); else start_guard();
            break;
        case CMD_HOTKEY:
            reg_set(L"Hotkey", hotkey_enabled() ? 0 : 1);
            hotkey_apply();
            break;
        case CMD_GUIDE:
            ShellExecuteW(NULL, L"open", g_ja ? L"https://sawaruna.com/ja/" : L"https://sawaruna.com/", NULL, NULL, SW_SHOWNORMAL);
            break;
        case CMD_QUIT:
            DestroyWindow(h);
            break;
        }
        return 0;
    case WM_DESTROY:
        stop_guard();
        UnregisterHotKey(h, HOTKEY_ID);
        if (g_wtsRegistered) WTSUnRegisterSessionNotification(h);
        if (g_trayAdded) Shell_NotifyIconW(NIM_DELETE, &g_nid);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(h, msg, wp, lp);
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, PWSTR cmd, int show) {
    (void)prev; (void)cmd; (void)show;
    g_inst = inst;
    g_ja = PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_JAPANESE;

    // One copy only. Opening Sawaruna again starts guarding (like the Mac version).
    HANDLE mutex = CreateMutexW(NULL, TRUE, L"Local\\SawarunaSingleInstance");
    DWORD err = GetLastError();
    if (err == ERROR_ALREADY_EXISTS || (!mutex && err == ERROR_ACCESS_DENIED)) {
        for (int i = 0; i < 20; i++) {   // the first copy may still be starting
            HWND other = FindWindowW(L"SawarunaWindow", NULL);
            if (other) { PostMessageW(other, WM_APP_START, 0, 0); break; }
            Sleep(250);
        }
        if (mutex) CloseHandle(mutex);
        return 0;
    }

    g_layoutUsesHotkey = layout_uses_altgr_l();

    g_hookReady = CreateEventW(NULL, FALSE, FALSE, NULL);
    HANDLE th = CreateThread(NULL, 0, hook_thread, NULL, 0, &g_hookThreadId);
    if (!th || WaitForSingleObject(g_hookReady, 5000) != WAIT_OBJECT_0) return 1;

    WNDCLASSEXW wc;
    ZeroMemory(&wc, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = inst;
    wc.lpszClassName = L"SawarunaWindow";
    wc.hIcon = LoadIconW(inst, MAKEINTRESOURCEW(IDI_APP));
    RegisterClassExW(&wc);
    // A hidden top-level window: it receives tray, shortcut and lock/unlock messages
    g_hwnd = CreateWindowExW(WS_EX_TOOLWINDOW, L"SawarunaWindow", L"Sawaruna", WS_POPUP,
                             0, 0, 0, 0, NULL, NULL, inst, NULL);
    if (!g_hwnd) return 1;

    g_taskbarCreated = RegisterWindowMessageW(L"TaskbarCreated");
    wts_register();
    tray_add();
    hotkey_apply();
    first_run();

    MSG m;
    while (GetMessageW(&m, NULL, 0, 0) > 0) {
        TranslateMessage(&m);
        DispatchMessageW(&m);
    }
    PostThreadMessageW(g_hookThreadId, WM_QUIT, 0, 0);
    WaitForSingleObject(th, 3000);
    if (mutex) { ReleaseMutex(mutex); CloseHandle(mutex); }
    return 0;
}
