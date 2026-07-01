# PurePlay — macOS Hi-Fi 音乐播放器产品设计文档

> 项目代号：**PurePlay**
> 版本：v2.0（基于 Strawberry Music Player 架构分析重设计）
> 定位：macOS 原生、bit-perfect、本地 + 云盘的 Hi-Res 音乐播放器
> 目标用户：Hi-Fi 发烧友、本地音乐收藏者、云盘音乐库用户
> 竞品参考：Strawberry (C++/Qt/GStreamer)、Vox、Audirvana、VLC

---

## 一、竞品分析：Strawberry Music Player

### 1.1 Strawberry 架构概要

| 维度 | Strawberry | 说明 |
|------|-----------|------|
| **语言** | C++ / Qt6 | 跨平台（Linux/macOS/Windows） |
| **音频引擎** | GStreamer | 插件生态，广泛格式支持 |
| **数据库** | SQLite | 持久化音乐库 + 智能播放列表 |
| **流媒体** | Tidal / Qobuz / Spotify / Subsonic | 商业音乐服务集成 |
| **模块数** | 40+ | engine/ collection/ playlist/ equalizer/ covermanager/ lyrics/ scrobbler/ tidal/ qobuz/ ... |
| **构建** | CMake + ~15 可选依赖 | libgstreamer, taglib, protobuf, libchromaprint... |

### 1.2 Strawberry 的优势（PurePlay 可借鉴）

| 特性 | Strawberry 做法 | PurePlay 借鉴策略 |
|------|---------------|------------------|
| **音乐库持久化** | SQLite + MusicBrainz 标签查询 + 多源封面获取 | ✅ 优先实现 GRDB/SQLite 迁移 |
| **智能播放列表** | filterparser/ 模块，SQL 查询驱动 | ✅ 实现基于规则的智能列表 |
| **无缝播放** | GStreamer pipeline 预缓冲 + 流切换 | ✅ 替换定时器检测为预解码策略 |
| **封面管理** | 多源获取（本地嵌入/网络/MusicBrainz） | ✅ 提取嵌入封面 + 目录图片 |
| **Last.fm 听歌记录** | scrobbler/ 模块 | ⚠️ Phase 3+ 考虑 |
| **全局快捷键** | MPRIS2 (Linux) / 系统热键 | ✅ 媒体键 + 全局热键 |
| **歌词显示** | lyrics/ 模块，多源在线获取 | ⚠️ Phase 4+ |
| **转码** | transcoder/ (GStreamer 内建) | ❌ 不做（不是播放器核心） |
| **设备同步** | device/ (libmtp/libgpod) | ❌ 不做（非目标场景） |

### 1.3 PurePlay 的独有优势（Strawberry 不具备）

| 特性 | PurePlay | Strawberry 为何没有 |
|------|---------|-------------------|
| **macOS CoreAudio HAL 独占** | Hog Mode + 自动采样率切换 | GStreamer CoreAudio sink 无独占能力 |
| **DSD/DoP 原生** | DoP v1.1 打包、DAC 能力探测 | 无 DSD 意识 |
| **Bit-Perfect 信号纯净** | DSP 默认旁路，零损耗 | GStreamer 总有 format 协商开销 |
| **零外部依赖音频路径** | 手写 pipeline，仅 swift-atomics | GStreamer ~200MB 依赖 |
| **夸克网盘流式播放** | Range 请求 + 预缓冲 + LRU 缓存 | 无个人云盘集成 |
| **信号路径可视化** | 底栏实时显示 DAC → 格式 → 模式 | 无 |
| **macOS 原生极简 UI** | AppKit + Vox 设计语言 | Qt 非原生 |

### 1.4 设计决策：PurePlay 定位策略

```
Strawberry 路线：功能广度（40+ 模块，全平台，全服务）
PurePlay 路线：音质深度（信号纯净，DSD 原生，macOS 最优）

不与 Strawberry 竞争功能数量，而是在 "信号路径零损耗" 这条线做到极致。
选择性借鉴 Strawberry 的基础设施（库管理、封面、无缝播放）。
```

---

## 二、产品愿景（v2.0）

### 2.1 一句话

> "**Strawberry 的库管理深度 + Audirvana 的音质底座 + 夸克网盘云端音乐库，压缩在 macOS 原生极简体积中。**"

