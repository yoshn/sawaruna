// Sawaruna
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

import Cocoa
import AVFoundation
import CoreImage
import IOKit.pwr_mgt
import IOKit.hid
import Carbon.HIToolbox

// Sawaruna
// AIにMacを任せて席を離れるための見張り番。人がマウスやキーボードに触ると、すぐにロックする。
//
// 安全のための約束（このファイルを読めば確かめられます）
//  1. インターネットに接続しない（通信するコードを一切含まない）
//  2. マウスやキーボードを見るのは「見張り中」だけ。待機中とロックしたあとは何も見ない
//  3. 押されたキーの内容は読まない・記録しない（使うのは「触られた」という事実だけ）
//  4. 写真は利用者が自分でオンにしたときだけ撮り、このMacの中にだけ保存する

// ===== 表示する言語 =====
// Macの言語設定の優先順に見て、対応している最初の言語を使う（どれも対応していなければ英語）
func pickLanguage() -> String {
    for raw in Locale.preferredLanguages {
        let l = raw.lowercased()
        if l.hasPrefix("zh") {
            // 中国語は繁体字（台湾・香港・マカオ）と簡体字を分ける
            if l.contains("hant") || l.hasSuffix("-tw") || l.hasSuffix("-hk") || l.hasSuffix("-mo") { return "zh-Hant" }
            return "zh-Hans"
        }
        let head = String(l.split(separator: "-").first ?? "")   // 「nb-NO」なら「nb」
        // ノルウェー語は書き方が2種類あるが、どちらもブークモール（nb）で表示する
        if head == "no" || head == "nn" { return "nb" }
        if head == "iw" { return "he" }   // ヘブライ語の古い書き方
        let codes = ["ja", "en", "ko", "es", "fr", "de", "pt", "it",
                     "ru", "hi", "id", "tr", "nl", "pl", "vi", "th", "sv", "uk",
                     "da", "nb", "fi", "is", "he"]
        if codes.contains(head) { return head }
    }
    return "en"
}
let language = pickLanguage()

// ===== 右から左に書く言語（ヘブライ語）=====
// 文字を右寄せにし、アイコンやボタンの並びも左右反対にする
let isRTL = (language == "he")
// 部品の並び（横に並べる順番・寄せる側）を右から左にする
func rtlLayout(_ v: NSView) {
    if isRTL { v.userInterfaceLayoutDirection = .rightToLeft }
}
// 文字を右寄せ・右から左にする
func rtlText(_ t: NSTextField) {
    if isRTL {
        t.alignment = .right
        t.baseWritingDirection = .rightToLeft
    }
}
// 位置を数字で決めている部品を、左右反対の位置に置く（total は入れ物の幅）
func rtlX(_ x: CGFloat, _ width: CGFloat, in total: CGFloat) -> CGFloat {
    isRTL ? total - x - width : x
}

// 日本語と英語の文言はこのファイルに、それ以外の言語はアプリの中の Localizations.json にある。
// Localizations.json は「英語の文 → その言語の文」の対応表で、文を足せば言語を増やせる
let translations: [String: String] = {
    guard language != "ja", language != "en",
          let url = Bundle.main.url(forResource: "Localizations", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let all = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: String]] else { return [:] }
    return all[language] ?? [:]
}()

func L(_ ja: String, _ en: String) -> String {
    if language == "ja" { return ja }
    return translations[en] ?? en
}
// 文の途中に時刻や枚数を入れるとき（%@ の位置に入る）
func LF(_ ja: String, _ en: String, _ args: CVarArg...) -> String {
    String(format: L(ja, en), arguments: args)
}

// 動作記録（~/.sawaruna-debug があるときだけ）。
// 書くのは「開始・見張り開始・ロック」などの状態だけで、操作の内容（どのキーが押されたかなど）は一切書かない
let debug = FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.sawaruna-debug")
let logPath = NSHomeDirectory() + "/Library/Logs/sawaruna.log"
// 以前の記録は起動のたびに消す
try? FileManager.default.removeItem(atPath: logPath)
func log(_ s: String) {
    guard debug else { return }
    let data = "\(Date()) \(s)\n".data(using: .utf8) ?? Data()
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile(); h.write(data); h.closeFile()
    } else {
        // 本人だけが読める権限で作る
        FileManager.default.createFile(atPath: logPath, contents: data, attributes: [.posixPermissions: 0o600])
    }
}

let accentA = NSColor(srgbRed: 0.31, green: 0.82, blue: 1.00, alpha: 1).cgColor   // シアン
let accentB = NSColor(srgbRed: 0.55, green: 0.36, blue: 0.96, alpha: 1).cgColor   // バイオレット

// 見張りの状態
//  idle    待機中（マウスもキーボードも見ていない）
//  arming  準備中（手を離して3秒たつのを待っている）
//  armed   見張り中（人が触るとロックする）
//  locking ロックした（ロックが解除されるのを待っている。マウスもキーボードも見ていない）
enum WatchState { case idle, arming, armed, locking }
var watchState: WatchState = .idle
var watchGeneration = 0            // 見張りを始める・終えるたびに増える。古いタイマーの動作を無効にするための番号
var lastHuman = Date()
var lockConfirmed = false
var tap: CFMachPort?
var tapSource: CFRunLoopSource?
var hidManager: IOHIDManager?
var armTimer: Timer?
var flashWindows: [NSWindow] = []
var pillWindow: NSWindow?
var pillRing: CAShapeLayer?
var pillRingView: NSView?
var pillIcon: NSImageView?
var pillTitle: NSTextField?
var pillSub: NSTextField?
var assertionID: IOPMAssertionID = 0
var sleepAssertionID: IOPMAssertionID = 0
var activityID: IOPMAssertionID = 0
var camera: Camera?
var capturedPhotos: [URL] = []
var captureDone = false
var lockedAt = Date()
var noticeWindow: NSWindow?
let armSound = NSSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true)

// 画面まわりの部品（あとで中身を入れる）
var onStateChange: () -> Void = {}
var openOnboarding: (Int?) -> Void = { _ in }
var onboardingVisible: () -> Bool = { false }

// 設定の保存
let defaults = UserDefaults.standard
func photoEnabled() -> Bool { defaults.bool(forKey: "photoEnabled") }
func setPhotoEnabled(_ on: Bool) { defaults.set(on, forKey: "photoEnabled") }

// ===== ショートカットキー（control + option + L で見張りを始める） =====
// RegisterEventHotKey は「この組み合わせが押された」ことだけを知らせる仕組みで、追加の許可はいらない
func hotkeyEnabled() -> Bool { !defaults.bool(forKey: "hotkeyOff") }
func setHotkeyEnabled(_ on: Bool) { defaults.set(!on, forKey: "hotkeyOff"); registerHotKey() }
var hotKeyRef: EventHotKeyRef?
var hotKeyHandlerInstalled = false
var hotKeyAvailable = true    // ほかのアプリが同じ組み合わせを使っていると false
var onHotKey: () -> Void = {}

func registerHotKey() {
    if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
    hotKeyAvailable = true
    guard hotkeyEnabled() else { return }
    if !hotKeyHandlerInstalled {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { onHotKey() }
            return noErr
        }, 1, &spec, nil, nil)
        hotKeyHandlerInstalled = true
    }
    let id = EventHotKeyID(signature: OSType(0x5357_4B59), id: 1)   // "SWKY"
    let status = RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(controlKey | optionKey), id,
                                     GetApplicationEventTarget(), 0, &hotKeyRef)
    if status != noErr { hotKeyRef = nil; hotKeyAvailable = false }
    log("hotkey " + (status == noErr ? "on" : "unavailable \(status)"))
}
func onboardingDone() -> Bool { defaults.bool(forKey: "onboardingDone") }

let listenSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
let cameraSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
func openSettings(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }

// 撮った写真は「ピクチャ/Sawaruna/日付/時刻」のフォルダに、1回ごとにまとめて保存する
let photoRoot = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Pictures/Sawaruna", isDirectory: true)
func eventFolder(for date: Date) -> URL {
    // フォルダ名は、Macの暦や数字の設定（仏暦など）に左右されない決まった形にする
    let d = DateFormatter()
    d.locale = Locale(identifier: "en_US_POSIX")
    d.dateFormat = "yyyy-MM-dd"
    let t = DateFormatter()
    t.locale = Locale(identifier: "en_US_POSIX")
    t.dateFormat = language == "ja" ? "HH時mm分ss秒" : "HH-mm-ss"
    return photoRoot.appendingPathComponent(d.string(from: date), isDirectory: true)
        .appendingPathComponent(t.string(from: date), isDirectory: true)
}

// ===== 触った人の撮影（利用者がオンにしたときだけ） =====
// 触られた瞬間だけカメラを起動し、約2秒のあいだに3枚撮って、すぐにカメラを止める。
// 見張っている間はカメラを使わない。写真はこのMacの中にだけ保存し、どこにも送らない
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "com.sawaruna.app.camera")
    let ci = CIContext()
    let folder: URL
    var firstFrame: CMTime?
    var shotTimes: [Double] = [0.35, 1.2, 2.2]   // カメラ起動からの秒数（あとになるほど明るさが安定する）
    var saved: [URL] = []
    var finished = false
    var onFirst: (() -> Void)?
    var onDone: (([URL]) -> Void)?

    init(folder: URL) {
        self.folder = folder
        super.init()
    }

    func start() -> Bool {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              let dev = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: dev) else { return false }
        session.beginConfiguration()
        session.sessionPreset = .high
        guard session.canAddInput(input) else { session.commitConfiguration(); return false }
        session.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(out) else { session.commitConfiguration(); return false }
        session.addOutput(out)
        session.commitConfiguration()
        // 写真のフォルダは本人だけが開ける権限で作る
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        queue.async { self.session.startRunning() }
        return true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if finished || shotTimes.isEmpty { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstFrame == nil { firstFrame = pts }
        guard let ff = firstFrame else { return }
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, ff))
        guard elapsed >= shotTimes[0], let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        shotTimes.removeFirst()
        let img = CIImage(cvPixelBuffer: pb)
        if let cg = ci.createCGImage(img, from: img.extent),
           let data = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            let url = folder.appendingPathComponent(L("写真", "photo") + "\(saved.count + 1).jpg")
            if (try? data.write(to: url)) != nil {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                saved.append(url)
                if saved.count == 1 {
                    let cb = onFirst
                    DispatchQueue.main.async { cb?() }
                }
            }
        }
        if shotTimes.isEmpty { finish() }
    }

    // queue の上で呼ぶ
    func finish() {
        if finished { return }
        finished = true
        let urls = saved
        queue.async { self.session.stopRunning() }
        let cb = onDone
        DispatchQueue.main.async { cb?(urls) }
    }
}

// 通知のクリックを受け取るための部品
final class ClickView: NSView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

// ロック解除後に「誰かが触れました」と知らせる（写真があれば写真付き）
func showIntruderNotice() {
    guard watchState == .locking, noticeWindow == nil else { return }
    let gen = watchGeneration
    let mouse = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
        finishWatch()
        return
    }
    let w: CGFloat = 500, h: CGFloat = 92
    let vf = screen.visibleFrame
    let frame = NSRect(x: vf.midX - w / 2, y: vf.maxY - h - 14, width: w, height: h)
    let win = NSWindow(contentRect: frame.offsetBy(dx: 0, dy: 12), styleMask: .borderless, backing: .buffered, defer: false)
    win.level = .screenSaver
    win.isOpaque = false
    win.backgroundColor = .clear
    win.hasShadow = true
    win.isReleasedWhenClosed = false
    win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

    let bounds = NSRect(x: 0, y: 0, width: w, height: h)
    let blur = NSVisualEffectView(frame: bounds)
    blur.material = .hudWindow
    blur.blendingMode = .behindWindow
    blur.state = .active
    blur.appearance = NSAppearance(named: .darkAqua)
    blur.maskImage = NSImage(size: bounds.size, flipped: false) { r in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: r, xRadius: 26, yRadius: 26).fill()
        return true
    }
    win.contentView = blur

    let photos = capturedPhotos
    let thumb = NSImageView(frame: NSRect(x: rtlX(14, 64, in: w), y: 14, width: 64, height: 64))
    thumb.wantsLayer = true
    thumb.layer?.cornerRadius = 14
    thumb.layer?.masksToBounds = true
    thumb.layer?.borderWidth = 2
    thumb.layer?.borderColor = accentA
    thumb.imageScaling = .scaleProportionallyUpOrDown
    if let last = photos.last, let img = NSImage(contentsOf: last) {
        thumb.image = img
    } else {
        thumb.image = symbol("exclamationmark.shield.fill", size: 28)
        thumb.contentTintColor = .white
        thumb.imageScaling = .scaleNone
    }
    blur.addSubview(thumb)

    let tf = DateFormatter()
    tf.dateFormat = "H:mm"
    let t = tf.string(from: lockedAt)
    let title = NSTextField(labelWithString: LF("%@ に誰かがMacに触れました", "Someone touched this Mac at %@", t))
    title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
    title.textColor = .white
    title.frame = NSRect(x: rtlX(92, w - 108, in: w), y: h / 2 + 2, width: w - 108, height: 20)
    title.lineBreakMode = .byTruncatingTail
    rtlText(title)
    blur.addSubview(title)
    let subText: String
    if !photoEnabled() {
        subText = L("画面をロックしました（写真の記録はオフです）", "The screen was locked (photo capture is off)")
    } else if photos.isEmpty {
        subText = L("写真は撮影できませんでした（カメラが使えない状態でした）", "No photo was taken (the camera was unavailable)")
    } else {
        subText = LF("写真%@枚を保存しました。クリックでフォルダを開きます",
                     "Saved %@ photo(s). Click to open the folder", "\(photos.count)")
    }
    let sub = NSTextField(labelWithString: subText)
    sub.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    sub.textColor = NSColor(white: 1, alpha: 0.65)
    sub.frame = NSRect(x: rtlX(92, w - 108, in: w), y: h / 2 - 18, width: w - 108, height: 16)
    sub.lineBreakMode = .byTruncatingTail
    rtlText(sub)
    blur.addSubview(sub)

    let click = ClickView(frame: bounds)
    click.onClick = {
        if let first = photos.first { NSWorkspace.shared.activateFileViewerSelecting([first]) }
        if gen == watchGeneration { finishWatch() }
    }
    blur.addSubview(click)

    noticeWindow = win
    NSApp.unhideWithoutActivation()
    win.alphaValue = 0
    win.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.25
        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
        win.animator().alphaValue = 1
        win.animator().setFrame(frame, display: true)
    }
    NSSound(contentsOfFile: "/System/Library/Sounds/Ping.aiff", byReference: true)?.play()
    // 12秒たったら自動で消して、待機に戻る
    DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
        guard gen == watchGeneration, noticeWindow === win else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            win.animator().alphaValue = 0
        }, completionHandler: {
            if gen == watchGeneration { finishWatch() }
        })
    }
}

// ===== ロックの瞬間に出す演出 =====
// 画面をぼかして暗くし、光る南京錠の掛け金が「カチッ」と閉まり、波紋が広がる

