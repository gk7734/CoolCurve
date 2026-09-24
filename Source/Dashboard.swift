import SwiftUI
import AppKit

struct HistoryPoint: Identifiable {
    let id = UUID()
    let time: Date
    let cpu: Double
    let gpu: Double
    let rpm: Double
}
struct CoolingEvent: Identifiable {
    let id = UUID()
    let time = Date()
    let title: String
    let detail: String
}
final class DashboardModel: ObservableObject {
    @Published var page = 0
    @Published var cpu: Double?
    @Published var gpu: Double?
    @Published var rpm: Double?
    @Published var target: Double?
    @Published var state = "reading"
    @Published var fresh = false
    @Published var updated: Date?
    @Published var history: [HistoryPoint] = []
    @Published var events: [CoolingEvent] = []
    @Published var canStart = false
    @Published var canStop = false
    var start: () -> Void = {}
    var stop: () -> Void = {}
    var quit: () -> Void = {}
    var openFolder: () -> Void = {}
    func record(_ title: String, _ detail: String = "") {
        events.insert(CoolingEvent(title:title,detail:detail),at:0)
        events = Array(events.prefix(30))
    }
    var statusTitle: String {
        switch state {
        case "auto": return "애플 자동 제어"
        case "active": return "사용자 커브 작동 중"
        case "pending": return "관리자 승인 대기"
        case "restoring": return "애플 자동으로 복귀 중"
        case "external": return "다른 앱이 팬을 제어 중"
        case "error": return "센서 확인 필요"
        default: return "센서를 읽고 있어요"
        }
    }
    var statusDetail: String {
        switch state {
        case "auto": return "macOS가 팬 속도를 결정합니다. CoolCurve는 상태만 표시합니다."
        case "active": return "CPU와 GPU의 최고 온도를 바탕으로 팬 속도를 조절합니다."
        case "pending": return "macOS 인증창에서 승인하면 사용자 커브가 시작됩니다."
        case "restoring": return "보조 프로세스가 제어를 해제하는 중입니다."
        case "external": return "Stats와 Macs Fan Control을 자동 모드로 바꾼 뒤 시작하세요."
        case "error": return "표시값이 최신이 아닐 수 있습니다. 사용자 제어를 해제합니다."
        default: return "팬 설정을 변경하지 않고 현재 상태를 확인합니다."
        }
    }
}

