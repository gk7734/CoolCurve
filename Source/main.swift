import AppKit
import SwiftUI
import Foundation
import Darwin

let cpuKeys = ["Tp00","Tp04","Tp08","Tp0C","Tp0G","Tp0K","Tp0O","Tp0R","Tp0U","Tp0X","Tp0a","Tp0d","Tp0g","Tp0j","Tp0m","Tp0p","Tp0u","Tp0y"]
let gpuKeys = ["Tg0U","Tg0X","Tg0d","Tg0g","Tg0j","Tg1Y","Tg1c"]
func modelID() -> String {
    var n = 0; sysctlbyname("hw.model",nil,&n,nil,0)
    var b = [CChar](repeating:0,count:n)
    sysctlbyname("hw.model",&b,&n,nil,0)
    return String(cString:b)
}
struct Sample {
    let cpu: Double, gpu: Double, rpm: Double, minimum: Double, maximum: Double, mode: Int, target: Double
    var hottest: Double { max(cpu,gpu) }
}
func sample(_ smc: SMC) -> Sample? {
    let cpu = cpuKeys.compactMap { smc.getValue($0) }
    let gpu = gpuKeys.compactMap { smc.getValue($0) }
    guard cpu.count == cpuKeys.count, gpu.count == gpuKeys.count,
          (cpu+gpu).allSatisfy({ $0.isFinite && (5...115).contains($0) }),
          smc.getValue("FNum") == 1,
          let rpm = smc.getValue("F0Ac"), rpm.isFinite, rpm >= 0,
          let lo = smc.getValue("F0Mn"), let hi = smc.getValue("F0Mx"),
          lo.isFinite, hi.isFinite, lo >= 500, hi > lo, hi <= 10000,
          let mode = smc.getValue(smc.fanModeKey(0)), mode.isFinite,
          let target = smc.getValue("F0Tg"), target.isFinite else { return nil }
    return Sample(cpu:cpu.max()!,gpu:gpu.max()!,rpm:rpm,minimum:lo,maximum:hi,mode:Int(mode),target:target)
}
func identity(_ pid: Int32) -> UInt64? {
    var info = proc_bsdinfo()
    guard proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return nil }
    return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
}
func restore(_ smc: SMC) -> Bool {
    for _ in 0..<3 {
        smc.setFanMode(0,mode:.automatic)
        _ = smc.resetFanControl()
        if let v = smc.getValue(smc.fanModeKey(0)), v == 0 || v == 3 { return true }
        usleep(100_000)
    }
    return false
}
func diagnostic(_ message: String) {
    FileHandle.standardError.write(Data((message+"\n").utf8))
}
var stopping = false
func signals() {
    signal(SIGTERM) { _ in stopping = true }
    signal(SIGINT) { _ in stopping = true }
    signal(SIGPIPE,SIG_IGN)
}
// Unprivileged lease: EOF or a stalled GUI heartbeat revokes control.
func lease() -> Never {
    var last = ProcessInfo.processInfo.systemUptime
    var fd = pollfd(fd:STDIN_FILENO,events:Int16(POLLIN),revents:0)
    while ProcessInfo.processInfo.systemUptime-last < 7 {
        let result = poll(&fd,1,1000)
        if result > 0 {
            var bytes = [UInt8](repeating:0,count:128)
            if read(STDIN_FILENO,&bytes,bytes.count) <= 0 { exit(0) }
            last = ProcessInfo.processInfo.systemUptime
        }
    }
    exit(0)
}
func controller(_ parent: Int32, _ born: UInt64) -> Never {
    guard geteuid() == 0, modelID() == "Mac17,16" else { exit(2) }
    signals()
    let smc = SMC()
    guard let initial = sample(smc), initial.mode == 0 || initial.mode == 3 else { exit(3) }
    var policy = CoolingPolicy(), previous: Int?, badRPM = 0, count = 0
    let start = ProcessInfo.processInfo.systemUptime
    while !stopping && identity(parent) == born {
        guard let s = sample(smc) else { diagnostic("Sensor validation failed"); break }
        if ProcessInfo.processInfo.thermalState == .critical { diagnostic("macOS reported critical thermal pressure"); break }
        // Stop fighting another controller, or return control if commands stop applying.
        if previous != nil && s.mode != 1 { diagnostic("Manual mode ended externally: mode=\(s.mode)"); break }
        guard let rpm = policy.update(temperature:s.hottest,now:ProcessInfo.processInfo.systemUptime,
                                      minimum:s.minimum,maximum:s.maximum) else { diagnostic("Invalid or stale policy input"); break }
        if ProcessInfo.processInfo.systemUptime-start > 30 && s.rpm < Double(previous ?? rpm)*0.70 { badRPM += 1 } else { badRPM = 0 }
        if badRPM >= 3 { diagnostic("Fan not following target: actual=\(s.rpm), expected=\(previous ?? rpm)"); break }
        smc.setFanSpeed(0,speed:rpm)
        guard smc.getValue(smc.fanModeKey(0)) == 1 else { diagnostic("Manual mode failed: mode=\(smc.getValue(smc.fanModeKey(0)) ?? -1)"); break }
        if count < 20 { diagnostic("sample cpu=\(s.cpu) gpu=\(s.gpu) actual=\(s.rpm) target=\(s.target) requested=\(rpm)") }
        previous = rpm; count += 1
        // Health pipe is separate from SMC diagnostic output.
        var beat: UInt8 = 1; _ = write(STDOUT_FILENO,&beat,1)
        usleep(2_000_000)
    }
    let ok = restore(smc)
    exit(ok ? (stopping || identity(parent) != born ? 0 : 4) : 5)
}
// Independent supervisor restores automatic mode if the controller crashes/hangs.
func helper(_ parent: Int32, _ born: UInt64) -> Never {
    guard geteuid() == 0, modelID() == "Mac17,16", identity(parent) == born else { exit(2) }
    let lock = open("/var/run/local.coolcurve.lock",O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
    guard lock >= 0, flock(lock,LOCK_EX|LOCK_NB) == 0 else { exit(6) }
    signals()
    let smc = SMC()
    guard let s = sample(smc), s.mode == 0 || s.mode == 3 else { exit(3) }
    let child = Process(), pipe = Pipe()
    child.executableURL = URL(fileURLWithPath:CommandLine.arguments[0])
    child.arguments = ["--control",String(parent),String(born)]
    child.standardOutput = pipe
    child.standardError = pipe
    do { try child.run() } catch { exit(7) }
    let fd = pipe.fileHandleForReading.fileDescriptor
    _ = fcntl(fd,F_SETFL,O_NONBLOCK)
    var last = ProcessInfo.processInfo.systemUptime
    var diagnostics = Data()
    while child.isRunning && !stopping && identity(parent) == born {
        var buffer = [UInt8](repeating:0,count:4096)
        let n = read(fd,&buffer,buffer.count)
        if n > 0 {
            last = ProcessInfo.processInfo.systemUptime
            let logs = buffer.prefix(n).filter { $0 != 1 }
            if !logs.isEmpty { diagnostics.append(contentsOf:logs); if diagnostics.count > 12000 { diagnostics = Data(diagnostics.suffix(12000)) } }
        }
        if ProcessInfo.processInfo.systemUptime-last > 10 { diagnostic("Controller heartbeat timed out"); break }
        usleep(250_000)
    }
    if child.isRunning { kill(child.processIdentifier,SIGTERM); usleep(500_000) }
    if child.isRunning { kill(child.processIdentifier,SIGKILL) }
    child.waitUntilExit()
    let tail = pipe.fileHandleForReading.readDataToEndOfFile().filter { $0 != 1 }
    if !tail.isEmpty { diagnostics.append(contentsOf:tail) }
    let ok = restore(smc)
    if child.terminationStatus != 0 || !ok {
        diagnostic("Controller exit code: \(child.terminationStatus)")
        FileHandle.standardError.write(diagnostics)
        diagnostic(ok ? "Automatic fan control restored." : "ERROR: automatic restore could not be verified.")
    } else { print("Automatic fan control restored.") }
    exit(ok ? child.terminationStatus : 5)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var item: NSStatusItem!, menu = NSMenu(), status = NSMenuItem(), reading = NSMenuItem(), detail = NSMenuItem()
    var startItem: NSMenuItem!, stopItem: NSMenuItem!
    var smc: SMC!, timer: Timer?, leaseProcess: Process?, heartbeat: Pipe?, authorizer: Process?
    var quitting = false, requested = false, lastSample: Sample?
    let dashboard = DashboardModel()
    var window: NSWindow!, sensorTimer: Timer?
    let popover = NSPopover()
    var outsideClickMonitor: Any?, localClickMonitor: Any?
    func removePopoverMonitors() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil; localClickMonitor = nil
    }
    func popoverDidClose(_ notification: Notification) { removePopoverMonitors() }
    func installPopoverMonitors() {
        removePopoverMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.otherMouseDown]) { [weak self] _ in
            self?.popover.performClose(nil)
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.otherMouseDown,.keyDown]) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.popover.performClose(nil); return nil }
                return event
            }
            if event.window !== self.popover.contentViewController?.view.window && event.window !== self.item.button?.window {
                self.popover.performClose(nil)
            }
            return event
        }
    }
    @objc func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = item.button else { return }
        refresh()
        popover.show(relativeTo:button.bounds,of:button,preferredEdge:.minY)
        popover.contentViewController?.view.window?.makeKey()
        installPopoverMonitors()
    }
    let sensorQueue = DispatchQueue(label:"local.coolcurve.sensors")
    var readingSensors = false
    @objc func showDashboard() {
        popover.performClose(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard(); return true
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        smc = SMC()
        item = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        item.button?.title = "❋ CoolCurve"
        menu.addItem(withTitle:"CoolCurve · 온도에 맞춰 냉각",action:nil,keyEquivalent:"")
        menu.addItem(withTitle:"대시보드 열기",action:#selector(showDashboard),keyEquivalent:"")
        menu.addItem(.separator())
        menu.addItem(status); menu.addItem(reading); menu.addItem(detail); menu.addItem(.separator())
        startItem = menu.addItem(withTitle:"온도 자동 조절 시작…",action:#selector(start),keyEquivalent:"")
        stopItem = menu.addItem(withTitle:"애플 자동 제어로 복귀",action:#selector(stop),keyEquivalent:"")
        menu.addItem(.separator())
        menu.addItem(withTitle:"설정과 사용 안내",action:#selector(guide),keyEquivalent:"")
        menu.addItem(withTitle:"자동 복귀 후 종료",action:#selector(quit),keyEquivalent:"q")
        for i in menu.items { i.target = self }
        menu.autoenablesItems = false
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.toolTip = "CoolCurve · 온도와 팬 속도 보기"
        popover.delegate = self
        popover.behavior = .transient
        popover.contentSize = NSSize(width:330,height:440)
        popover.contentViewController = NSHostingController(rootView:MenuPanelView(model:dashboard,
            openDashboard:{ [weak self] in self?.showDashboard() },
            openGuide:{ [weak self] in self?.popover.performClose(nil); self?.guide() }))
        let mainMenu = NSMenu(), appMenu = NSMenu()
        let root = NSMenuItem(); root.title = "CoolCurve"; root.submenu = appMenu; mainMenu.addItem(root)
        let popupCommand = appMenu.addItem(withTitle:"메뉴 막대 팝업 열기",action:#selector(togglePopover),keyEquivalent:"m")
        popupCommand.keyEquivalentModifierMask = [.command,.shift]
        appMenu.addItem(withTitle:"대시보드 열기",action:#selector(showDashboard),keyEquivalent:"1")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"자동 복귀 후 종료",action:#selector(quit),keyEquivalent:"q")
        for entry in appMenu.items { entry.target = self }
        NSApp.mainMenu = mainMenu
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(sleeping),name:NSWorkspace.willSleepNotification,object:nil)
        dashboard.start = { [weak self] in self?.start() }
        dashboard.stop = { [weak self] in self?.stop() }
        dashboard.quit = { [weak self] in self?.quit() }
        dashboard.openFolder = { NSWorkspace.shared.open(Bundle.main.bundleURL.deletingLastPathComponent()) }
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:860,height:780),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "CoolCurve"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:DashboardView(model:dashboard))
        window.center()
        dashboard.record("앱 실행", "팬 모드를 변경하지 않고 센서 상태를 확인합니다.")
        timer = Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in
            if let h = self?.heartbeat { try? h.fileHandleForWriting.write(contentsOf:Data([1])) }
        }
        sensorTimer = Timer.scheduledTimer(withTimeInterval:5,repeats:true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer!,forMode:.common)
        RunLoop.main.add(sensorTimer!,forMode:.common)
        refresh(); showDashboard()
    }
    func refresh() {
        guard !readingSensors else { return }
        readingSensors = true
        sensorQueue.async { [weak self] in
            guard let self else { return }
            let result = sample(self.smc)
            DispatchQueue.main.async {
                self.readingSensors = false
                self.update(result)
            }
        }
    }
    func update(_ value: Sample?) {
        lastSample = value
        guard let s = value else {
            item.button?.title = "❋ 센서 오류"
            if requested { stop() }
            dashboard.state = "error"; dashboard.fresh = false
            dashboard.canStart = false; dashboard.canStop = requested
            startItem.isEnabled = false; stopItem.isEnabled = requested
            return
        }
        dashboard.cpu = s.cpu; dashboard.gpu = s.gpu; dashboard.rpm = s.rpm; dashboard.target = s.target
        dashboard.fresh = true; dashboard.updated = Date()
        dashboard.history.append(HistoryPoint(time:Date(),cpu:s.cpu,gpu:s.gpu,rpm:s.rpm))
        dashboard.history.removeAll { $0.time < Date().addingTimeInterval(-300) }
        let next = requested ? (s.mode == 1 ? "active" : "pending") : (authorizer != nil ? "restoring" : (s.mode == 0 || s.mode == 3 ? "auto" : "external"))
        if dashboard.state != next {
            dashboard.state = next
            dashboard.record(dashboard.statusTitle)
        }
        item.button?.title = String(format:"❋ %.0f° · %.0f RPM",s.hottest,s.rpm)
        reading.title = String(format:"CPU 최고 %.1f°C · GPU 최고 %.1f°C",s.cpu,s.gpu)
        detail.title = String(format:"현재 %.0f RPM · 목표 %.0f RPM",s.rpm,s.target)
        status.title = requested ? (s.mode == 1 ? "온도 자동 조절 중" : "관리자 승인 / 제어 시작 대기") : (s.mode == 0 || s.mode == 3 ? "애플 자동 제어" : "다른 앱의 수동 제어 감지")
        startItem.isEnabled = !requested && authorizer == nil && (s.mode == 0 || s.mode == 3)
        stopItem.isEnabled = requested
        dashboard.canStart = startItem.isEnabled; dashboard.canStop = requested
        status.title = dashboard.statusTitle
    }
    @objc func start() {
        popover.performClose(nil)
        guard !requested, authorizer == nil, dashboard.fresh, let updated = dashboard.updated, Date().timeIntervalSince(updated) < 10, modelID() == "Mac17,16", let s = lastSample, s.mode == 0 || s.mode == 3 else {
            alert("시작할 수 없음","이 빌드는 Mac17,16 전용입니다. Stats와 Macs Fan Control을 자동 모드로 두고 다시 시도하세요."); return
        }
        let p = Process(), h = Pipe()
        p.executableURL = Bundle.main.executableURL; p.arguments = ["--lease"]; p.standardInput = h
        do { try p.run() } catch { alert("시작 실패",error.localizedDescription); return }
        guard let born = identity(p.processIdentifier) else { p.terminate(); return }
        leaseProcess = p; heartbeat = h; requested = true
        dashboard.state = "pending"; dashboard.canStart = false; dashboard.canStop = true
        dashboard.record("사용자 커브 시작 요청")
        let shellQuote: (String)->String = { "'" + $0.replacingOccurrences(of:"'",with:"'\\''") + "'" }
        let command = shellQuote(Bundle.main.executablePath!) + " --helper \(p.processIdentifier) \(born)"
        let escaped = command.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")
        let auth = Process(), output = Pipe()
        auth.executableURL = URL(fileURLWithPath:"/usr/bin/osascript")
        auth.arguments = ["-e","do shell script \"\(escaped)\" with administrator privileges"]
        auth.standardOutput = output; auth.standardError = output
        authorizer = auth
        auth.terminationHandler = { [weak self] process in
            let message = String(data:output.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                let unexpected = self.requested
                let logURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Last-run.txt")
                try? message.write(to:logURL,atomically:true,encoding:.utf8)
                self.stop(); self.authorizer = nil; self.refresh()
                self.dashboard.record(process.terminationStatus == 0 ? "제어 종료" : "제어 종료 · 확인 필요", message)
                if self.quitting { NSApp.terminate(nil) }
                else if unexpected && process.terminationStatus != 0 { self.alert("온도 조절이 종료됐습니다", "승인 취소, 센서 오류 또는 제어 충돌이 발생했을 수 있습니다. 현재 팬 모드를 확인하세요.\n\n"+message) }
            }
        }
        do { try auth.run() } catch { stop(); authorizer = nil; alert("시작 실패",error.localizedDescription) }
        refresh()
    }
    @objc func stop() {
        if requested { dashboard.record("애플 자동 복귀 요청") }
        requested = false
        dashboard.canStart = false; dashboard.canStop = false
        if authorizer != nil { dashboard.state = "restoring" }
        try? heartbeat?.fileHandleForWriting.close(); heartbeat = nil
        if leaseProcess?.isRunning == true { leaseProcess?.terminate() }
        leaseProcess = nil
        status.title = authorizer == nil ? "애플 자동 제어" : "애플 자동 제어로 복귀 중…"
    }
    @objc func sleeping() { stop() }
    @objc func quit() {
        quitting = true; stop()
        if authorizer == nil { NSApp.terminate(nil) }
    }
    func applicationWillTerminate(_ notification: Notification) { removePopoverMonitors(); stop() }
    @objc func guide() {
        let curve = CoolingPolicy.points.map { "\(Int($0.0))°C → \(Int($0.1)) RPM" }.joined(separator:"\n")
        alert("CoolCurve · FL 균형 커브", "CPU·GPU 최고 온도를 기준으로 조절합니다.\n\n"+curve+"\n\n일반 온도 상승은 4초 시간상수로 완화하고, 2초마다 최대 300 RPM씩 올립니다. 하강은 8초 시간상수·2°C 차이·20초 대기 후 최대 100 RPM씩 낮춥니다.\n85°C 이상은 상승 지연 없이 반응하고 92°C 이상은 최대 속도를 요청합니다. 기기 위험 온도 기준이 아닌 사용자 설정입니다.\n\n시작 시 관리자 인증이 필요합니다. Stats와 Macs Fan Control은 자동으로 두세요. 종료·센서 오류·잠자기에는 애플 자동 복귀를 시도합니다.\n\n이전 커브의 실기 제어와 연결 종료 복귀는 확인했습니다. 이번 커브는 시뮬레이션 검증을 마쳤으며 장시간·고부하 실기 검증은 아직 남아 있습니다.")
    }
    func alert(_ title: String,_ text: String) {
        NSApp.activate(ignoringOtherApps:true)
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.addButton(withTitle:"확인"); a.runModal()
    }
}

let args = CommandLine.arguments
if args.contains("--self-test") { policyTests(); exit(0) }
if args.contains("--lease") { lease() }
if args.count == 4, let pid = Int32(args[2]), let born = UInt64(args[3]) {
    if args[1] == "--helper" { helper(pid,born) }
    if args[1] == "--control" { controller(pid,born) }
}
if args.contains("--probe") {
    guard let s = sample(SMC()) else { print("Sensor validation failed"); exit(1) }
    print("Model \(modelID()), CPU max \(s.cpu), GPU max \(s.gpu), RPM \(s.rpm), mode \(s.mode), range \(s.minimum)...\(s.maximum)")
    exit(0)
}
signal(SIGPIPE,SIG_IGN)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate(); app.delegate = delegate
app.run()
