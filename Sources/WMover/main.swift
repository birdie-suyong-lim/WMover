import Cocoa
import ApplicationServices
import IOKit.pwr_mgt
import ServiceManagement

// MARK: - 설정 (단축키 조합은 여기서 바꾼다)
//   위치조절(move)   : Control + Shift   + 좌클릭 드래그
//   크기조절(resize) : Control + Command + 좌클릭 드래그
enum Config {
    static let moveFlags: CGEventFlags   = [.maskControl, .maskShift]
    static let resizeFlags: CGEventFlags = [.maskControl, .maskCommand]
    static let minWidth: CGFloat  = 120
    static let minHeight: CGFloat = 80
}

// 비교에 쓰는 modifier 마스크 (Caps/숫자패드 등 잡음 플래그 제거용)
private let relevantMask: CGEventFlags = [.maskControl, .maskCommand, .maskAlternate, .maskShift]

// MARK: - 진단 로그 (/tmp/wmover.log)
func wlog(_ msg: String) {
    let line = msg + "\n"
    let path = "/tmp/wmover.log"
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else {
        try? line.write(toFile: path, atomically: false, encoding: .utf8)
    }
}

// MARK: - 핵심: 마우스 아래 윈도우를 찾아 이동/리사이즈
final class WindowMover {
    enum Mode { case none, move, resize }

    private var mode: Mode = .none
    private var targetWindow: AXUIElement?
    private var initialMouse = CGPoint.zero
    private var initialWinPos = CGPoint.zero
    private var initialWinSize = CGSize.zero
    private var pendingSize: CGSize?          // 리사이즈 종료 시 1회 적용할 최종 크기
    private var eventTap: CFMachPort?
    private lazy var overlay = OverlayWindow() // 리사이즈 미리보기 외곽선

    /// 현재 modifier 조합으로 어떤 동작인지 판정
    private func mode(for flags: CGEventFlags) -> Mode {
        let f = flags.intersection(relevantMask)
        if f == Config.moveFlags { return .move }
        if f == Config.resizeFlags { return .resize }
        return .none
    }

    // MARK: 이벤트 탭 시작
    @discardableResult
    func start() -> Bool {
        // 클릭 없이: 단축키 눌림(flagsChanged) + 마우스 이동(mouseMoved)만 본다.
        // 버튼을 누른 채 움직이는 경우도 대비해 dragged도 포함.
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let me = Unmanaged<WindowMover>.fromOpaque(refcon!).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            wlog("start: tapCreate FAILED (trusted=\(AXIsProcessTrusted()))")
            return false
        }
        wlog("start: tap created OK (trusted=\(AXIsProcessTrusted()))")

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    // MARK: 이벤트 처리
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            // 단축키 조합이 바뀌는 순간마다 판정
            let desired = mode(for: event.flags)
            if desired != mode {
                endDrag() // 기존 추적이 있으면 종료
                if desired != .none {
                    let ok = beginDrag(at: event.location, mode: desired) // 커서 아래 윈도우가 없으면 비활성 유지
                    wlog("flagsChanged: desired=\(desired) at \(event.location) windowFound=\(ok)")
                }
            }
            return Unmanaged.passUnretained(event)

        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            // 활성 상태면 커서를 따라 이동/리사이즈 (이벤트는 그대로 통과 → 커서는 정상 이동)
            if mode != .none { update(to: event.location) }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    @discardableResult
    private func beginDrag(at point: CGPoint, mode: Mode) -> Bool {
        guard let win = windowUnderPoint(point),
              let pos = axValue(win, kAXPositionAttribute, .cgPoint) as CGPoint?,
              let size = axValue(win, kAXSizeAttribute, .cgSize) as CGSize? else {
            return false
        }
        targetWindow = win
        initialMouse = point
        initialWinPos = pos
        initialWinSize = size
        self.mode = mode
        AXUIElementPerformAction(win, kAXRaiseAction as CFString) // 대상 윈도우를 앞으로
        if mode == .resize {
            // 리사이즈는 라이브로 안 바꾸고 외곽선 미리보기부터 띄운다
            pendingSize = size
            overlay.show(frame: Self.cocoaRect(topLeft: pos, size: size))
        }
        return true
    }

