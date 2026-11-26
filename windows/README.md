# Sawaruna for Windows (test version 0.1)

[日本語は下にあります](#日本語)

Lock your PC the moment a person touches it, while AI agents keep working.

## Use

1. Open `Sawaruna.exe`. Its icon appears in the notification area at the bottom right (select the ^ arrow if you don't see it).
2. Press **Ctrl+Alt+L**, or choose **Start guarding** from the icon. Opening Sawaruna again also starts guarding.
3. Keep your hands off for 3 seconds. When a sound plays and the icon changes, guarding has started.
4. If anyone touches the mouse or keyboard, the PC locks. Sign in as usual. Guarding ends when the PC locks.

This test version is not signed yet, so Windows may show "Windows protected your PC". Select **More info**, then **Run anyway**.

No installation and no extra permission is needed. To remove it, quit Sawaruna from its menu and delete the file. Settings are stored in `HKEY_CURRENT_USER\Software\Sawaruna`.

## How it tells an agent from a person

Windows marks input created by software (SendInput and similar) as "injected". Sawaruna ignores injected input and locks on input that comes from a physical mouse or keyboard. It only checks that flag and the type of event. It never reads which key was pressed or where the mouse is.

## What it never does

- Sawaruna itself never connects to the internet. ("How it works & safety" opens sawaruna.com in your browser only when you click it.)
- It never reads or records which keys you press.
- It watches input only from the moment you start guarding (including the 3-second wait) until the PC locks.
- From the first touch until the lock, a person's mouse and keyboard input is blocked.

## Limits

Sawaruna is a tripwire for someone walking up to your PC. It is not a security boundary.

- **Input from software is ignored.** That includes AI agents, but also remote-control and input-sharing tools (TeamViewer, AnyDesk, VNC, Quick Assist, Mouse Without Borders), the on-screen and touch keyboards, and voice or eye control. A person using those will not trigger a lock.
- **Remote Desktop and virtual machines count as a person.** Input over Remote Desktop, or from a host into a virtual machine, is not marked injected, so it locks the PC.
- **Windows hides some input from normal apps:** windows running as administrator, UAC prompts, and the Ctrl+Alt+Del screen. Touches there may not be detected. Touchscreen and pen input may not be detected on every device.
- **Any program running under your account can stop or quit Sawaruna.**
- **After locking, your PC is as safe as your Windows sign-in** (password, PIN, Windows Hello).
- On keyboard layouts where AltGr+L types a letter (for example Polish), the Ctrl+Alt+L shortcut is off by default.

## License

GPL-3.0-or-later. "Sawaruna" and the Sawaruna logo are trademarks of Yoshiki Nakamura.

---

## 日本語

AI に作業を続けさせたまま、人が触った瞬間に PC をロックします。

### 使い方

1. `Sawaruna.exe` を開きます。画面右下の通知領域にアイコンが出ます（見当たらないときは「^」を押してください）。
2. **Ctrl+Alt+L** を押すか、アイコンから **見張りを始める** を選びます。Sawaruna をもう一度開いても見張りが始まります。
3. 3秒間、手を離します。音が鳴り、アイコンが変わったら見張りが始まります。
4. だれかがマウスやキーボードに触ると、PC がロックされます。解除はいつものサインインです。ロックすると見張りは終了します。

この試作版はまだ署名していないため、「Windows によって PC が保護されました」と表示されることがあります。**詳細情報** を押してから **実行** を選んでください。

インストールも追加の許可も不要です。削除するときは、メニューから Sawaruna を終了してファイルを消してください。設定は `HKEY_CURRENT_USER\Software\Sawaruna` に保存します。

### エージェントと人を見分けるしくみ

Windows は、ソフトが作った操作（SendInput など）に「injected（注入された）」という印を付けます。Sawaruna はこの印がある操作を無視し、実物のマウスやキーボードからの操作でロックします。確かめるのはこの印と操作の種類だけで、どのキーが押されたかやマウスの位置は読みません。

### しないこと

- Sawaruna 自体はインターネットに接続しません（「使い方と安全性」を押したときだけ、ブラウザで sawaruna.com を開きます）。
- 押したキーの内容は読まず、記録もしません。
- 入力を見るのは、見張りを始めてから（手を離して待つ3秒を含みます）ロックするまでだけです。
- 触られてからロックするまでの間は、人のマウスとキーボードの操作を止めます。

### できないこと

Sawaruna は、PC に近づいた人に気づくための仕掛けです。セキュリティの境界ではありません。

- **ソフトからの操作は無視します。** AI エージェントだけでなく、リモート操作や入力共有のツール（TeamViewer、AnyDesk、VNC、クイック アシスト、Mouse Without Borders）、スクリーン キーボードやタッチ キーボード、音声や視線での操作も含みます。これらを使った人の操作ではロックされません。
- **リモート デスクトップと仮想マシンは「人の操作」になります。** リモート デスクトップ経由の操作や、ホストから仮想マシンへの操作には印が付かないため、ロックされます。
- **Windows が通常のアプリに見せない操作があります。** 管理者として実行中のウィンドウ、UAC の確認画面、Ctrl+Alt+Del の画面への操作は、気づけないことがあります。タッチ画面やペンの操作も、機種によっては気づけません。
- **同じアカウントで動くプログラムは、Sawaruna を止めたり終了したりできます。**
- **ロックしたあとの安全性は、Windows のサインイン（パスワード、PIN、Windows Hello）と同じです。**
- AltGr+L で文字を入力するキーボード配列（ポーランド語など）では、Ctrl+Alt+L のショートカットは最初からオフになります。

### ライセンス

GPL-3.0-or-later。「Sawaruna」の名前とロゴは中村圭希（Yoshiki Nakamura）の商標です。