private let blue = Color(red:0.24,green:0.52,blue:0.96)
private let teal = Color(red:0.12,green:0.65,blue:0.62)
private let card = Color(nsColor:.controlBackgroundColor)

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    var body: some View {
        VStack(alignment:.leading,spacing:22) {
            HStack(spacing:12) {
                Image(systemName:"fanblades.fill").font(.system(size:26)).foregroundStyle(.white)
                    .frame(width:48,height:48).background(blue.gradient,in:RoundedRectangle(cornerRadius:14))
                VStack(alignment:.leading,spacing:3) {
                    Text("CoolCurve").font(.system(size:25,weight:.semibold,design:.rounded))
                    Text("Mac mini M5 Pro · 냉각 대시보드").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Text("로컬 시험판 0.4").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal,11).padding(.vertical,6).background(.quaternary,in:Capsule())
            }
            HStack(spacing:8) {
                tab("대시보드",symbol:"square.grid.2x2",index:0)
                tab("온도 커브",symbol:"chart.xyaxis.line",index:1)
                tab("활동 기록",symbol:"clock",index:2)
                Spacer()
                if model.fresh { Label("실시간",systemImage:"circle.fill").font(.caption).foregroundStyle(teal) }
            }
            if model.page == 0 { overview }
            else if model.page == 1 { curvePage }
            else { eventsPage }
            Spacer(minLength:0)
            Divider()
            HStack {
                Text("창을 닫아도 메뉴 막대에서 계속 실행됩니다.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("프로젝트 폴더",action:model.openFolder).buttonStyle(.link)
                Button("자동 복귀 후 종료",action:model.quit).buttonStyle(.link)
            }
        }
        .padding(28)
        .frame(minWidth:760,minHeight:700)
        .background(Color(nsColor:.windowBackgroundColor))
    }
    func tab(_ title: String,symbol: String,index: Int) -> some View {
        Button { model.page = index } label: {
            Label(title,systemImage:symbol).font(.system(size:13,weight:.medium))
                .padding(.horizontal,15).padding(.vertical,9)
                .foregroundStyle(model.page == index ? blue : .secondary)
                .background(model.page == index ? blue.opacity(0.10) : .clear,in:RoundedRectangle(cornerRadius:9))
        }.buttonStyle(.plain).accessibilityLabel(title)
    }
    var statusPanel: some View {
        HStack(spacing:14) {
            Image(systemName:model.state == "active" ? "waveform.path" : "shield.lefthalf.filled")
                .font(.system(size:24)).foregroundStyle(model.state == "active" ? blue : teal)
            VStack(alignment:.leading,spacing:5) {
                Text(model.statusTitle).font(.headline)
                Text(model.statusDetail).font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            Spacer(minLength:8)
            if model.canStop {
                Button("애플 자동으로 복귀",action:model.stop).controlSize(.large).buttonStyle(.bordered)
            } else {
                Button("사용자 커브 시작",action:model.start).controlSize(.large).buttonStyle(.borderedProminent)
                    .tint(blue).disabled(!model.canStart)
            }
        }.padding(18).background(card,in:RoundedRectangle(cornerRadius:14))
    }
    var overview: some View {
        VStack(alignment:.leading,spacing:18) {
            statusPanel
            HStack(spacing:12) {
                metric("CPU 최고 온도",value:model.cpu,unit:"°C",symbol:"cpu",color:blue)
                metric("GPU 최고 온도",value:model.gpu,unit:"°C",symbol:"square.stack.3d.up",color:teal)
                metric("실제 팬 속도",value:model.rpm,unit:"RPM",symbol:"fanblades",color:.orange)
            }
            VStack(alignment:.leading,spacing:14) {
                HStack {
                    Text("최근 온도").font(.headline)
                    Spacer()
                    legend("CPU",color:blue); legend("GPU",color:teal)
                    Text("최대 5분").font(.caption).foregroundStyle(.secondary)
                }
                HistoryGraph(points:model.history).frame(height:158)
                HStack {
                    Text("최고 센서 온도 · 5초마다 갱신").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let t = model.updated { Text(t,style:.time).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
            }.padding(18).background(card,in:RoundedRectangle(cornerRadius:14))
            Label("애플 자동을 기본으로 권장합니다. 사용자 커브는 더 낮은 온도를 원할 때 선택하세요.",systemImage:"info.circle")
                .font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }
    }
    func metric(_ title: String,value: Double?,unit: String,symbol: String,color: Color) -> some View {
        VStack(alignment:.leading,spacing:12) {
            Label(title,systemImage:symbol).font(.system(size:12,weight:.medium)).foregroundStyle(.secondary)
            HStack(alignment:.firstTextBaseline,spacing:5) {
                Text(value.map { String(format:unit == "RPM" ? "%.0f" : "%.1f",$0) } ?? "—")
                    .font(.system(size:32,weight:.medium,design:.rounded)).monospacedDigit()
                Text(unit).font(.system(size:13)).foregroundStyle(.secondary)
            }
            Rectangle().fill(color.opacity(model.fresh ? 0.85 : 0.3)).frame(height:3).clipShape(Capsule())
        }.frame(maxWidth:.infinity,alignment:.leading).padding(18).background(card,in:RoundedRectangle(cornerRadius:14))
        .opacity(model.fresh ? 1 : 0.55)
    }
    func legend(_ title: String,color: Color) -> some View {
        HStack(spacing:5) { Circle().fill(color).frame(width:6,height:6); Text(title).font(.caption).foregroundStyle(.secondary) }
    }
    var curvePage: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                VStack(alignment:.leading,spacing:4) {
                    Text("사용자 냉각 커브").font(.title3.weight(.semibold))
                    Text("코드에 저장된 커브 · 온도 지점 사이를 비례 계산").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.state == "active" ? "사용 중" : "미사용").font(.caption.weight(.medium))
                    .padding(8).background(blue.opacity(0.1),in:Capsule()).foregroundStyle(blue)
            }
            CurveGraph().frame(height:195).padding(18).background(card,in:RoundedRectangle(cornerRadius:14))
            HStack(spacing:0) {
                ForEach(Array(CoolingPolicy.points.enumerated()),id:\.offset) { _, point in
                    VStack(spacing:5) {
                        Text("\(Int(point.0))°").font(.system(size:12,weight:.semibold))
                        Text("\(Int(point.1))").font(.system(size:11,design:.monospaced)).foregroundStyle(.secondary)
                    }.frame(maxWidth:.infinity)
                }
            }
            HStack(alignment:.top,spacing:20) {
                behavior("온도가 오를 때","일반 구간은 급등을 완화하고 2초당 최대 300 RPM씩 올립니다.",symbol:"arrow.up.right")
                behavior("온도가 내려갈 때","2°C 하강 조건과 20초 대기 후 2초당 최대 100 RPM씩 낮춥니다.",symbol:"arrow.down.right")
                behavior("85°C 이상일 때","상승 지연 없이 반응합니다. 92°C 이상이면 최대 속도를 요청합니다.",symbol:"thermometer.high")
            }.padding(18).background(card,in:RoundedRectangle(cornerRadius:14))
            Text("이 수치는 Apple의 온도 한계가 아닙니다. 더 높은 팬 속도가 더 높은 성능을 보장하지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    func behavior(_ title: String,_ text: String,symbol: String) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Image(systemName:symbol).foregroundStyle(blue)
            Text(title).font(.system(size:12,weight:.semibold))
            Text(text).font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    var eventsPage: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("이번 실행의 활동").font(.title3.weight(.semibold))
            Text("정상 복귀와 오류를 구분해 표시합니다. 최근 실행 결과는 프로젝트 폴더의 Last-run.txt에 저장됩니다.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing:0) {
                    ForEach(model.events) { event in
                        HStack(alignment:.top,spacing:12) {
                            Text(event.time,style:.time).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width:76,alignment:.leading)
                            VStack(alignment:.leading,spacing:5) {
                                Text(event.title).font(.system(size:13,weight:.semibold))
                                if !event.detail.isEmpty { Text(event.detail).font(.system(size:12)).foregroundStyle(.secondary).textSelection(.enabled) }
                            }.frame(maxWidth:.infinity,alignment:.leading)
                        }.padding(16)
                        Divider()
                    }
                }
            }.frame(maxHeight:.infinity).background(card,in:RoundedRectangle(cornerRadius:14))
        }
    }
}