    private func update(to point: CGPoint) {
        guard let win = targetWindow else { return }
        let dx = point.x - initialMouse.x
        let dy = point.y - initialMouse.y
        switch mode {
        case .move:
            var p = CGPoint(x: initialWinPos.x + dx, y: initialWinPos.y + dy)
            if let v = AXValueCreate(.cgPoint, &p) {
                AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, v)
            }
        case .resize:
            // 대상 앱은 안 건드리고 외곽선 오버레이만 갱신 (리플로우 없음 → 부드러움)
            let s = CGSize(width:  max(Config.minWidth,  initialWinSize.width  + dx),
                           height: max(Config.minHeight, initialWinSize.height + dy))
            pendingSize = s
            overlay.show(frame: Self.cocoaRect(topLeft: initialWinPos, size: s))
            _ = win
        case .none:
            break
        }
    }

    private func endDrag() {
        // 리사이즈였다면 마지막 크기를 딱 한 번 적용
        if mode == .resize, let win = targetWindow, var s = pendingSize {
            if let v = AXValueCreate(.cgSize, &s) {
                AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, v)
            }
        }
        overlay.hide()
        mode = .none
        targetWindow = nil
        pendingSize = nil
    }

    /// Quartz(좌상단 원점) 프레임 → Cocoa(좌하단 원점) 프레임 변환
    static func cocoaRect(topLeft: CGPoint, size: CGSize) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: topLeft.x,
                      y: primaryHeight - topLeft.y - size.height,
                      width: size.width, height: size.height)
    }

    // MARK: AX 헬퍼
    /// 좌표(Quartz: 좌상단 원점) 아래의 윈도우 AXUIElement를 찾는다.
    private func windowUnderPoint(_ p: CGPoint) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &element) == .success,
              var current = element else { return nil }

        // 윈도우 역할을 만날 때까지 부모로 거슬러 올라간다
        for _ in 0..<25 {
            if let role: String = axValue(current, kAXRoleAttribute), role == (kAXWindowRole as String) {
                return current
            }
            // 일부 요소는 직접 소속 윈도우를 가리킨다
            if let win = axElement(current, kAXWindowAttribute) {
                return win
            }
            guard let parent = axElement(current, kAXParentAttribute) else { return nil }
            current = parent
        }
        return nil
    }

    // CGPoint/CGSize 추출
    private func axValue(_ el: AXUIElement, _ attr: String, _ type: AXValueType) -> CGPoint? {
        guard let v = copyAX(el, attr) else { return nil }
        var out = CGPoint.zero
        return AXValueGetValue(v as! AXValue, type, &out) ? out : nil
    }
    private func axValue(_ el: AXUIElement, _ attr: String, _ type: AXValueType) -> CGSize? {
        guard let v = copyAX(el, attr) else { return nil }
        var out = CGSize.zero
        return AXValueGetValue(v as! AXValue, type, &out) ? out : nil
    }
    // String 속성
    private func axValue(_ el: AXUIElement, _ attr: String) -> String? {
        copyAX(el, attr) as? String
    }
    // AXUIElement 속성
    private func axElement(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = copyAX(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    private func copyAX(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success ? ref : nil
    }
}

// MARK: - 리사이즈 미리보기 오버레이
//   드래그 중엔 대상 앱을 건드리지 않고, 목표 크기를 나타내는 반투명 외곽선만 그린다.
//   (대상 앱의 매 픽셀 리플로우를 피해 버벅임 제거)
final class OverlayWindow {
    private let window: NSWindow

    init() {
        window = NSWindow(contentRect: .zero, styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver // 일반 윈도우보다 위
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = OutlineView()
    }

    func show(frame: NSRect) {
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }
}

final class OutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        bounds.fill()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 3
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}

// MARK: - 잠자기 방지 (카페인 기능)
//   앱이 켜져 있는 동안 맥이 idle 슬립에 빠지지 않게 한다.
//   디스플레이 슬립을 막으면 시스템 idle 슬립도 함께 막혀 원조 Caffeine과 동작이 같다.
final class SleepGuard {
    private var assertionID: IOPMAssertionID = 0
    private(set) var isActive = false

    @discardableResult func enable() -> Bool {
        guard !isActive else { return true }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "WMover 잠자기 방지" as CFString,
            &assertionID)
        isActive = (result == kIOReturnSuccess)
        return isActive
    }

    func disable() {
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isActive = false
    }

    @discardableResult func toggle() -> Bool {
        if isActive { disable() } else { enable() }
        return isActive
    }
}

// MARK: - 로그인 항목 (맥 시작 시 자동 실행)
//   macOS 13+ SMAppService.mainApp 사용 — 별도 헬퍼 앱 없이 앱 자신을 등록한다.
//   등록 정보는 시스템 설정 > 일반 > 로그인 항목에 노출되며, 거기서 끌 수도 있다.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 등록/해제. 성공 여부를 반환한다.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            wlog("LoginItem.setEnabled(\(enabled)) FAILED: \(error)")
            return false
        }
    }
}

// MARK: - 메뉴바 앱
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let mover = WindowMover()
    private let sleepGuard = SleepGuard()
    private var sleepItem: NSMenuItem!
    private var loginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        requestAccessibilityThenStart()
        // 실행 시 잠자기 방지 자동 켜짐
        sleepGuard.enable()
        sleepItem.state = sleepGuard.isActive ? .on : .off
        // 로그인 항목 현재 등록 상태 반영
        loginItem.state = LoginItem.isEnabled ? .on : .off
    }

    func applicationWillTerminate(_ notification: Notification) {
        sleepGuard.disable()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "macwindow.on.rectangle",
                                   accessibilityDescription: "WMover")
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "WMover", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "이동:  ⌃⇧ + 드래그", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(withTitle: "크기:  ⌃⌘ + 드래그", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        sleepItem = NSMenuItem(title: "잠자기 방지", action: #selector(toggleSleep), keyEquivalent: "")
        sleepItem.target = self
        menu.addItem(sleepItem)
        loginItem = NSMenuItem(title: "맥 시작 시 실행", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "접근성 설정 열기…",
                     action: #selector(openAccessibility), keyEquivalent: "")
        menu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func requestAccessibilityThenStart() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)

        if trusted, mover.start() {
            return
        }

        // 권한이 아직 없거나 탭 생성 실패 → 부여될 때까지 잠깐씩 재시도
        var attempts = 0
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            attempts += 1
            if AXIsProcessTrusted(), self.mover.start() {
                timer.invalidate()
            } else if attempts > 120 {
                timer.invalidate()
            }
        }
    }

    @objc private func toggleSleep() {
        sleepItem.state = sleepGuard.toggle() ? .on : .off
    }

    @objc private func toggleLoginItem() {
        let target = !LoginItem.isEnabled
        if LoginItem.setEnabled(target) {
            loginItem.state = target ? .on : .off
        } else {
            // 등록 실패(예: 미서명 빌드) 시 시스템 설정으로 안내
            loginItem.state = LoginItem.isEnabled ? .on : .off
            let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openAccessibility() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 진입점
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // Dock 미표시 · 메뉴바 상주
app.run()
