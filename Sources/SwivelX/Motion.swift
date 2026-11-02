import AppKit
import Foundation

// MARK: - 缓动曲线（来自 emilkowalski/animate 的代币规范）
// --ease-out:    cubic-bezier(0.23, 1, 0.32, 1)   进入/退出
// --ease-in-out: cubic-bezier(0.77, 0, 0.175, 1)  屏幕上的位移
// --ease-drawer: cubic-bezier(0.32, 0.72, 0, 1)   iOS 抽屉
// 规范：UI 动画一律 < 300ms；绝不在进入动画上用 ease-in；
//       交互态用可打断的过渡（类比 CSS transition），阶段性序列才用关键帧。

struct CubicBezier {
    let x1: Double, y1: Double, x2: Double, y2: Double

    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
    }

    /// 给定进度 t(0...1)，返回缓动后的值
    func value(at t: Double) -> Double {
        let x = min(max(t, 0), 1)
        // 二分求解 x(u) = t
        var lo = 0.0, hi = 1.0, u = x
        for _ in 0..<18 {
            u = (lo + hi) / 2
            let cx = bezier(u, x1, x2)
            if cx < x { lo = u } else { hi = u }
        }
        return bezier(u, y1, y2)
    }

    private func bezier(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let mt = 1 - t
        return 3 * mt * mt * t * a + 3 * mt * t * t * b + t * t * t
    }
}

enum Ease {
    static let out    = CubicBezier(0.23, 1, 0.32, 1)
    static let inOut  = CubicBezier(0.77, 0, 0.175, 1)
    static let drawer = CubicBezier(0.32, 0.72, 0, 1)
    static let linear = CubicBezier(0, 0, 1, 1)
}

// MARK: - 时长代币

enum Timing {
    static let press: TimeInterval    = 0.12   // 100–160ms 按压反馈
    static let popover: TimeInterval  = 0.20   // 125–200ms 小浮层
    static let ring: TimeInterval     = 0.24   // 150–250ms 展开/收起
    static let selection: TimeInterval = 0.14  // 交互态切换（可打断）
}

// MARK: - 可打断的过渡（类比 CSS transition）

@MainActor
final class Anim {
    private(set) var value: CGFloat
    private var target: CGFloat
    private var from: CGFloat
    private var start: Date
    private var duration: TimeInterval
    private var ease: CubicBezier

    init(_ initial: CGFloat, duration: TimeInterval = Timing.ring, ease: CubicBezier = Ease.out) {
        self.value = initial
        self.target = initial
        self.from = initial
        self.start = Date()
        self.duration = duration
        self.ease = ease
    }

    /// 设定新目标：从当前值出发，中途打断也平滑（规范 4）
    func to(_ newTarget: CGFloat, duration: TimeInterval? = nil, ease: CubicBezier? = nil) {
        if abs(newTarget - target) < 0.0005 && abs(value - target) < 0.0005 { return }
        from = value
        target = newTarget
        start = Date()
        if let d = duration { self.duration = d }
        if let e = ease { self.ease = e }
    }

    /// 直接跳到终值（用于「减弱动态效果」）
    func jump(to final: CGFloat) {
        value = final; target = final; from = final; start = Date()
    }

    /// 推进一帧，返回是否仍需继续重绘
    @discardableResult
    func tick() -> Bool {
        let t = min(1, Date().timeIntervalSince(start) / duration)
        value = from + (target - from) * CGFloat(ease.value(at: t))
        return t < 1
    }
}

// MARK: - 弹簧过渡（真·弹性：会冲过头再回弹）

/// 欠阻尼弹簧的解析解，时间驱动，和帧率无关。
/// 线性缓动永远不会有「弹」的感觉 —— 弹性来自**冲过目标值再荡回来**。
/// - zeta 越小越弹（0.4 ≈ 20% 过冲，0.55 ≈ 12%，1.0 = 不弹）
/// - omega 越大越快（20 约 0.19s 到峰值、0.36s 稳住）
@MainActor
final class Spring {

    private(set) var value: CGFloat
    private var from: CGFloat
    private var target: CGFloat
    private var start = Date()
    private var omega: Double
    private var zeta: Double

    init(_ initial: CGFloat, omega: Double = 20, zeta: Double = 0.55) {
        value = initial
        from = initial
        target = initial
        self.omega = omega
        self.zeta = min(0.95, max(0.15, zeta))
    }

    /// 改目标：从当前值（含当前速度方向）重新出发，打断也平滑
    func to(_ newTarget: CGFloat, omega: Double? = nil, zeta: Double? = nil) {
        if abs(newTarget - target) < 0.0005 && abs(value - target) < 0.001 { return }
        from = value
        target = newTarget
        start = Date()
        if let omega { self.omega = omega }
        if let zeta { self.zeta = min(0.95, max(0.15, zeta)) }
    }

    func jump(to final: CGFloat) {
        value = final
        from = final
        target = final
        start = Date()
    }

    /// 推进一帧，返回是否仍需继续重绘
    @discardableResult
    func tick() -> Bool {
        let t = Date().timeIntervalSince(start)
        let settle = 6.0 / (zeta * omega)
        if t >= settle {
            value = target
            return false
        }
        let wd = omega * (1 - zeta * zeta).squareRoot()
        let env = exp(-zeta * omega * t)
        let d = Double(from - target)
        let x = Double(target) + d * env * (cos(wd * t) + (zeta * omega / wd) * sin(wd * t))
        value = CGFloat(x)
        return true
    }
}

// MARK: - 关键帧过渡（放大 → 缩小 → 正常）

/// 按时间轴跑一组关键帧。每一段用各自的缓动，跑完停在最后一个值。
/// 用它来表达「冲过头 → 回一点 → 落定」这种有明确节拍的动作。
@MainActor
final class Keyframe {

    struct Key {
        let t: TimeInterval
        let v: CGFloat
        let ease: CubicBezier
        init(_ t: TimeInterval, _ v: CGFloat, _ ease: CubicBezier = Ease.out) {
            self.t = t; self.v = v; self.ease = ease
        }
    }

    private(set) var value: CGFloat
    private var keys: [Key] = []
    private var start = Date()
    private var running = false

    init(_ initial: CGFloat) { value = initial }

    func run(_ keys: [Key]) {
        guard keys.count >= 2 else { value = keys.first?.v ?? value; return }
        self.keys = keys.sorted { $0.t < $1.t }
        value = self.keys[0].v
        start = Date()
        running = true
    }

    func jump(to v: CGFloat) {
        value = v
        keys = []
        running = false
    }

    @discardableResult
    func tick() -> Bool {
        guard running, let last = keys.last else { return false }
        let el = Date().timeIntervalSince(start)
        if el >= last.t {
            value = last.v
            running = false
            return false
        }
        var i = 1
        while i < keys.count && el > keys[i].t { i += 1 }
        let a = keys[i - 1], b = keys[i]
        let span = max(0.0001, b.t - a.t)
        let p = min(1, max(0, (el - a.t) / span))
        let e = b.ease.value(at: p)
        value = a.v + (b.v - a.v) * CGFloat(e)
        return true
    }
}

// MARK: - 减弱动态效果开关

enum MotionPreference {
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