### 2.2 核心差异化

| 维度 | Strawberry | Audirvana | Vox | **PurePlay** |
|------|:---------:|:---------:|:---:|:------------:|
| 平台 | 全平台 | macOS/Win | macOS | macOS |
| 音频引擎 | GStreamer | 自研 | 自研 | 自研(VLC启发) |
| Bit-Perfect | ⚠️ (Linux ALSA) | ✅ | ✅ | ✅ |
| DSD/DoP | ❌ | ✅ | ⚠️ | ✅ |
| 信号路径显示 | ❌ | ⚠️ | ❌ | ✅ |
| 智能播放列表 | ✅ | ❌ | ❌ | ✅ (规划) |
| 云盘集成 | ❌ | ❌ | ❌ | ✅ (夸克) |
| 体积 | ~50MB | ~80MB | <20MB | <10MB |
| 价格 | 免费开源 | $$$$ | 免费+付费 | 免费开源 |

### 2.3 目标用户画像

| 用户群 | 场景 | 核心需求 | Strawberry 满足 | PurePlay 满足 |
|--------|------|---------|:-:|:-:|
| Hi-Fi 发烧友 | USB DAC + 高解析文件 | bit-perfect, DSD | ❌ | ✅ |
| 本地收藏者 | 大型 FLAC 库管理 | 智能列表, 封面 | ✅ | ⚠️→✅ |
| 云盘用户 | TB 级夸克网盘音乐 | 流式播放, 缓存 | ❌ | ✅ |
| macOS 用户 | 原生体验, 低内存 | 轻量, 美观 | ❌ (Qt) | ✅ |

---

## 三、系统架构（v2.0 重设计）

### 3.1 分层架构（借鉴 Strawberry 模块化 + VLC 管线）

```
┌──────────────────────────────────────────────────────────────────────┐
│ Layer 5 — UI (AppKit, Vox 设计语言)                                    │
│  主窗口 · 播放列表 · 封面 · 信号路径栏 · 设置 · 云盘浏览器             │
├──────────────────────────────────────────────────────────────────────┤
│ Layer 4 — Application Services                                        │
│  PlayerController · PlaylistManager · LibraryScanner                  │
│  CloudSession(夸克) · CoverArtManager · ScrobbleService              │
├──────────────────────────────────────────────────────────────────────┤
│ Layer 3 — Audio Engine (手写, 零 GStreamer)                            │
│  ┌────────────┐  ┌────────────┐  ┌──────────┐  ┌────────────┐       │
│  │  Source    │─▶│  Decoder   │─▶│ DSPChain │─▶│   Output   │       │
│  │(Local/Cloud)│  │(CoreAudio/ │  │(bypass   │  │(CoreAudio  │       │
│  │            │  │ WAV/FFmpeg)│  │ by def)  │  │ HogMode)   │       │
│  └────────────┘  └────────────┘  └──────────┘  └────────────┘       │
│  PCMRingBuffer · DoPPacker · DACCapabilityProbe · GaplessPreloader   │
├──────────────────────────────────────────────────────────────────────┤
│ Layer 2 — Data & Infrastructure                                       │
│  SQLite(GRDB) · MetadataReader(taglib/AudioToolbox)                   │
│  SmartPlaylistEngine · FileScanner(FSEvents)                          │
│  QuarkAPIClient · CloudDownloadCache · KeychainStore · RateLimiter    │
├──────────────────────────────────────────────────────────────────────┤
│ Layer 1 — Platform (macOS 13+)                                        │
│  CoreAudio HAL · AudioToolbox · Security.framework · WebKit(可选)     │
└──────────────────────────────────────────────────────────────────────┘
```

### 3.2 vs Strawberry 架构对比