struct CurveGraph: View {
    var body: some View {
        Canvas { context,size in
            let left: CGFloat = 42, bottom: CGFloat = 26
            let w = size.width-left-12, h = size.height-bottom-10
            func point(_ t: Double,_ rpm: Double) -> CGPoint { CGPoint(x:left+(t-45)/50*w,y:10+(1-(rpm-1000)/4000)*h) }
            for rpm in [1000,2000,3000,4000,4900] {
                let y = point(45,Double(rpm)).y
                var line = Path(); line.move(to:CGPoint(x:left,y:y)); line.addLine(to:CGPoint(x:size.width,y:y))
                context.stroke(line,with:.color(.secondary.opacity(0.15)),lineWidth:1)
                context.draw(Text("\(rpm)").font(.system(size:10)).foregroundColor(.secondary),at:CGPoint(x:20,y:y))
            }
            for t in [50,60,70,80,90] { context.draw(Text("\(t)°C").font(.system(size:10)).foregroundColor(.secondary),at:CGPoint(x:point(Double(t),1000).x,y:size.height-8)) }
            var curve = Path()
            for (i,p) in CoolingPolicy.points.enumerated() { if i == 0 { curve.move(to:point(p.0,p.1)) } else { curve.addLine(to:point(p.0,p.1)) } }
            context.stroke(curve,with:.color(blue),style:StrokeStyle(lineWidth:3,lineCap:.round,lineJoin:.round))
            for p in CoolingPolicy.points { let c = point(p.0,p.1); context.fill(Path(ellipseIn:CGRect(x:c.x-3,y:c.y-3,width:6,height:6)),with:.color(blue)) }
        }.accessibilityLabel("사용자 커브: 50도 1000 RPM부터 92도 4900 RPM까지")
    }
}
struct HistoryGraph: View {
    let points: [HistoryPoint]
    var body: some View {
        ZStack {
            Canvas { context,size in
                let w = size.width-32, h = size.height-10
                for t in [40,60,80,100] {
                    let y = (1-Double(t-30)/80)*h
                    var line = Path(); line.move(to:CGPoint(x:0,y:y)); line.addLine(to:CGPoint(x:w,y:y))
                    context.stroke(line,with:.color(.secondary.opacity(0.13)),lineWidth:1)
                    context.draw(Text("\(t)°").font(.system(size:10)).foregroundColor(.secondary),at:CGPoint(x:w+18,y:y))
                }
                guard let end = points.last?.time else { return }
                for (gpu,color) in [(false,blue),(true,teal)] {
                    var line = Path()
                    for (i,p) in points.enumerated() {
                        let x = max(0,1+p.time.timeIntervalSince(end)/300)*w
                        let y = (1-min(1,max(0,((gpu ? p.gpu : p.cpu)-30)/80)))*h
                        if i == 0 { line.move(to:CGPoint(x:x,y:y)) } else { line.addLine(to:CGPoint(x:x,y:y)) }
                    }
                    context.stroke(line,with:.color(color),style:StrokeStyle(lineWidth:2,lineCap:.round,lineJoin:.round))
                }
            }
            if points.count < 2 { Text("온도 기록을 모으고 있어요").font(.caption).foregroundStyle(.secondary) }
        }.accessibilityLabel("최근 5분 CPU와 GPU 최고 온도 그래프")
    }
}