// 演出中は画面の上にかぶさり、クリックもキー入力も下のアプリに通さない
class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool { true }
}


func anim(_ key: String, _ from: Any, _ to: Any, begin: CFTimeInterval, dur: CFTimeInterval,
          fill: CAMediaTimingFillMode = .both) -> CABasicAnimation {
    let a = CABasicAnimation(keyPath: key)
    a.fromValue = from
    a.toValue = to
    a.beginTime = begin
    a.duration = dur
    a.timingFunction = CAMediaTimingFunction(name: .easeOut)
    a.fillMode = fill
    a.isRemovedOnCompletion = false
    return a
}

func kerned(_ text: String, font: NSFont, color: NSColor, kern: CGFloat) -> NSAttributedString {
    let m = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    if text.count > 1 {
        let len = (text as NSString).length
        m.addAttribute(.kern, value: kern, range: NSRange(location: 0, length: len - 1))
    }
    return m
}

func buildLockScene(_ root: CALayer, size: CGSize, scale: CGFloat, t0: CFTimeInterval, timeText: String) {
    let k = max(0.6, min(1.4, size.height / 1000))   // 画面サイズに合わせた倍率
    let cx = size.width / 2
    let cy = size.height / 2 + 60 * k

    // 暗幕
    let dim = CALayer()
    dim.frame = CGRect(origin: .zero, size: size)
    dim.backgroundColor = NSColor(srgbRed: 0.02, green: 0.03, blue: 0.08, alpha: 0.55).cgColor
    root.addSublayer(dim)

    // 背後の光
    let glow = CAGradientLayer()
    glow.type = .radial
    glow.colors = [NSColor(srgbRed: 0.42, green: 0.55, blue: 1.0, alpha: 0.55).cgColor,
                   NSColor(srgbRed: 0.42, green: 0.55, blue: 1.0, alpha: 0.0).cgColor]
    glow.startPoint = CGPoint(x: 0.5, y: 0.5)
    glow.endPoint = CGPoint(x: 1, y: 1)
    let gr = 300 * k
    glow.frame = CGRect(x: cx - gr, y: cy - gr, width: gr * 2, height: gr * 2)
    root.addSublayer(glow)
    glow.add(anim("transform.scale", 0.4, 1.0, begin: t0, dur: 0.5), forKey: "s")
    glow.add(anim("opacity", 0.0, 1.0, begin: t0, dur: 0.3), forKey: "o")

    // 掛け金が閉まった瞬間に広がる波紋
    for i in 0..<2 {
        let r = 95 * k
        let ring = CAShapeLayer()
        ring.frame = CGRect(x: cx - r, y: cy - r - 20 * k, width: r * 2, height: r * 2)
        ring.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: r * 2, height: r * 2), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = i == 0 ? accentA : accentB
        ring.lineWidth = 3 * k
        ring.opacity = 0
        root.addSublayer(ring)
        let b = t0 + 0.26 + Double(i) * 0.14
        ring.add(anim("transform.scale", 0.9, 2.8, begin: b, dur: 0.8, fill: .forwards), forKey: "s")
        ring.add(anim("opacity", 0.9, 0.0, begin: b, dur: 0.8, fill: .forwards), forKey: "o")
    }

    // 南京錠
    let lw = 150 * k, lh = 200 * k, bodyH = 112 * k
    let lock = CALayer()
    lock.frame = CGRect(x: cx - lw / 2, y: cy - lh / 2 - 20 * k, width: lw, height: lh)
    lock.shadowColor = accentB
    lock.shadowRadius = 34 * k
    lock.shadowOpacity = 0.9
    lock.shadowOffset = .zero
    root.addSublayer(lock)

    // 掛け金（U字）
    let sw = lw * 0.62
    let left = (lw - sw) / 2, right = lw - left
    let arcY = lh - 10 * k - sw / 2
    let sp = CGMutablePath()
    sp.move(to: CGPoint(x: left, y: bodyH - 8 * k))
    sp.addLine(to: CGPoint(x: left, y: arcY))
    sp.addArc(center: CGPoint(x: lw / 2, y: arcY), radius: sw / 2, startAngle: .pi, endAngle: 0, clockwise: true)
    sp.addLine(to: CGPoint(x: right, y: bodyH - 8 * k))
    let shackle = CAShapeLayer()
    shackle.frame = CGRect(x: 0, y: 0, width: lw, height: lh)
    shackle.path = sp
    shackle.fillColor = nil
    shackle.strokeColor = NSColor(white: 0.96, alpha: 1).cgColor
    shackle.lineWidth = 18 * k
    shackle.lineCap = .round
    lock.addSublayer(shackle)
    let close = CASpringAnimation(keyPath: "transform.translation.y")
    close.fromValue = 36 * k
    close.toValue = 0
    close.damping = 13
    close.stiffness = 320
    close.mass = 1
    close.beginTime = t0 + 0.12
    close.duration = close.settlingDuration
    close.fillMode = .both
    close.isRemovedOnCompletion = false
    shackle.add(close, forKey: "close")

    // 本体（グラデーション）
    let body = CAGradientLayer()
    body.frame = CGRect(x: 0, y: 0, width: lw, height: bodyH)
    body.colors = [accentA, accentB]
    body.startPoint = CGPoint(x: 0, y: 1)
    body.endPoint = CGPoint(x: 1, y: 0)
    body.cornerRadius = 28 * k
    lock.addSublayer(body)

    // 鍵穴
    let kx = lw / 2, ky = bodyH * 0.58, kr = 12 * k
    let kp = CGMutablePath()
    kp.addEllipse(in: CGRect(x: kx - kr, y: ky - kr, width: kr * 2, height: kr * 2))
    kp.addRoundedRect(in: CGRect(x: kx - 5 * k, y: ky - 34 * k, width: 10 * k, height: 30 * k),
                      cornerWidth: 5 * k, cornerHeight: 5 * k)
    let keyhole = CAShapeLayer()
    keyhole.path = kp
    keyhole.fillColor = NSColor(srgbRed: 0.05, green: 0.06, blue: 0.16, alpha: 0.85).cgColor
    lock.addSublayer(keyhole)

    // 登場して、閉まった瞬間に小さく弾む
    let pop = CAKeyframeAnimation(keyPath: "transform.scale")
    pop.values = [0.55, 1.05, 1.0, 1.0, 1.08, 0.99, 1.0]
    pop.keyTimes = [0, 0.22, 0.32, 0.38, 0.46, 0.62, 1]
    pop.beginTime = t0
    pop.duration = 0.55
    pop.fillMode = .both
    pop.isRemovedOnCompletion = false
    lock.add(pop, forKey: "pop")
    lock.add(anim("opacity", 0.0, 1.0, begin: t0, dur: 0.15), forKey: "o")

    // 文字
    func addText(_ str: NSAttributedString, top: CGFloat, delay: CFTimeInterval) -> CGFloat {
        let h = ceil(str.size().height) + 4
        let tl = CATextLayer()
        tl.string = str
        tl.alignmentMode = .center
        tl.contentsScale = scale
        tl.frame = CGRect(x: 0, y: top - h, width: size.width, height: h)
        root.addSublayer(tl)
        tl.add(anim("opacity", 0.0, 1.0, begin: t0 + delay, dur: 0.3), forKey: "o")
        tl.add(anim("transform.translation.y", -16 * k, 0.0, begin: t0 + delay, dur: 0.35), forKey: "y")
        return top - h
    }
    let title = kerned("LOCKED", font: NSFont.systemFont(ofSize: 60 * k, weight: .heavy),
                       color: NSColor(white: 1, alpha: 0.97), kern: 20 * k)
    let sub = kerned(L("人の操作を検知したのでロックしました", "Human touch detected. Locked") + "  ·  \(timeText)",
                     font: NSFont.systemFont(ofSize: 20 * k, weight: .medium),
                     color: NSColor(white: 1, alpha: 0.72),
                     kern: language == "hi" ? 0 : 1.5 * k)   // ヒンディー語は文字の間を広げると上の線が切れるので広げない
    let afterTitle = addText(title, top: lock.frame.minY - 44 * k, delay: 0.22)
    _ = addText(sub, top: afterTitle - 14 * k, delay: 0.32)
}