| 模块 | Strawberry | PurePlay | 选择理由 |
|------|-----------|----------|---------|
| 音频引擎 | GStreamer | 手写 Pipeline | 完全控制信号路径，无格式协商损耗 |
| 解码 | GStreamer 插件 | AudioToolbox + libFLAC | macOS 原生支持 FLAC/ALAC/AAC/MP3 |
| 输出 | GStreamer sink | CoreAudio HAL 直驱 | Hog Mode + 采样率切换 |
| 数据库 | SQLite (直接) | GRDB.swift (ORM) | Swift 原生，类型安全 |
| 封面 | CoverManager (多源) | CoverArtManager | 嵌入提取 + 目录扫描 |
| 播放列表 | 多标签 + 智能 | 单列表 + 智能(规划) | 保持极简，逐步扩展 |
| 流媒体 | Tidal/Qobuz/Subsonic | 夸克网盘 | 服务目标市场 |
| UI 框架 | Qt6 Widgets | AppKit | macOS 原生 |
| 构建依赖 | ~15 个 | 1 个 (swift-atomics) | 极简依赖 |

---

## 四、音频引擎设计

### 4.1 信号路径（核心差异化）

```
文件/云盘 → Source → Decoder → [DSP Chain (默认旁路)] → Ring Buffer → CoreAudio Hog Mode → DAC

关键保证：
• Bit-Perfect 模式下零 DSP 处理
• 保持源文件原始 PCM 精度（不强制转 float32）
• 自动采样率切换匹配源文件
• DSD 文件自动选择 DoP 或 PCM 转换
```

### 4.2 无缝播放（借鉴 Strawberry GStreamer 预缓冲策略）

```
当前曲播放进度 > 80%:
  → 预解码下一曲前 2 秒到 Ring Buffer B
  → 当前曲结束 → 无停顿切换到 Buffer B
  → 如果采样率/位深不同 → 静默切换设备格式 → 极短间隙（<50ms）

替代现有方案：
  旧: Timer 0.5s 检测 isAtEnd → 间隙明显
  新: 预解码 + 双缓冲 → 真正无缝
```

### 4.3 解码器支持（通过 AudioToolbox + 专用解码器）

| 格式 | 解码器 | Strawberry 对比 |
|------|--------|---------------|
| FLAC | AudioToolbox (macOS 原生) | GStreamer flac 插件 |
| ALAC/AAC/MP3 | AudioToolbox (macOS 原生) | GStreamer 插件 |
| DSD (DSF/DFF) | 自建 DSD 解码 + DoP | ❌ 不支持 |
| WAV/AIFF | 自建 WAVDecoder | GStreamer wav 插件 |
| APE/WavPack/Ogg | FFmpeg (LGPL, 可选) | GStreamer 插件 |

### 4.4 DSP 链（默认旁路，可选启用）

| 节点 | 算法 | 状态 |
|------|------|:----:|
| ReplayGain | 整数增益 | ✅ 已实现 |
| Biquad EQ | 10 段 IIR Peaking EQ | ✅ 已实现 |
| Crossfeed | BS2B 耳机交叉馈入 | ✅ 已实现 |
| Dither | TPDF (位深降级时) | ✅ 已实现 |
| Resampler | SoXR VHQ (规划) | ⚠️ 占位 |

---

## 五、音乐库管理（借鉴 Strawberry）

### 5.1 数据库设计（SQLite via GRDB.swift）

```sql
-- 借鉴 Strawberry 的 collection 模块设计
CREATE TABLE tracks (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    file_path     TEXT NOT NULL UNIQUE,
    source        TEXT NOT NULL DEFAULT 'local',  -- 'local' | 'quark'
    cloud_fid     TEXT,
    title         TEXT,
    artist        TEXT,
    album         TEXT,
    album_artist  TEXT,
    track_number  INTEGER DEFAULT 0,
    disc_number   INTEGER DEFAULT 1,
    year          INTEGER,
    genre         TEXT,
    duration      REAL DEFAULT 0,
    sample_rate   REAL DEFAULT 44100,
    bit_depth     INTEGER DEFAULT 16,
    channels      INTEGER DEFAULT 2,
    format        TEXT,
    file_size     INTEGER DEFAULT 0,
    cover_hash    TEXT,               -- 封面图片哈希，用于去重
    replay_gain_track REAL,
    replay_gain_album REAL,
    date_added    REAL,
    last_played   REAL,
    play_count    INTEGER DEFAULT 0
);

CREATE INDEX idx_tracks_album ON tracks(album_artist, album, disc_number, track_number);
CREATE INDEX idx_tracks_artist ON tracks(artist);

-- 智能播放列表（借鉴 Strawberry filterparser/）
CREATE TABLE smart_playlists (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    name      TEXT NOT NULL,
    rules     TEXT NOT NULL,          -- JSON 编码的过滤规则
    sort_by   TEXT DEFAULT 'title',
    sort_asc  INTEGER DEFAULT 1,
    max_items INTEGER
);

-- 普通播放列表
CREATE TABLE playlists (
    id   INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL
);

CREATE TABLE playlist_items (
    playlist_id INTEGER REFERENCES playlists(id),
    track_id    INTEGER REFERENCES tracks(id),
    position    INTEGER,
    PRIMARY KEY (playlist_id, position)
);
```