struct MenuPanelView: View {
    @ObservedObject var model: DashboardModel
    var openDashboard: () -> Void
    var openGuide: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Label("CoolCurve",systemImage:"fanblades.fill")
                    .font(.system(size:16,weight:.semibold)).foregroundStyle(Color(red:0.43,green:0.70,blue:1))
                Spacer()
                Text(model.fresh ? "실시간" : "확인 중")
                    .font(.system(size:12,weight:.medium)).foregroundStyle(Color.white.opacity(0.85))
            }
            HStack(spacing:8) {
                Circle().fill(model.state == "auto" ? teal : (model.state == "active" ? blue : .orange)).frame(width:7,height:7)
                Text(model.statusTitle).font(.system(size:13,weight:.semibold))
                Spacer()
            }
            HStack(spacing:8) {
                metric("CPU 최고",value:model.cpu,unit:"°C",color:blue)
                metric("GPU 최고",value:model.gpu,unit:"°C",color:teal)
            }
            HStack {
                Label("팬 속도",systemImage:"fanblades").foregroundStyle(Color.white.opacity(0.85))
                Spacer()
                Text(model.rpm.map { String(format:"%.0f",$0) } ?? "—").font(.system(size:23,weight:.medium,design:.rounded)).monospacedDigit()
                Text("RPM").font(.system(size:12,weight:.medium)).foregroundStyle(Color.white.opacity(0.85))
            }
            if model.state == "active", let target = model.target {
                Text("요청 속도 \(Int(target)) RPM").font(.system(size:12,weight:.medium)).foregroundStyle(Color.white.opacity(0.85))
            }
            Text(model.statusDetail).font(.system(size:13)).foregroundStyle(Color.white.opacity(0.85))
                .fixedSize(horizontal:false,vertical:true)
            Divider()
            if model.canStop {
                Button(action:model.stop) { Label("애플 자동으로 복귀",systemImage:"arrow.uturn.backward").frame(maxWidth:.infinity) }
                    .controlSize(.large)
            } else {
                Button(action:model.start) { Label("사용자 커브 시작…",systemImage:"waveform.path").frame(maxWidth:.infinity) }
                    .controlSize(.large).disabled(!model.canStart)
            }
            HStack {
                Button("대시보드 열기",action:openDashboard).buttonStyle(.link)
                Spacer()
                Button(action:openGuide) { Image(systemName:"questionmark.circle") }.buttonStyle(.plain).help("설정과 사용 안내").accessibilityLabel("설정과 사용 안내")
                Button(action:model.quit) { Image(systemName:"power") }.buttonStyle(.plain).help("자동 복귀 후 종료").accessibilityLabel("자동 복귀 후 종료")
            }
        }
        .padding(20).frame(width:330,height:440,alignment:.top)
        .foregroundStyle(Color.white)
        .background(Color.black.opacity(0.08),in:RoundedRectangle(cornerRadius:20))
        .glassEffect(.regular.tint(Color.white.opacity(0.08)),in:RoundedRectangle(cornerRadius:20))
        .environment(\.colorScheme,.dark)
    }
    func metric(_ title:String,value:Double?,unit:String,color:Color) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Text(title).font(.system(size:12,weight:.medium)).foregroundStyle(Color.white.opacity(0.85))
            HStack(alignment:.firstTextBaseline,spacing:3) {
                Text(value.map { String(format:"%.1f",$0) } ?? "—")
                    .font(.system(size:26,weight:.semibold,design:.rounded)).monospacedDigit()
                Text(unit).font(.system(size:12,weight:.medium)).foregroundStyle(Color.white.opacity(0.85))
            }
            Capsule().fill(color).frame(height:3)
        }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
            .background(Color.black.opacity(0.08),in:RoundedRectangle(cornerRadius:12))
    }
}