func showFlash() {
    pillWindow?.orderOut(nil)
    pillWindow = nil
    let t0 = CACurrentMediaTime() + 0.02
    let f = DateFormatter()
    f.dateFormat = "H:mm"
    let timeText = f.string(from: Date())
    for screen in NSScreen.screens {
        let frame = screen.frame
        let w = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let bounds = NSRect(origin: .zero, size: frame.size)
        let blur = NSVisualEffectView(frame: bounds)
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        w.contentView = blur
        let host = NSView(frame: bounds)
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: frame.size)
        host.layer = root
        host.wantsLayer = true
        blur.addSubview(host)
        buildLockScene(root, size: frame.size, scale: screen.backingScaleFactor, t0: t0, timeText: timeText)
        w.alphaValue = 0
        if flashWindows.isEmpty { w.makeKeyAndOrderFront(nil) } else { w.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            w.animator().alphaValue = 1
        }
        flashWindows.append(w)
    }
    NSApp.activate(ignoringOtherApps: true)
    NSSound(contentsOfFile: "/System/Library/Sounds/Glass.aiff", byReference: true)?.play()
}

func clearFlash() {
    for w in flashWindows { w.orderOut(nil) }
    flashWindows.removeAll()
}

// メニューから「ロックの演出を見る」を選んだとき（ロックはしない）
func previewFlash() {
    guard watchState == .idle, flashWindows.isEmpty else { return }
    showFlash()
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
        guard watchState == .idle else { return }
        let wins = flashWindows
        flashWindows.removeAll()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            for w in wins { w.animator().alphaValue = 0 }
        }, completionHandler: {
            for w in wins { w.orderOut(nil) }
            if !onboardingVisible() { NSApp.hide(nil) }
        })
    }
}

// 人が触った瞬間に呼ばれる
func lockNow() {
    // 見張り中以外では何もしない（二重に実行されるのも防ぐ）
    guard watchState == .armed else { return }
    watchState = .locking
    lockedAt = Date()
    lockConfirmed = false
    capturedPhotos = []
    captureDone = false
    armTimer?.invalidate()
    armTimer = nil
    // ここから先は、マウスもキーボードも見ない（ロック画面で入力するパスワードを見ないため）。
    // この関数は入力の受け取り口の中から呼ばれるので、まず受け取りを止め、片付けは直後に行う
    if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
    DispatchQueue.main.async { if watchState != .arming && watchState != .armed { stopListening() } }
    log("LOCK")
    onStateChange()
    showFlash()   // まず画面を覆う

    // 0.8秒だけ演出を見せてからロックする。写真がオンなら1枚目が撮れるまで待つ（最長2秒）
    var fired = false
    let fire: () -> Void = {
        if fired { return }
        fired = true
        performLock()
    }
    let minTime = DispatchTime.now() + 0.8
    if photoEnabled() {
        let c = Camera(folder: eventFolder(for: lockedAt))
        c.onFirst = { DispatchQueue.main.asyncAfter(deadline: minTime) { fire() } }
        c.onDone = { urls in
            capturedPhotos = urls
            captureDone = true
            camera = nil
            log("PHOTOS \(urls.count)")
        }
        if c.start() {
            camera = c
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { fire() }
            // カメラが反応しないときでも、6秒で必ず止める
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { c.queue.async { c.finish() } }
            return
        }
        log("camera unavailable")
    }
    captureDone = true
    DispatchQueue.main.asyncAfter(deadline: minTime) { fire() }
}

// 画面がロックされているかを確かめる
func isScreenLocked() -> Bool {
    if lockConfirmed { return true }
    guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (d["CGSSessionScreenIsLocked"] as? Bool) ?? false
}

func displaySleepNow() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["displaysleepnow"]
    try? p.run()
}

func performLock() {
    // 見張り中に止めていた画面の自動スリープを元に戻す
    releasePowerAssertions()
    // macOSのロック画面を呼び出す
    var asked = false
    if let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
       let sym = dlsym(h, "SACLockScreenImmediate") {
        typealias LockFn = @convention(c) () -> Int32
        _ = unsafeBitCast(sym, to: LockFn.self)()
        asked = true
    }
    // 予備の方法：画面を消す（「すぐにパスワードを要求」の設定でロックされる）
    if !asked { displaySleepNow() }
    verifyLock(watchGeneration, tries: 0, usedFallback: !asked)
    // ここでは終了せず、ロックが解除されるまで待って知らせる
}

// 本当にロックされたかを確かめる。ロックできていなければ、画面を覆ったまま予備の方法を試し、
// それでもだめなら利用者に知らせる（「ロックしたつもり」で終わらせない）
func verifyLock(_ gen: Int, tries: Int, usedFallback: Bool) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        guard gen == watchGeneration, watchState == .locking else { return }
        if isScreenLocked() {
            // ロック画面が出たので演出を片付けて、元の作業中のアプリに操作を戻す
            clearFlash()
            NSApp.hide(nil)
            return
        }
        if tries < 2 {
            // ロック画面が出るまで少し待つ
            verifyLock(gen, tries: tries + 1, usedFallback: usedFallback)
        } else if !usedFallback {
            log("lock not confirmed, trying fallback")
            displaySleepNow()
            verifyLock(gen, tries: tries + 1, usedFallback: true)
        } else if tries < 14 {
            verifyLock(gen, tries: tries + 1, usedFallback: true)
        } else {
            log("lock failed")
            finishWatch()
            showWarningPill(L("ロックできませんでした", "Could not lock the screen"),
                            L("システム設定の「ロック画面」を確認してください", "Check Lock Screen in System Settings"))
        }
    }
}

// ===== 見張り開始の表示（画面上部の小さなカプセル） =====
// 起動するとリングが3秒かけて満ち、満ちた瞬間に「見張り中」へ切り替わって消える
// クリックは下のアプリにそのまま通し、AIの作業のじゃまをしない

func symbol(_ name: String, size: CGFloat) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .semibold))
}