### 5.2 智能播放列表规则引擎

借鉴 Strawberry 的 `filterparser/` 模块：

```swift
/// 智能播放列表规则（类似 Strawberry 的 SmartPlaylistSearch）
enum SmartPlaylistRule {
    case format(is: AudioFileFormat)
    case sampleRateAbove(Double)
    case bitDepthAbove(Int)
    case artistContains(String)
    case albumContains(String)
    case genreIs(String)
    case addedAfter(Date)
    case playCountBelow(Int)
    case isDSD
    case isHiRes  // >44.1kHz 或 >16bit
}
```

### 5.3 封面管理（借鉴 Strawberry CoverManager）

```
获取优先级:
1. 文件内嵌封面 (ID3 APIC / Vorbis Comment PICTURE)
2. 同目录 cover.jpg / folder.jpg / front.jpg
3. 同目录任意 .jpg/.png（按文件名匹配度排序）
4. MusicBrainz Cover Art Archive (可选，在线)

存储:
- 封面缓存目录: ~/Library/Caches/PurePlay/covers/
- 以 SHA256(封面数据) 为文件名去重
- SQLite tracks.cover_hash 关联
```

---

## 六、夸克网盘集成

### 6.1 架构（v2.0 验证完成）

```
WKWebView/Cookie粘贴 → QuarkAPIClient → CloudStreamSource → AudioPipeline
                                              ↓
                              CloudDownloadCache (LRU 2GB)
```

### 6.2 已实现功能

| 功能 | 状态 | 说明 |
|------|:----:|------|
| Cookie 认证 | ✅ | 手动粘贴 + Keychain 持久化 |
| 目录浏览 | ✅ | 支持导航、返回、刷新 |
| 音频文件过滤 | ✅ | 仅显示音频 + 目录 |
| 单文件播放 | ✅ | 预缓冲 5MB → 流式解码 |
| 批量加入列表 | ✅ | "全部加入列表" 按钮 |
| LRU 磁盘缓存 | ✅ | 已实现但未接入播放路径 |
| 请求限速 | ✅ | Token Bucket ≤5 req/s |

### 6.3 下一步规划

| 功能 | 优先级 | 说明 |
|------|:------:|------|
| 缓存接入播放路径 | P0 | 播放前检查缓存，播放后写入缓存 |
| 预加载下一曲 | P1 | 进度>80% 自动下载 |
| 自动扫描云盘目录 | P1 | 配置监控目录，增量同步到 SQLite |
| WebDAV/Nextcloud 支持 | P2 | 扩展非夸克用户群 |

---

## 七、UI 设计（Vox 风格 + Strawberry 功能密度平衡）

### 7.1 设计哲学

```
Strawberry 风格: 信息密度最大化（多标签/多面板/筛选器）→ 适合键鼠 power user
Vox 风格:       封面即英雄，控件隐形 → 适合沉浸听音
PurePlay 平衡:  默认 Vox 极简 + 按需展开 Strawberry 级功能
                "简约入口，深度可达"
```

### 7.2 主界面（已实现）

