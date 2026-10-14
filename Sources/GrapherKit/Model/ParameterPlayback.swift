import Foundation

/// 参数播放的方式：到头之后往回走，还是回到起点重新开始。
public enum PlaybackMode: String, CaseIterable, Sendable {
    case pingPong
    case loop
}

/// 参数自动变化时每一帧怎么走：纯数学，界面层的计时器只管按时间调它。
public enum ParameterPlayback {

    /// 往前走 `seconds` 秒之后的值与方向。扫满整个范围要 `sweepSeconds` 秒；范围是 `lower…upper`。
    /// - 往返：走到端点就反向，一次跨过好几个来回（卡顿后的大步长）也折得对。
    /// - 循环：走到上端回到下端接着走（方向永远向上）。
    /// 起点不在范围里时先夹进范围。范围为空、时间或速度不合法时原样返回。
    public static func advance(
        value: Double, direction: Double, lower: Double, upper: Double,
        seconds: Double, sweepSeconds: Double, mode: PlaybackMode
    ) -> (value: Double, direction: Double) {
        guard upper > lower, seconds >= 0, sweepSeconds > 0, value.isFinite else { return (value, direction) }
        let span = upper - lower
        var position = (min(max(value, lower), upper) - lower) / span   // 0…1
        var heading = direction >= 0 ? 1.0 : -1.0
        let travel = seconds / sweepSeconds                              // 以「整个范围」为单位

        switch mode {
        case .loop:
            heading = 1
            position += travel
            position -= position.rounded(.down)
        case .pingPong:
            // 展开成在 0…2 的圆周上匀速走，再折回 0…1。
            var phase = heading > 0 ? position : 2 - position
            phase += travel
            phase = phase.truncatingRemainder(dividingBy: 2)
            if phase < 0 { phase += 2 }
            if phase <= 1 {
                position = phase
                heading = 1
            } else {
                position = 2 - phase
                heading = -1
            }
        }
        return (lower + position * span, heading)
    }
}