func showPill() {
    let mouse = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
    let w: CGFloat = 460, h: CGFloat = 68
    let vf = screen.visibleFrame
    let frame = NSRect(x: vf.midX - w / 2, y: vf.maxY - h - 14, width: w, height: h)
    let win = NSWindow(contentRect: frame.offsetBy(dx: 0, dy: 12), styleMask: .borderless, backing: .buffered, defer: false)
    win.level = .screenSaver
    win.isOpaque = false
    win.backgroundColor = .clear
    win.hasShadow = true
    win.ignoresMouseEvents = true
    win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

    let bounds = NSRect(x: 0, y: 0, width: w, height: h)
    let blur = NSVisualEffectView(frame: bounds)
    blur.material = .hudWindow
    blur.blendingMode = .behindWindow
    blur.state = .active
    blur.appearance = NSAppearance(named: .darkAqua)
    blur.maskImage = NSImage(size: bounds.size, flipped: false) { r in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2).fill()
        return true
    }
    win.contentView = blur

    // 細い光の縁取り
    let edge = NSView(frame: bounds)
    let edgeRoot = CALayer()
    edge.layer = edgeRoot
    edge.wantsLayer = true
    let edgeLine = CAShapeLayer()
    edgeLine.path = CGPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerWidth: h / 2 - 0.75,
                           cornerHeight: h / 2 - 0.75, transform: nil)
    edgeLine.fillColor = nil
    edgeLine.strokeColor = NSColor(white: 1, alpha: 0.14).cgColor
    edgeLine.lineWidth = 1.5
    edgeRoot.addSublayer(edgeLine)
    blur.addSubview(edge)

    // 3秒で満ちるリング（シアン→バイオレット）
    let rs: CGFloat = 46
    let ringView = NSView(frame: NSRect(x: rtlX(12, rs, in: w), y: (h - rs) / 2, width: rs, height: rs))
    let rl = CALayer()
    ringView.layer = rl
    ringView.wantsLayer = true
    let rp = CGMutablePath()
    rp.addArc(center: CGPoint(x: rs / 2, y: rs / 2), radius: rs / 2 - 3,
              startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
    let track = CAShapeLayer()
    track.path = rp
    track.fillColor = nil
    track.strokeColor = NSColor(white: 1, alpha: 0.14).cgColor
    track.lineWidth = 3.5
    rl.addSublayer(track)
    let ring = CAShapeLayer()
    ring.path = rp
    ring.fillColor = nil
    ring.strokeColor = NSColor.white.cgColor
    ring.lineWidth = 3.5
    ring.lineCap = .round
    ring.strokeEnd = 0
    ring.frame = CGRect(x: 0, y: 0, width: rs, height: rs)
    let grad = CAGradientLayer()
    grad.frame = CGRect(x: 0, y: 0, width: rs, height: rs)
    grad.colors = [accentA, accentB]
    grad.startPoint = CGPoint(x: 0, y: 1)
    grad.endPoint = CGPoint(x: 1, y: 0)
    grad.mask = ring
    rl.addSublayer(grad)
    blur.addSubview(ringView)

    let icon = NSImageView(frame: NSRect(x: rtlX(12 + (rs - 22) / 2, 22, in: w), y: (h - 22) / 2, width: 22, height: 22))
    icon.image = symbol("hand.raised.fill", size: 15)
    icon.contentTintColor = .white
    icon.imageScaling = .scaleProportionallyDown
    blur.addSubview(icon)

    let title = NSTextField(labelWithString: L("手を離すと見張りを開始します", "Let go to start guarding"))
    title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
    title.textColor = .white
    title.frame = NSRect(x: rtlX(72, w - 88, in: w), y: h / 2 - 1, width: w - 88, height: 20)
    title.lineBreakMode = .byTruncatingTail
    rtlText(title)
    blur.addSubview(title)
    let sub = NSTextField(labelWithString: L("3秒間 マウスとキーボードに触れないでください", "Keep your hands off for 3 seconds"))
    sub.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    sub.textColor = NSColor(white: 1, alpha: 0.62)
    sub.frame = NSRect(x: rtlX(72, w - 88, in: w), y: h / 2 - 19, width: w - 88, height: 16)
    sub.lineBreakMode = .byTruncatingTail
    rtlText(sub)
    blur.addSubview(sub)

    pillWindow = win
    pillRing = ring
    pillRingView = ringView
    pillIcon = icon
    pillTitle = title
    pillSub = sub

    win.alphaValue = 0
    win.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.22
        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
        win.animator().alphaValue = 1
        win.animator().setFrame(frame, display: true)
    }
}

func updatePill(_ progress: Double) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    pillRing?.strokeEnd = CGFloat(progress)
    CATransaction.commit()
}

func pillArmed() {
    guard pillWindow != nil else { return }
    updatePill(1)
    pillIcon?.image = symbol("checkmark.shield.fill", size: 16)
    pillTitle?.stringValue = L("見張り中", "Guarding")
    pillSub?.stringValue = L("AIはそのまま作業できます。人が触るとロックします", "AI keeps working. A human touch locks the Mac")
    // 満ちた瞬間に、リングから光の輪が広がる
    if let rv = pillRingView, let rl = rv.layer {
        let now = CACurrentMediaTime()
        for i in 0..<2 {
            let pulse = CAShapeLayer()
            pulse.frame = rv.bounds
            pulse.path = CGPath(ellipseIn: rv.bounds.insetBy(dx: 3, dy: 3), transform: nil)
            pulse.fillColor = nil
            pulse.strokeColor = i == 0 ? accentA : accentB
            pulse.lineWidth = 2
            pulse.opacity = 0
            rl.addSublayer(pulse)
            let b = now + Double(i) * 0.12
            pulse.add(anim("transform.scale", 1.0, 1.45, begin: b, dur: 0.55, fill: .forwards), forKey: "s")
            pulse.add(anim("opacity", 1.0, 0.0, begin: b, dur: 0.55, fill: .forwards), forKey: "o")
        }
    }
    let shown = pillWindow
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { if pillWindow === shown { hidePill() } }
}

func hidePill() {
    guard let win = pillWindow else { return }
    pillWindow = nil
    let up = win.frame.offsetBy(dx: 0, dy: 10)
    NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = 0.35
        win.animator().alphaValue = 0
        win.animator().setFrame(up, display: true)
    }, completionHandler: { win.orderOut(nil) })
}

// ===== 見張りの本体 =====
// マウスとキーボードの操作を受け取る。読むのは「どのプログラムが送った操作か」だけで、
// 押されたキーの内容やマウスの位置は読まない

let eventTypes: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                 .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
                                 .otherMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged]
let eventMask: CGEventMask = eventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }

// 人が触ったときの処理（準備中なら数え直し、見張り中ならロック）
func humanTouched() {
    switch watchState {
    case .arming: lastHuman = Date()
    case .armed: lockNow()
    case .idle, .locking: break
    }
}

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = tap, watchState == .arming || watchState == .armed { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    // 実物の機器からの操作は送り主プロセスが0。AIなどプログラムが送った操作は0以外
    if event.getIntegerValueField(.eventSourceUnixProcessID) == 0 { humanTouched() }
    return Unmanaged.passUnretained(event)
}

// キーボード本体（内蔵・外付けとも）からの入力を直接受け取る。
// 画面側のキー入力は、パスワード欄などでは他のアプリから隠されるため。
// ここに届くのは実物のキーボードの操作だけで、AIが送るキー入力は届かない。
// 確かめるのは「キーボードのキーかどうか」だけで、どのキーかは使わない・記録しない
let hidCallback: IOHIDValueCallback = { _, _, _, value in
    let element = IOHIDValueGetElement(value)
    let usage = IOHIDElementGetUsage(element)
    guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_KeyboardOrKeypad), usage >= 0x04, usage <= 0xE7 else { return }
    humanTouched()
}

// 見張りを始めるときだけ、入力の受け取りを始める
func startListening() -> Bool {
    stopListening()
    guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
                                    eventsOfInterest: eventMask, callback: tapCallback, userInfo: nil) else { return false }
    let s = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
    CGEvent.tapEnable(tap: t, enable: true)
    tap = t
    tapSource = s

    let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let matching: [[String: Any]] = [
        [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard],
        [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keypad],
    ]
    IOHIDManagerSetDeviceMatchingMultiple(m, matching as CFArray)
    IOHIDManagerRegisterInputValueCallback(m, hidCallback, nil)
    IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    _ = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
    hidManager = m
    return true
}

// 入力の受け取りを完全にやめる（待機中とロック後は、何も受け取らない）
func stopListening() {
    if let t = tap {
        CGEvent.tapEnable(tap: t, enable: false)
        if let s = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        CFMachPortInvalidate(t)
    }
    tap = nil
    tapSource = nil
    if let m = hidManager {
        IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        _ = IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
    }
    hidManager = nil
}