```
┌────────────────────────────────────────────────────────────────────┐
│ ● ● ●              PurePlay v1.3.x                      [⌃] [☁]  │
├────────────────────────────────────────────────────────────────────┤
│                                                                    │
│            ┌────────────────────────────────┐                      │
│            │         ALBUM  ART            │    ┌─────────┐       │
│            │       (60% 高度)               │    │ 96kHz   │       │
│            └────────────────────────────────┘    │ 24bit   │       │
│                                                  │ FLAC    │       │
│   Track Title                                    │ Bit-P   │       │
│   Artist — Album                                 └─────────┘       │
│   ☁ 夸克网盘                                                       │
│                                                                    │
│   ━━━━━━━━━━●━━━━━━━━━━━━━━━━━━━━━━━━━━  00:00 / 05:12            │
│                                                                    │
│   ┌── 波形/频谱 ──────────────────────────────────┐                │
│   └────────────────────────────────────────────────┘                │
│                                                                    │
│      🔀  ◀◀   ▶⏸   ▶▶   ☁   📋                                    │
│                                                                    │
│   🔊 ─────────────────────────────────── 75%                       │
│                                                                    │
│   Hi-Res · 96kHz · 24bit · Bit-Perfect                             │
├────────────────────────────────────────────────────────────────────┤
│   PLAYLIST (12 tracks, 3☁)                    [+] [−] [Clear]      │
│   ▶ 1. ☁ Track Name                                    FLAC        │
│     2. Local Track                                      WAV         │
│     3. ☁ Another                                        DSD         │
├────────────────────────────────────────────────────────────────────┤
│ 🔊 ES9038 · Hog · 96k/24b · Bit-Perfect · ☁ 5.0MB/s              │
└────────────────────────────────────────────────────────────────────┘
```

### 7.3 播放控件功能

| 按钮 | 功能 | 状态 |
|------|------|:----:|
| 🔀/🔁/🔂/→ | 播放模式切换（随机/循环/单曲/顺序） | ✅ |
| ◀◀ | 上一曲（尊重播放模式） | ✅ |
| ▶⏸ | 播放/暂停切换 | ✅ |
| ▶▶ | 下一曲（尊重播放模式） | ✅ |
| ☁ | 夸克网盘（登录/浏览/选择） | ✅ |
| 📋 | 播放列表显示/隐藏 | ✅ |
| 🔊 滑块 | 音量控制（CoreAudio Unit 级别） | ✅ |

---

## 八、实施路线图（基于 Strawberry 对标）

### Phase 1 — 核心引擎 ✅ 已完成

- [x] CoreAudio HAL 输出 (Hog Mode)
- [x] WAV/FLAC/ALAC/MP3/AAC 解码 (AudioToolbox)
- [x] PCM Ring Buffer (无锁)
- [x] DSP Chain (Gain/EQ/Crossfeed/Dither)
- [x] DSD/DoP 打包
- [x] AudioPipeline 编排
- [x] PlayerController (播放/暂停/上下曲/模式)
- [x] 音量控制

### Phase 2 — 夸克网盘 ✅ 已完成

- [x] QuarkAPIClient (Cookie 认证/文件列表/下载)
- [x] CloudStreamSource (Range 流式)
- [x] CloudDownloadCache (LRU)
- [x] 文件浏览器 UI (目录导航/全部加入列表)
- [x] 登录面板 (Cookie 粘贴)
- [x] 播放列表统一本地+云盘

### Phase 3 — 音乐库（借鉴 Strawberry collection/）

| 任务 | 说明 |
|------|------|
| 3.1 | SQLite 持久化（GRDB.swift 迁移） |
| 3.2 | FSEvents 目录监听 + 增量扫描 |
| 3.3 | 元数据读取（AudioToolbox + taglib） |
| 3.4 | 封面提取（嵌入 + 目录） |
| 3.5 | 专辑/艺术家/流派视图 |
| 3.6 | 全文搜索 (FTS5) |
| 3.7 | 智能播放列表规则引擎 |
| 3.8 | 播放历史 + 播放计数 |

### Phase 4 — 无缝播放 + 体验

| 任务 | 说明 |
|------|------|
| 4.1 | 预解码下一曲（双缓冲无缝切换） |
| 4.2 | 自动采样率切换（按曲目） |
| 4.3 | 全局媒体键支持 |
| 4.4 | 菜单栏迷你控制面板 |
| 4.5 | Last.fm / ListenBrainz 听歌记录 |
| 4.6 | 缓存接入播放路径 |

### Phase 5 — 高级功能

| 任务 | 说明 |
|------|------|
| 5.1 | SoXR VHQ 重采样 |
| 5.2 | DAC 能力自动探测 |
| 5.3 | WebDAV/Nextcloud 支持 |
| 5.4 | 歌词显示（在线获取） |
| 5.5 | A/B 对比（DSP vs Bypass） |
| 5.6 | 代码签名 + 公证 + DMG 发布 |

---

## 九、技术栈

