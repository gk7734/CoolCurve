import Foundation

struct CoolingPolicy {
    // Locally selected values, NOT vendor thermal limits. See TUNING.md.
    static let points: [(Double, Double)] = [(50,1000),(55,1200),(60,1600),(65,2000),(70,2400),(75,2800),(80,3300),(85,3900),(90,4500),(92,4900)]
    var target: Double = 0
    var lastRise: Double = 0
    var lastTime: Double?
    var smoothed: Double?
    var referenceTemperature: Double?
    static func speed(at temperature: Double) -> Double {
        if temperature <= points[0].0 { return points[0].1 }
        for i in 1..<points.count {
            let a = points[i-1], b = points[i]
            if temperature <= b.0 { return a.1 + (b.1-a.1)*(temperature-a.0)/(b.0-a.0) }
        }
        return points.last!.1
    }
    mutating func update(temperature: Double, now: Double, minimum: Double, maximum: Double) -> Int? {
        guard temperature.isFinite, (5...115).contains(temperature), now.isFinite,
              minimum.isFinite, maximum.isFinite, minimum >= 500,
              maximum > minimum, maximum <= 10000 else { return nil }
        if let previous = lastTime, now <= previous || now-previous > 10 { return nil }
        let dt = lastTime.map { now-$0 } ?? 2
        lastTime = now
        if let old = smoothed {
            let tau = temperature > old ? 4.0 : 8.0
            smoothed = old + (1-exp(-dt/tau))*(temperature-old)
        } else { smoothed = temperature }
        // The high-temperature path bypasses smoothing and the upward slew limit.
        let input = temperature >= 85 ? max(temperature,smoothed!) : smoothed!
        if let reference = referenceTemperature {
            if input >= reference || input <= reference-2 { referenceTemperature = input }
        } else { referenceTemperature = input }
        var desired = Self.speed(at:referenceTemperature!)
        if temperature >= 92 { desired = maximum }
        desired = min(maximum, max(minimum, desired))
        if target == 0 {
            target = desired; lastRise = now
        } else if desired > target && (desired-target >= 50 || temperature >= 85) {
            target = temperature >= 85 ? desired : min(desired,target+150*min(dt,2))
            lastRise = now
        } else if now-lastRise >= 20 && target-desired >= 100 {
            target = max(desired, target-50*min(dt,2))
        }
        target = min(maximum, max(minimum, target))
        return Int(target.rounded())
    }
}

func policyTests() {
    var p = CoolingPolicy()
    func tick(_ t: Double, _ time: Double) -> Int? { p.update(temperature:t,now:time,minimum:1000,maximum:4900) }
    precondition(tick(65,0) == 2000)
    precondition(tick(92,2) == 4900, "Must react immediately to a hot sample")
    precondition(tick(55,4) == 4900, "Must not oscillate after brief cooling")
    for time in stride(from:6.0,through:20.0,by:2.0) { precondition(tick(55,time) == 4900) }
    precondition(tick(55,22) == 4800, "Slow ramp down after hold")
    precondition(tick(.nan,24) == nil)
    precondition(tick(0,24) == nil)
    precondition(tick(116,24) == nil)
    precondition(tick(100,26) == 4900)
    var limited = CoolingPolicy()
    precondition(limited.update(temperature:95,now:0,minimum:1000,maximum:3000) == 3000)
    var spike = CoolingPolicy()
    let base = spike.update(temperature:60,now:0,minimum:1000,maximum:4900)!
    let brief = spike.update(temperature:80,now:2,minimum:1000,maximum:4900)!
    precondition(brief-base <= 300 && brief < Int(CoolingPolicy.speed(at:80)))
    precondition(spike.update(temperature:86,now:4,minimum:1000,maximum:4900)! >= 4020)
    precondition(spike.update(temperature:60,now:20,minimum:1000,maximum:4900) == nil, "Stale control cycle must relinquish ownership")
    var jitter = CoolingPolicy()
    var outputs = [Int]()
    for i in 0..<120 {
        outputs.append(jitter.update(temperature:i%2 == 0 ? 65 : 64.5,now:Double(i*2),minimum:1000,maximum:4900)!)
    }
    precondition(Set(outputs).count == 1, "Sub-degree jitter must not hunt")
    var cooldown = CoolingPolicy()
    _ = cooldown.update(temperature:95,now:0,minimum:1000,maximum:4900)
    var previous = 4900
    for i in 1...180 {
        let rpm = cooldown.update(temperature:40,now:Double(i*2),minimum:1000,maximum:4900)!
        precondition(rpm <= previous && previous-rpm <= 100 && rpm >= 1000)
        previous = rpm
    }
    precondition(previous == 1000)
    print("PASS: hot override, spike filtering, jitter stability, cooldown, invalid/stale samples, hardware bounds")
}