// ===== 見張り中のスクリーンセーバー・画面オフ対策 =====
// スクリーンセーバーの開始時間（秒）。0 は「しない」、読めないときは nil
func screensaverSeconds() -> Int? {
    let app = "com.apple.screensaver" as CFString
    CFPreferencesSynchronize(app, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    guard let v = CFPreferencesCopyValue("idleTime" as CFString, app,
                                         kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) else { return nil }
    return (v as? NSNumber)?.intValue
}

// 画面オフまでの時間（秒）。今の電源（電源アダプタ／バッテリー）の設定を読む。0 は「しない」
func displaySleepSeconds() -> Int? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["-g"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let out = String(data: data, encoding: .utf8) ?? ""
    for line in out.split(separator: "\n") {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if parts.count >= 2, parts[0] == "displaysleep", let m = Int(parts[1]) { return m * 60 }
    }
    return nil
}

// 合図の間隔：スクリーンセーバーと画面オフのうち短いほうの半分（30秒〜5分の範囲）
// スクリーンセーバーの設定が読めないときは、安全のため30秒にする
func keepAwakeInterval() -> TimeInterval {
    guard let saver = screensaverSeconds() else { return 30 }
    let limits = [saver, displaySleepSeconds() ?? 0].filter { $0 > 0 }
    guard let shortest = limits.min() else { return 300 }   // どちらも「しない」設定
    return min(300, max(30, TimeInterval(shortest) / 2))
}

// 見張り中は、合図を定期的に送ってスクリーンセーバー・画面オフ・スリープを防ぐ
// （マウスやキーの操作は発生しない）。間隔はMacの設定に合わせて毎回決め直す
func keepAwake(_ gen: Int) {
    guard gen == watchGeneration, watchState == .arming || watchState == .armed else { return }
    _ = IOPMAssertionDeclareUserActivity("Sawaruna watching" as CFString, kIOPMUserActiveLocal, &activityID)
    DispatchQueue.main.asyncAfter(deadline: .now() + keepAwakeInterval()) { keepAwake(gen) }
}

func holdPowerAssertions() {
    releasePowerAssertions()
    _ = IOPMAssertionCreateWithName("PreventUserIdleDisplaySleep" as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Sawaruna watching" as CFString, &assertionID)
    _ = IOPMAssertionCreateWithName("PreventUserIdleSystemSleep" as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Sawaruna watching" as CFString, &sleepAssertionID)
}

func releasePowerAssertions() {
    if assertionID != 0 { IOPMAssertionRelease(assertionID); assertionID = 0 }
    if sleepAssertionID != 0 { IOPMAssertionRelease(sleepAssertionID); sleepAssertionID = 0 }
}

// 画面上部のカプセルで注意を知らせる
func showWarningPill(_ title: String, _ sub: String) {
    pillWindow?.orderOut(nil)
    pillWindow = nil
    showPill()
    updatePill(1)
    pillIcon?.image = symbol("exclamationmark.triangle.fill", size: 16)
    pillTitle?.stringValue = title
    pillSub?.stringValue = sub
    let win = pillWindow
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
        if pillWindow === win { hidePill() }
    }
}

// 見張り中の自己点検（2秒ごと）。見張りが止まっていたら、安全な側に倒してロックする
func selfCheck() {
    guard watchState == .armed else { return }
    var healthy = CGPreflightListenEventAccess()
    if let t = tap {
        if !CGEvent.tapIsEnabled(tap: t) { CGEvent.tapEnable(tap: t, enable: true) }
        if !CGEvent.tapIsEnabled(tap: t) { healthy = false }
    } else {
        healthy = false
    }
    if !healthy {
        log("self-check failed")
        lockNow()
    }
}

// 見張りを始める（メニューから、またはアプリをもう一度開いたとき）
func startWatch() {
    switch watchState {
    case .arming, .armed: return
    case .locking: finishWatch()   // 前回のお知らせが出たままなら、片付けてから始める
    case .idle: break
    }
    // 初回の案内が終わっていなければ、案内を出す
    guard onboardingDone() else {
        openOnboarding(defaults.integer(forKey: "onboardingStep"))
        return
    }
    // 許可が外れていたら、許可の画面から案内し直す
    guard CGPreflightListenEventAccess() else {
        defaults.set(false, forKey: "onboardingDone")
        openOnboarding(1)
        return
    }
    guard startListening() else {
        showWarningPill(L("見張りを始められませんでした", "Could not start guarding"),
                        L("入力監視の許可を確認してください", "Check the Input Monitoring permission"))
        return
    }
    clearFlash()
    watchGeneration += 1
    let gen = watchGeneration
    watchState = .arming
    lastHuman = Date()
    holdPowerAssertions()
    keepAwake(gen)
    pillWindow?.orderOut(nil)
    pillWindow = nil
    showPill()
    // 人の操作が3秒途切れたら見張り開始（AIの操作は数えない）
    armTimer?.invalidate()
    armTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
        guard gen == watchGeneration, watchState == .arming else { return }
        let idle = Date().timeIntervalSince(lastHuman)
        updatePill(min(1, idle / 3))
        if idle >= 3 {
            watchState = .armed
            log("ARMED")
            armSound?.play()
            pillArmed()
            onStateChange()
            armTimer?.invalidate()
            armTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                if gen == watchGeneration { selfCheck() }
            }
        }
    }
    onStateChange()
    log("started")
}

func endWatchCommon() {
    watchGeneration += 1
    armTimer?.invalidate()
    armTimer = nil
    stopListening()
    releasePowerAssertions()
    watchState = .idle
    onStateChange()
}

// 見張りをやめる（準備中にメニューから、または自分でロックしたとき）
func cancelWatch() {
    guard watchState == .arming || watchState == .armed else { return }
    endWatchCommon()
    hidePill()
    log("canceled")
}

// ロックが解除されたあとの片付け。待機に戻る
func finishWatch() {
    endWatchCommon()
    clearFlash()
    if let w = noticeWindow { w.orderOut(nil) }
    noticeWindow = nil
    log("finished")
}

// ===== 初回の案内 =====

final class ActionButton: NSButton {
    var handler: (() -> Void)?
    @objc func fire() { handler?() }
}

func makeButton(_ title: String, primary: Bool = false, _ handler: @escaping () -> Void) -> ActionButton {
    let b = ActionButton(frame: .zero)
    b.title = title
    b.setButtonType(.momentaryPushIn)
    b.bezelStyle = .rounded
    b.controlSize = .large
    b.font = NSFont.systemFont(ofSize: 14, weight: primary ? .semibold : .regular)
    b.handler = handler
    b.target = b
    b.action = #selector(ActionButton.fire)
    if primary { b.keyEquivalent = "\r" }
    return b
}

func makeText(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, alpha: CGFloat = 1, width: CGFloat = 464) -> NSTextField {
    let t = NSTextField(wrappingLabelWithString: s)
    t.font = NSFont.systemFont(ofSize: size, weight: weight)
    t.textColor = NSColor(white: 1, alpha: alpha)
    t.isSelectable = false
    t.preferredMaxLayoutWidth = width
    t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    rtlText(t)
    return t
}

func makeIcon(_ name: String, size: CGFloat, color: NSColor) -> NSImageView {
    let v = NSImageView()
    v.image = symbol(name, size: size)
    v.contentTintColor = color
    v.imageScaling = .scaleNone
    v.translatesAutoresizingMaskIntoConstraints = false
    v.widthAnchor.constraint(equalToConstant: size * 1.5).isActive = true
    v.heightAnchor.constraint(equalToConstant: size * 1.5).isActive = true
    return v
}