| 层级 | 技术 | Strawberry 对比 |
|------|------|---------------|
| **语言** | Swift 6 + C (FFI) | C++ |
| **UI** | AppKit | Qt6 Widgets |
| **音频引擎** | 自建 Pipeline | GStreamer |
| **解码** | AudioToolbox + WAVDecoder | GStreamer 插件 |
| **DSD** | 自建 DoP + DSD2PCM | ❌ |
| **输出** | CoreAudio HAL (Hog Mode) | GStreamer CoreAudio sink |
| **数据库** | SQLite via GRDB.swift | SQLite (直接) |
| **DSP** | IIR Biquad + Gain + Dither | GStreamer EQ 元素 |
| **云盘** | URLSession + Keychain | ❌ |
| **构建** | SPM | CMake |
| **依赖** | swift-atomics (1个) | ~15 个 |
| **最低系统** | macOS 13+ | 无 (跨平台) |

---

## 十、关键设计决策

| # | 决策 | 选择 | Strawberry 做法 | 理由 |
|---|------|------|---------------|------|
| 1 | 音频引擎 | 手写 Pipeline | GStreamer | 完全控制信号路径，无格式协商 |
| 2 | 平台策略 | macOS only | 全平台 | 聚焦做最优 macOS 音频体验 |
| 3 | DSP 默认 | 全部旁路 | 始终开启 | 发烧友追求 bit-perfect |
| 4 | DSD 支持 | DoP + PCM 转换 | 不支持 | 差异化核心卖点 |
| 5 | 依赖策略 | 极简(1个) | 丰富(15+) | 减少体积+维护成本 |
| 6 | 云盘 | 夸克网盘 | Tidal/Qobuz | 服务目标用户（中国发烧友） |
| 7 | UI 哲学 | Vox 极简 | 信息密集 | 先简约，按需展开 |
| 8 | 库管理 | Phase 3 实现 | 核心功能 | 先保证播放纯净再扩展 |
| 9 | 无缝播放 | 预解码策略(规划) | GStreamer 内建 | 必须做，但不牺牲信号纯净 |
| 10 | 封面管理 | 嵌入+目录(规划) | 多源网络获取 | 本地优先，网络可选 |

---

## 十一、当前版本状态（v1.3.x）

### 已实现

- ✅ 音频引擎：FLAC/WAV/ALAC/MP3/AAC/AIFF 解码 + 播放
- ✅ CoreAudio 输出 + Hog Mode + 音量控制
- ✅ DSD/DoP 打包器 + DAC 策略选择
- ✅ DSP: Gain + 10段 Biquad EQ + Crossfeed + Dither
- ✅ 播放模式：顺序/循环/单曲/随机
- ✅ 播放/暂停/上下曲/进度条/音量
- ✅ 夸克网盘：登录 + 目录浏览 + 流式播放 + 加入列表
- ✅ 播放列表：添加/删除/清空/拖拽/双击播放
- ✅ Hi-Fi 状态显示 + 信号路径栏
- ✅ Vox 风格深色 UI + App 图标
- ✅ 84 个自动化测试全通过
- ✅ DMG 打包发布

### 已知待改进（Phase 3+）

- ⚠️ 音乐库仍为 InMemory（无持久化）
- ⚠️ 无缝播放仍有间隙（定时器检测）
- ⚠️ 封面未提取
- ⚠️ 无全局快捷键
- ⚠️ 云盘缓存未接入播放路径
- ⚠️ 无歌词/元数据丰富

---

## 十二、开源参考

| 项目 | 借鉴内容 |
|------|---------|
| **Strawberry** | 模块化架构、智能播放列表、封面管理、无缝播放策略 |
| **VLC** | 模块注册机制、滤波图组装、CoreAudio 监听器 |
| **SFBAudioEngine** | DSD 解码、DoP 打包参考 |
| **AList** | 夸克网盘 API 逆向参考 |
| **Vox Player** | UI 设计语言（封面英雄 + 深色极简） |
| **Audirvana** | Bit-Perfect 理念、内存缓冲、采样率切换 |

---

**文档结束。**
PurePlay v2.0 设计基于 Strawberry 架构分析重构，明确了 "不与 Strawberry 竞争功能数量，而在信号纯净上做到极致" 的产品策略。
