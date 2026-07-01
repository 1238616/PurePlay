# PurePlay 缺陷修复计划

> 基于高级测试审计报告，分 3 轮迭代修复 19 项缺陷。
> 总预估：3 轮 × 每轮 1-2 天 = 5-7 天完成全部修复。

---

## 迭代策略

| 轮次 | 目标 | 时间 | 验收标准 |
|------|------|------|---------|
| **Sprint 1** | 修复高优先级 + 用户可感知 bug | 1-2 天 | 音量不跳变、stop 可靠、chunk 有淘汰 |
| **Sprint 2** | 修复中优先级线程安全 + 功能闭环 | 1-2 天 | TSan clean、EQ 回路通、Gapless 健壮 |
| **Sprint 3** | 低优先级 + 测试补全 + 代码清洁 | 1-2 天 | 覆盖率 ≥220 tests、无死代码、CI-ready |

---

## Sprint 1 — 高优先级（H1-H4 + M3-M4）

### S1.1 — H3 音量跳变修复
**文件**: `Player/PlayerController.swift`
**改动**: 在 `playLocal()` 和 `playCloud()` 的 `try pipe.start()` 之后立即调用 `output.setVolume(volume)`。
**验收**: 设 volume=0.3 → 播放 → 切下一首 → 音量仍为 0.3。

### S1.2 — H2 stop() 竞态修复
**文件**: `Player/PlayerController.swift`
**改动**: 在 `playCloud()` 的两处 `await` 之后各加一行 `guard state == .buffering else { return }`。
**验收**: 播放云盘 → 缓冲期间点 stop → 音频不再开始。

### S1.3 — M4 decoder 泄漏修复
**文件**: `Player/PlayerController.swift`
**改动**: `tryGaplessAdvance()` 的 catch 块顶部增加 `dec.close()`。
**验收**: 反复触发 gapless 失败路径 → lsof 无残留 FileHandle。

### S1.4 — H1 chunk 淘汰
**文件**: `Cloud/CloudStreamSource.swift`
**改动**: 
- 新增 `evictBehindPosition()` 私有方法：在 `read()` 成功返回后异步调用；
- 淘汰 `position - 2 * chunkSize` 之前的所有 `.ready` 块（保留当前 ±2 块热区）。
**验收**: 播放 500MB 文件到末尾 → 峰值 RSS < 50MB（vs 现在 500MB+）。

### S1.5 — H4 重试退避
**文件**: `Cloud/CloudStreamSource.swift`
**改动**:
- 新增 `.failed(retryCount: Int)` 到 ChunkState enum；
- `fetchChunk` catch 中递增 retryCount，超 3 次标记 `.failed`；
- 重试间隔指数退避（1s / 2s / 4s via Task.sleep）；
- `read()` 遇到 `.failed` 直接抛 `PurePlayError.ioError`。
**验收**: 断网 → read 最多重试 3 次后抛错（不再无限循环）。

### S1.6 — M3 设备切换云盘恢复
**文件**: `Player/PlayerController.swift`
**改动**: `setOutputDevice()` 的恢复分支检测 `.cloud` 后用 `Task { try await playFromQueueAsync(...) }` 代替同步 `try? playFromQueue()`。
**验收**: 云盘播放中切设备 → 播放自动恢复。

---

## Sprint 2 — 线程安全 + 功能闭环（M1-M2, M5-M6, F4-F5）

### S2.1 — M1 decoder 竞争修复
**文件**: `Audio/AudioPipeline.swift`
**改动**: grace-window 中读 `self.decoder` 前后用 `seekLock` 短暂加锁：
```swift
seekLock.lock()
let currentDecoder = decoder
seekLock.unlock()
let currentDecoderID = ObjectIdentifier(currentDecoder)
```
**验收**: TSan 在 gapless 流程中无 data-race 报告。

### S2.2 — M2 onProgress 竞争修复
**文件**: `Cloud/CloudStreamSource.swift`
**改动**: `fetchChunk` 完成时在 lock 内 capture 闭包到局部变量，unlock 后调用：
```swift
lock.lock()
let cb = onProgress
lock.unlock()
cb?(ready, totalBytes)
```
**验收**: TSan clean。