// アイコンと文章を横に並べた1行
func makeRow(_ icon: String, _ text: String) -> NSStackView {
    let row = NSStackView(views: [makeIcon(icon, size: 17, color: NSColor(cgColor: accentA) ?? .white),
                                  makeText(text, size: 13.5, alpha: 0.86, width: 420)])
    row.orientation = .horizontal
    row.alignment = .top
    row.spacing = 10
    rtlLayout(row)
    return row
}

final class Onboarding: NSObject, NSWindowDelegate {
    var window: NSWindow?
    var step = 0
    var pollTimer: Timer?
    var lastGranted = false
    let lastStep = 3

    func show(at s: Int) {
        step = max(0, min(lastStep, s))
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 590),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Sawaruna"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        render()
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // 許可の状態が変わったら表示を更新する
        pollTimer?.invalidate()
        lastGranted = CGPreflightListenEventAccess()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self, self.step == 1 else { return }
            let g = CGPreflightListenEventAccess()
            if g != self.lastGranted {
                self.lastGranted = g
                self.render()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func go(_ s: Int) {
        step = max(0, min(lastStep, s))
        render()
    }

    func finish(thenStart: Bool) {
        defaults.set(true, forKey: "onboardingDone")
        defaults.removeObject(forKey: "onboardingStep")
        window?.close()
        if thenStart { startWatch() }
    }

    // 許可をオンにしても反映されないときのために、アプリを開き直す
    func reopenApp() {
        defaults.set(step, forKey: "onboardingStep")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", Bundle.main.bundlePath]
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
    }

    func render() {
        guard let window = window else { return }
        if !onboardingDone() { defaults.set(step, forKey: "onboardingStep") }

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 590))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(srgbRed: 0.06, green: 0.07, blue: 0.13, alpha: 1).cgColor
        rtlLayout(content)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        rtlLayout(stack)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 46),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 48),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -48),
        ])

        let nav = NSStackView()
        nav.orientation = .horizontal
        nav.spacing = 10
        nav.translatesAutoresizingMaskIntoConstraints = false
        rtlLayout(nav)
        content.addSubview(nav)
        NSLayoutConstraint.activate([
            nav.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            nav.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -26),
        ])

        let counter = makeText("\(step + 1) / \(lastStep + 1)", size: 12, weight: .medium, alpha: 0.45, width: 80)
        counter.translatesAutoresizingMaskIntoConstraints = false
        counter.baseWritingDirection = .leftToRight   // 「1 / 4」の数字の順番は、どの言語でも変えない
        content.addSubview(counter)
        NSLayoutConstraint.activate([
            counter.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 48),
            counter.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -34),
        ])

        let cyan = NSColor(cgColor: accentA) ?? .white
        func head(_ icon: String, _ title: String) {
            stack.addArrangedSubview(makeIcon(icon, size: 38, color: cyan))
            stack.addArrangedSubview(makeText(title, size: 23, weight: .bold))
            stack.setCustomSpacing(6, after: stack.arrangedSubviews[0])
        }
        func body(_ s: String) { stack.addArrangedSubview(makeText(s, size: 14, alpha: 0.82)) }
        func back() { nav.addArrangedSubview(makeButton(L("戻る", "Back")) { [unowned self] in self.go(self.step - 1) }) }
        func next(enabled: Bool = true) {
            let b = makeButton(L("次へ", "Next"), primary: true) { [unowned self] in self.go(self.step + 1) }
            b.isEnabled = enabled
            nav.addArrangedSubview(b)
        }

        switch step {
        case 0:
            head("checkmark.shield.fill", L("Sawaruna へようこそ", "Welcome to Sawaruna"))
            body(L("AIにMacを任せて席を離れるための見張り番です。だれかがマウスやキーボードに触ると、すぐに画面をロックします。",
                   "A guard for when you leave your Mac working with AI. If anyone touches the mouse or keyboard, the screen locks at once."))
            let h = makeText(L("3つの約束", "Three promises"), size: 13, weight: .semibold, alpha: 0.55)
            stack.addArrangedSubview(h)
            stack.setCustomSpacing(22, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
            stack.addArrangedSubview(makeRow("wifi.slash",
                L("インターネットに接続しません。写真も記録も、このMacの外に出ることはありません。",
                  "It never connects to the internet. Photos and records never leave this Mac.")))
            stack.addArrangedSubview(makeRow("keyboard",
                L("押したキーの内容は読みません。記録もしません。使うのは「触られた」という事実だけです。",
                  "It never reads or records which keys are pressed. It only uses the fact that something was touched.")))
            stack.addArrangedSubview(makeRow("eye.slash",
                L("マウスやキーボードを見るのは、あなたが見張りを始めたときだけです。それ以外の時間は何も見ません。",
                  "It only watches the mouse and keyboard while you are guarding. The rest of the time it watches nothing.")))
            next()

        case 1:
            let granted = CGPreflightListenEventAccess()
            head("hand.raised.fill", L("「触られたこと」を知るための許可", "Permission to notice a touch"))
            body(L("マウスやキーボードが触られた瞬間を知るために、Macの「入力監視」という許可が必要です。名前は大げさですが、Sawarunaが使うのは「触られたかどうか」だけです。",
                   "To notice the moment the mouse or keyboard is touched, macOS requires the Input Monitoring permission. Despite the name, Sawaruna only uses whether something was touched."))
            body(L("1. 下の「設定を開く」を押す\n2. 開いた画面で「Sawaruna」をオンにする\n3. 「終了して再度開く」と聞かれたら、それを選ぶ",
                   "1. Click “Open Settings” below\n2. Turn on “Sawaruna” in the list\n3. If asked to “Quit & Reopen”, choose it"))
            let open = makeButton(L("設定を開く", "Open Settings"), primary: !granted) {
                _ = CGRequestListenEventAccess()
                openSettings(listenSettingsURL)
            }
            stack.addArrangedSubview(open)
            let status = makeText(granted ? L("✓ 許可されています", "✓ Permission granted")
                                          : L("まだ許可されていません", "Not granted yet"),
                                  size: 14, weight: .semibold)
            status.textColor = granted ? NSColor.systemGreen : NSColor.systemOrange
            stack.addArrangedSubview(status)
            if !granted {
                let re = makeButton(L("オンにしたのに変わらないとき：Sawarunaを開き直す", "Turned it on but nothing changed? Reopen Sawaruna")) {
                    [unowned self] in self.reopenApp()
                }
                re.controlSize = .regular
                re.font = NSFont.systemFont(ofSize: 12)
                stack.addArrangedSubview(re)
            }
            back()
            next(enabled: granted)

        case 2:
            let on = photoEnabled()
            head("camera.fill", L("触った人の写真を残しますか？", "Keep a photo of who touched it?"))
            body(L("オンにすると、触られた瞬間にMacのカメラで写真を3枚撮ります。カメラが動くのはその数秒だけで、見張っている間は使いません。写真は、このMacの「ピクチャ」の中の「Sawaruna」フォルダにだけ保存されます。",
                   "When on, the Mac’s camera takes three photos at the moment of the touch. The camera runs only for those few seconds, never while guarding. Photos are saved only in Pictures > Sawaruna on this Mac."))
            body(L("人を無断で撮影することは、国や場所によっては問題になることがあります。使う場所に合わせて選んでください。あとからメニューでいつでも変えられます。",
                   "Photographing people without consent can be a problem depending on the country and place. Choose what suits where you use it. You can change this anytime from the menu."))
            let choices = NSStackView()
            choices.orientation = .horizontal
            choices.spacing = 10
            rtlLayout(choices)
            choices.addArrangedSubview(makeButton(L("写真を残す", "Keep photos")) { [unowned self] in
                switch AVCaptureDevice.authorizationStatus(for: .video) {
                case .authorized:
                    setPhotoEnabled(true)
                    self.render()
                case .notDetermined:
                    AVCaptureDevice.requestAccess(for: .video) { ok in
                        DispatchQueue.main.async {
                            setPhotoEnabled(ok)
                            self.render()
                        }
                    }
                default:
                    // 以前にカメラを「許可しない」にしている場合は、設定画面を開く
                    setPhotoEnabled(false)
                    openSettings(cameraSettingsURL)
                    self.render()
                }
            })
            choices.addArrangedSubview(makeButton(L("写真は残さない", "No photos")) { [unowned self] in
                setPhotoEnabled(false)
                self.render()
            })
            stack.addArrangedSubview(choices)
            let st = makeText(on ? L("いまの設定：写真を残す", "Current setting: keep photos")
                                 : L("いまの設定：写真は残さない", "Current setting: no photos"),
                              size: 14, weight: .semibold)
            st.textColor = on ? NSColor.systemGreen : NSColor(white: 1, alpha: 0.7)
            stack.addArrangedSubview(st)
            back()
            next()

        default:
            head("shield.fill", L("準備ができました", "You’re all set"))
            body(L("画面の右上（メニューバー）に、盾のアイコンがあります。席を離れるときは、アイコンを押して「見張りを始める」を選んでください。",
                   "There is a shield icon at the top right of the screen (the menu bar). When you step away, click it and choose “Start guarding”."))
            body(L("手を離して3秒たつと「チン」と鳴って、見張りが始まります。そのあとだれかが触ると、すぐにロックされます。解除はいつものパスワードやTouch IDです。",
                   "Three seconds after you let go, a chime sounds and guarding begins. After that, any touch locks the Mac. Unlock with your usual password or Touch ID."))
            body(L("Sawarunaのアイコンをもう一度開いても、同じように見張りが始まります。",
                   "Opening the Sawaruna app again also starts guarding."))
            back()
            nav.addArrangedSubview(makeButton(L("試してみる", "Try it now")) { [unowned self] in self.finish(thenStart: true) })
            nav.addArrangedSubview(makeButton(L("完了", "Done"), primary: true) { [unowned self] in self.finish(thenStart: false) })
        }

        window.contentView = content
    }
}

