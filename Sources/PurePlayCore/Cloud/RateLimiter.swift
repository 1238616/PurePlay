import Foundation

/// Token Bucket 限速器 — 防止夸克网盘风控
/// 默认 5 req/s，突发允许 10 个令牌
public final class RateLimiter: @unchecked Sendable {
    private let rate: Double
    private let burstCapacity: Int
    private var tokens: Double
    private var lastRefill: CFAbsoluteTime
    private let lock = NSLock()

    public init(rate: Double = 5.0, burst: Int = 10) {
        self.rate = rate
        self.burstCapacity = burst
        self.tokens = Double(burst)
        self.lastRefill = CFAbsoluteTimeGetCurrent()
    }

    /// 同步等待获取一个令牌
    public func acquire() {
        lock.lock()
        refill()
        while tokens < 1.0 {
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.05)
            lock.lock()
            refill()
        }
        tokens -= 1.0
        lock.unlock()
    }

    /// 异步等待获取令牌
    public func acquireAsync() async {
        while true {
            lock.lock()
            refill()
            if tokens >= 1.0 {
                tokens -= 1.0
                lock.unlock()
                return
            }
            lock.unlock()
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// 检查是否有可用令牌（不消耗）
    public var available: Bool {
        lock.lock()
        refill()
        let result = tokens >= 1.0
        lock.unlock()
        return result
    }

    private func refill() {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastRefill
        let newTokens = elapsed * rate
        tokens = min(Double(burstCapacity), tokens + newTokens)
        lastRefill = now
    }
}