### S2.3 — M6 isRunning 原子化
**文件**: `Audio/AudioPipeline.swift`
**改动**: 将 `private var isRunning = false` 改为 `private let _isRunning = ManagedAtomic<Bool>(false)`，所有读写走 atomic 操作。
**验收**: TSan clean。

### S2.4 — M5 短曲 gapless 修复
**文件**: `Audio/AudioPipeline.swift` + `Player/PlayerController.swift`
**改动**: 
- grace window 从 250ms 提升到 600ms（> timer 的 500ms，确保 timer 有机会触发 swap）；
- 或者把 timer interval 从 0.5s 缩短到 0.2s（更快检测 isAtEnd）。
推荐后者：0.2s timer + 保留 250ms grace = 在 isAtEnd 后 50ms 内 timer 一定能触发。
**验收**: 播放 100ms WAV 队列 × 10 首 → 全部 gapless 无静音。

### S2.5 — F4 EQ 回路接入
**文件**: `App/main.swift`
**改动**: 在 AppDelegate 中 wire `EQPanel.shared.onChanged = { enabled, gains in ... }`，回调内更新 `playerController` 的 DSPPreferences 并通知当前管线重建 DSP chain（或延迟到下一首生效）。
**验收**: 开 EQ → 拖拽 → 听到频响变化。

### S2.6 — F5 NowPlayingViewModel 活化
**文件**: `App/main.swift`
**改动**: 在 `updateNowPlaying(url:)` 和 `updateForCloud(...)` 中改用 `applyNowPlaying(NowPlayingViewModel.derive(from: playerController, ...))`。删除旧直接 label 赋值。
**验收**: 播放时标题/艺人来自 ViewModel → 验证单元测试 derive() 输出一致。

---

## Sprint 3 — 低优先级 + 测试补全 + 清洁

### S3.1 — L1 CloudStreamSource lock/cv 统一
**改动**: 把 `NSCondition` 去掉，改用 `lock` + `DispatchSemaphore` 或统一为 `NSCondition`（单一条件对象同时做 mutex）。

### S3.2 — L4 SincResampler work buffer 复用
**改动**: 把 `work` 改为实例属性 `[Float]`，按需扩容。

### S3.3 — L7 死代码清理
**改动**: 移除 `needRight` / `_ = needRight`。

### S3.4 — F7 GlobalHotKey 权限检查
**改动**: 注册前用 `AXIsProcessTrusted()` 检测；若未授权弹 alert 引导用户到「系统设置 → 隐私与安全 → 输入监控」。

### S3.5 — F1 端到端播放测试
**改动**: 新增 integration test：用 `MockAudioOutput.pullFrames()` 模拟真实渲染节奏，验证从 play → 解码 → ring buffer → pullFrames 全链路字节正确。

### S3.6 — F3 压力测试骨架
**改动**: 新增 `stressTestGaplessLoop`：在测试中连续 gapless 50 首短 WAV，验证 0 underrun。

### S3.7 — L2 Unmanaged 安全加固
**改动**: 在 `CoreAudioHALOutput` 中用 `passRetained` 替代 `passUnretained`，并在 `stop()` 中 `takeRetainedValue()` 释放。确保即使 deinit 延迟也不会 use-after-free。

### S3.8 — EQ 持久化
**改动**: EQ enabled + gains 存入 `UserDefaults`；App 启动时恢复。

---

## 自动化验证矩阵

每轮完成后必须满足：

| 检查项 | 命令 | 预期 |
|--------|------|------|
| 编译 | `swift build` | 0 errors, 0 warnings |
| 测试 | `swift run PurePlayTests` | all pass (≥206) |
| Release 构建 | `swift build -c release --product PurePlay` | success |
| TSan (选测) | `swift build -c debug -Xswiftc -sanitize=thread` | 0 data races |

---

## 进度追踪

每个 Sprint 开始时更新 TodoWrite，每完成一项立即标记。
Loop 每 30 分钟 tick 一次检查当前 Sprint 进度。