// ===== メニューバーのアイコン =====

final class StatusMenu: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        if isRTL { menu.userInterfaceLayoutDirection = .rightToLeft }
        item.menu = menu
        refresh()
    }

    // 状態に合わせてアイコンを変える
    func refresh() {
        let name: String
        switch watchState {
        case .idle: name = "shield"
        case .arming: name = "shield.lefthalf.filled"
        case .armed, .locking: name = "shield.fill"
        }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Sawaruna")
            ?? NSImage(systemSymbolName: "shield", accessibilityDescription: "Sawaruna")
        img?.isTemplate = true
        item.button?.image = img
        item.button?.title = img == nil ? "SW" : ""
    }

    func add(_ title: String, _ action: Selector?, enabled: Bool = true, checked: Bool = false) {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        mi.isEnabled = enabled && action != nil
        mi.state = checked ? .on : .off
        menu.addItem(mi)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status: String
        switch watchState {
        case .idle: status = L("待機中（何も見ていません）", "Idle (watching nothing)")
        case .arming: status = L("準備中：手を離すと見張りが始まります", "Getting ready: let go to start")
        case .armed: status = L("見張り中", "Guarding")
        case .locking: status = L("ロックしました", "Locked")
        }
        add(status, nil)
        menu.addItem(NSMenuItem.separator())
        if watchState == .arming || watchState == .armed {
            add(L("見張りをやめる", "Stop guarding"), #selector(toggleWatch))
        } else {
            add(L("見張りを始める", "Start guarding"), #selector(toggleWatch))
        }
        menu.addItem(NSMenuItem.separator())
        add(L("ショートカット ⌃⌥L を使う", "Use the ⌃⌥L shortcut"), #selector(toggleHotkey), checked: hotkeyEnabled())
        if hotkeyEnabled() && !hotKeyAvailable {
            add(L("⌃⌥L はほかのアプリが使っています", "⌃⌥L is already used by another app"), nil)
        }
        add(L("触った人の写真を残す", "Keep a photo of who touched it"), #selector(togglePhoto), checked: photoEnabled())
        add(L("記録を見る", "Show records"), #selector(openRecords))
        add(L("ロックの演出を見る", "Preview the lock animation"), #selector(preview), enabled: watchState == .idle)
        menu.addItem(NSMenuItem.separator())
        add(L("使い方と安全性", "How it works & safety"), #selector(guide), enabled: watchState == .idle)
        let v = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        add("Sawaruna \(v)", nil)
        menu.addItem(NSMenuItem.separator())
        add(L("Sawarunaを終了", "Quit Sawaruna"), #selector(quit))
    }

    @objc func toggleWatch() {
        if watchState == .arming || watchState == .armed { cancelWatch() } else { startWatch() }
    }

    @objc func toggleHotkey() { setHotkeyEnabled(!hotkeyEnabled()) }

    @objc func togglePhoto() {
        if photoEnabled() {
            setPhotoEnabled(false)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setPhotoEnabled(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { setPhotoEnabled(ok) }
            }
        default:
            openSettings(cameraSettingsURL)
        }
    }

    @objc func openRecords() {
        try? FileManager.default.createDirectory(at: photoRoot, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(photoRoot)
    }

    @objc func preview() { previewFlash() }
    @objc func guide() { openOnboarding(0) }
    @objc func quit() { NSApp.terminate(nil) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // 動いている間にもう一度アプリを開くと（ダブルクリックやショートカット）、見張りを始める
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if onboardingVisible() { openOnboarding(nil) } else { startWatch() }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        stopListening()
        releasePowerAssertions()
    }
}

// ===== ここから起動時の処理 =====

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let appDelegate = AppDelegate()
app.delegate = appDelegate
let onboarding = Onboarding()
let statusMenu = StatusMenu()
onStateChange = { statusMenu.refresh() }
openOnboarding = { s in onboarding.show(at: s ?? onboarding.step) }
onboardingVisible = { onboarding.window?.isVisible == true }
// ⌃⌥L：待機中なら見張りを始める（見張り中に押した場合は「人が触った」として扱われる）
onHotKey = {
    guard watchState == .idle else { return }
    if onboardingVisible() { openOnboarding(nil) } else { startWatch() }
}
registerHotKey()

// 画面がロックされたとき
DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"),
                                                    object: nil, queue: .main) { _ in
    switch watchState {
    case .locking: lockConfirmed = true     // Sawarunaがロックした
    case .arming, .armed: cancelWatch()     // 利用者が自分でロックした
    case .idle: break
    }
}
// ロックが解除されたとき：触られてロックしていた場合は知らせる
DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"),
                                                    object: nil, queue: .main) { _ in
    guard watchState == .locking else { return }
    clearFlash()
    let gen = watchGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + (captureDone ? 0.6 : 3.0)) {
        guard gen == watchGeneration, watchState == .locking else { return }
        showIntruderNotice()
    }
}

// 起動したとき：初回は案内を出す。2回目からは「開く＝見張りを始める」
DispatchQueue.main.async {
    if onboardingDone() {
        startWatch()
    } else {
        openOnboarding(defaults.integer(forKey: "onboardingStep"))
    }
}
log("launched")
app.run()
