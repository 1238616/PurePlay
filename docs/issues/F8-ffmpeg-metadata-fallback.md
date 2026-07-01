# F8 — FFmpeg metadata 回退（asf / matroska tag + 内嵌封面）

**Milestone**: v1.6
**Depends on**: F1
**Blocks**: 无
**估时**: 1.5 天

## 上下文

`MetadataReader` 现在走 AVFoundation 的 `AVAsset`（`Sources/PurePlayCore/Metadata/MetadataReader.swift:27`）。AVFoundation 在 macOS 13+ **不支持 ASF/WMA** 和 **Matroska/MKA** 容器的元数据解析。

F1 补完 demuxer 后，`.wma` 和 `.mka` 文件能播放，但 library 视图会看到「标题=文件名、艺术家空、专辑空、无封面」，体验断层。

根据 grilling 决策（Q21）：v1.6 同时补 FFmpeg metadata 回退，覆盖基本 tag + 第一张内嵌封面。

## 范围

### 1. 新增 FFmpeg-based 回退

`Sources/PurePlayCore/Metadata/MetadataReader.swift`：

```swift
final class MetadataReader {
    func read(url: URL) -> Metadata {
        let asset = AVAsset(url: url)
        let primary = readFromAVAsset(asset)
        let ext = url.pathExtension.lowercased()
        if primary.isMostlyEmpty && ["wma", "mka"].contains(ext) {
            return readFromFFmpeg(url) ?? primary
        }
        return primary
    }

    private func readFromFFmpeg(_ url: URL) -> Metadata? {
        var fmtCtx: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&fmtCtx, url.path, nil, nil) == 0 else { return nil }
        defer { avformat_close_input(&fmtCtx) }
        guard avformat_find_stream_info(fmtCtx, nil) >= 0 else { return nil }

        var metadata = Metadata()

        // 1. Tag 字典：format.metadata + audio stream.metadata 合并
        let formatDict = fmtCtx!.pointee.metadata
        readDict(formatDict, into: &metadata)
        // 也读 audio stream 的 metadata（matroska 经常把 tag 放在流上）
        for i in 0..<Int(fmtCtx!.pointee.nb_streams) {
            let stream = fmtCtx!.pointee.streams![i]!
            if stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
                readDict(stream.pointee.metadata, into: &metadata)
            }
        }

        // 2. 封面：找 AV_DISPOSITION_ATTACHED_PIC 的 video stream
        for i in 0..<Int(fmtCtx!.pointee.nb_streams) {
            let stream = fmtCtx!.pointee.streams![i]!
            if stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC != 0 {
                let pkt = stream.pointee.attached_pic
                let data = Data(bytes: pkt.data!, count: Int(pkt.size))
                metadata.artwork = data
                break
            }
        }

        return metadata
    }

    private func readDict(_ dict: OpaquePointer?, into metadata: inout Metadata) {
        guard let dict = dict else { return }
        var tag: UnsafeMutablePointer<AVDictionaryEntry>? = nil
        while let entry = av_dict_get(dict, "", tag, AV_DICT_IGNORE_SUFFIX) {
            let key = String(cString: entry.pointee.key).lowercased()
            let value = String(cString: entry.pointee.value)
            switch key {
            case "title":         metadata.title = value
            case "artist":        metadata.artist = value
            case "album":         metadata.album = value
            case "album_artist":  metadata.albumArtist = value
            case "genre":         metadata.genre = value
            case "date", "year":  metadata.creationDate = value
            case "track":         metadata.trackNumber = Int(value.split(separator: "/").first ?? "")
            case "disc":          metadata.discNumber = Int(value.split(separator: "/").first ?? "")
            default: break
            }
            tag = UnsafeMutablePointer(mutating: entry)
        }
    }
}
```

### 2. CFFmpeg 模块需要暴露的符号

确认 `Modules/CFFmpeg/module.modulemap` 已暴露：
- `av_dict_get` / `AVDictionaryEntry`
- `AVFormatContext.metadata`
- `AVStream.disposition` / `AV_DISPOSITION_ATTACHED_PIC`
- `AVStream.attached_pic` (AVPacket)

可能需要补 shim header。

### 3. ReplayGain 标签：v1.6 不实现

`replaygain_track_gain`、`replaygain_album_gain` 等标签 v1.6 不读，等 v1.7+ 决定。

## 验收

- [ ] 一个带 tag 的 WMA 文件，library 视图正确显示 title / artist / album / albumArtist / genre / year
- [ ] 一个带封面的 `.mka` 文件，封面正确显示
- [ ] AVAsset 已能解析的格式（FLAC/MP3/MP4 等）不受影响（短路逻辑：primary 非空就不走回退）
- [ ] 无封面 / 无 tag 的文件不崩溃，metadata 字段保持 nil
- [ ] 多曲库扫描 1000 首文件无 leak（valgrind 或 Instruments）

## 风险

- `av_dict_get` 迭代器需要正确传递上次返回的 entry 作为下次的 prev（已在示例中处理）
- 封面 attached_pic 在某些畸形文件上 `pkt.data == nil`；需要 guard
- ASF 标签字段名可能与示例不同（比如 `WM/AlbumTitle` 而不是 `album`）；F8 实现时需要实测一个真实 WMA 文件，必要时加映射表

## 文件

- `Sources/PurePlayCore/Metadata/MetadataReader.swift`
- `Modules/CFFmpeg/module.modulemap`（可能需补符号）
