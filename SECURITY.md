# Security

[日本語](SECURITY.ja.md)

Sawaruna uses powerful permissions: Input Monitoring, and optionally the camera. This page lists everything it does and does not do. You can check every point by reading the single source file, `Sawaruna.swift`.

## Three promises

1. **No internet connection.** The app contains no networking code. Photos and settings never leave your Mac.
2. **No keystroke logging.** Sawaruna never uses or records which keys you press. It only uses the fact that something was touched.
3. **Input is watched only while guarding.** That means from the moment you start guarding (including the 3-second wait) until it locks. When idle, and after it has locked the screen, it watches nothing.

## Permissions

| Permission | Used for | Never used for |
|---|---|---|
| Input Monitoring | Noticing the moment the mouse or keyboard is touched | Using or saving which keys are pressed |
| Camera (optional) | Taking three photos at the moment of a touch, only if you turn it on | Taking photos at any other time, recording video, sending anything |

The photo feature is off by default. Sawaruna does not ask for camera access unless you turn it on.

## What is stored on your Mac

| Data | Location | Notes |
|---|---|---|
| Photos (only if turned on) | `Pictures/Sawaruna` | Saved so that only your user account can open them |
| Settings (such as photos on or off) | Standard macOS preferences | No personal data |

No record of your input is stored anywhere. A diagnostic log is written to `~/Library/Logs/sawaruna.log` only if you create a file named `.sawaruna-debug` in your home folder yourself. It contains only states such as "guarding started" and "locked", and it is cleared every time the app starts.

## Safety design

- **Input is received only while guarding.** The event tap is created when guarding starts and removed when it ends.
- **Input stops the moment it locks.** The password you type on the lock screen never reaches Sawaruna.
- **AI input and human input are told apart** by which process sent each event. Physical devices send input through the system (process ID 0). Sawaruna also listens to the physical keyboard directly, because macOS hides key events while a password field is active. There, it only checks that the input is a keyboard key, never which key.
- **The lock is verified.** After asking macOS to lock, Sawaruna checks that the screen is actually locked. If not, it keeps the screen covered, tries another method (turning the display off, which locks only if "Require password immediately" is set in Lock Screen settings), and warns you if that also fails.
- **It fails toward locking.** While guarding, Sawaruna checks itself every 2 seconds. If it can no longer watch (for example, the permission was removed), it locks immediately.
- **Protection against injection.** The app is signed with the Hardened Runtime, which makes it much harder for other programs to inject code into Sawaruna and misuse its permissions.

## Limits

Sawaruna cannot prevent:

- **Shoulder surfing.** The screen stays visible while guarding.
- **Remote control software.** Screen sharing and similar tools send input the same way an AI agent does, so they do not trigger a lock.
- **Voice control** and other input that does not involve touching the mouse or keyboard.
- **The moment before the lock.** Locking takes 0.8 seconds after a touch (up to 2 seconds with photos on). The screen is covered during that time, but some macOS shortcuts cannot be blocked.
- **The app being force-quit.** If Sawaruna is killed, guarding stops.
- **Physical access**, such as carrying the Mac away or turning it off. Use Find My and FileVault as well.

For anything truly sensitive, lock your Mac with Control + Command + Q. Sawaruna is a tool for letting an AI keep working with the screen visible.

## Photos and the law

Photographing people without their consent may be restricted by law in some countries and places. At work or in public places, check the local rules and post a notice if needed.

## How to verify

- The whole app is one file, `Sawaruna.swift`. Search it to confirm there is no networking code (for example, `URLSession`).
- `install.command` builds the app from this source on your own Mac.

## Reporting a problem

- **Security issues:** please do not open a public issue. Report privately with GitHub's "Report a vulnerability" button on the Security tab.
- **Other bugs and questions:** https://github.com/yoshn/sawaruna/issues
