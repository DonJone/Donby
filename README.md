<p align="center">
  <img src="docs/logo.png" width="96" alt="Donby Logo" />
</p>

<h1 align="center">Donby</h1>

<p align="center">
  专为 macOS (Apple Silicon) 打造的原生高性能媒体播放器与影库客户端
</p>

<p align="center">
  <a href="https://github.com/DonJone/Donby/actions/workflows/build-dmg.yml"><img src="https://github.com/DonJone/Donby/actions/workflows/build-dmg.yml/badge.svg" alt="Build macOS DMG" /></a>
  <a href="https://github.com/DonJone/Donby/releases/latest"><img src="https://img.shields.io/github/v/release/DonJone/Donby?style=flat-square&color=FA2D48" alt="Release" /></a>
  <img src="https://img.shields.io/badge/Platform-macOS%2014%2B%20(Apple%20Silicon)-111827?style=flat-square&logo=apple" alt="Platform" />
  <a href="./LICENSE"><img src="https://img.shields.io/badge/License-AGPL--3.0%20%2B%20Commons%20Clause-4B5563?style=flat-square" alt="License" /></a>
</p>

<p align="center">
  <img src="docs/screenshots/preview.png" width="900" alt="Donby Preview" />
</p>

Donby 是一款基于 **SwiftUI / AppKit + Metal EDR + 自研 C++20 播放内核** 构建的 macOS 原生媒体播放器，覆盖 Emby、Jellyfin、UHDNow、本地媒体目录、网络直链与 IPTV 直播，聚焦 4K HDR/杜比视界直出、极速起播与高帧率桌面交互体验。

## 核心特性

### 播放内核与 HDR 渲染
- **自研 C++20 播放引擎**：基于 FFmpeg、VideoToolbox 硬件解码、AudioToolbox 与 libass 构建，支持 4K HEVC/H.264/AV1 原画硬解与低延迟精准 Seek。
- **Metal EDR 影院级色彩管线**：原生支持 HDR10 与 Dolby Vision (Profile 5 / Profile 8 RPU) 动态范围映射，结合 macOS XDR 屏幕 EDR headroom 独立标定字幕亮度（203 / 250 / 400 nit）。
- **全视口字幕与防遮挡**：字幕支持完整渲染至宽银幕上下黑边区域，控制栏呼出时平滑上移避让；暂停状态下拖动字号/位置滑块实时 60fps 预览。

### 智能字幕与双语对齐
- **Silero VAD 字音自动对齐**：内置开源 Silero VAD 16kHz 语音检测权重（基于 Apple `Accelerate` 原生矩阵加速，零额外 Python/ONNX 运行时依赖），以音轨为绝对基准一键校准偏移字幕。
- **双字幕自动对齐与帧率漂移修正**：自动对齐主/副双语字幕时间偏移及 23.976fps / 25fps 帧率漂移，并结合 VAD 音轨校验防止误拉偏；支持一键撤销。
- **零闪烁同步双语渲染**：统一视频显示时间轴下的时间不变区间预处理，解决异位切分（1 对 2 / 交错翻译）导致的单语挂屏与切换闪烁，配合三缓冲 Metal 字幕纹理消除 120Hz ProMotion 残影。
- **多格式与编码兼容**：支持内嵌/外挂 ASS、SSA、SRT、PGS 字幕，自动识别 UTF-8 / GB18030 编码，内置简繁转换、苹方/影院橙金双语样式增强及按剧集记忆字幕偏好。

### Turbo 并发流媒体与离线影库
- **Turbo 多连接分片缓存引擎**：HTTP/2 自适应并发 Range 分片拉取，配合 L1 内存 + L2 磁盘持久化分片缓存与 302 重定向缓存，大幅降低 4K Remux 起播与拖进度条耗时。
- **详情页预读与连播预取**：可选按续播进度或片头跳过落点后台预加载码流，剧集临近结尾静默预取下一集，支持按季记忆片头/片尾跳过与自动连播。
- **统一离线影库**：完整缓存可自动归档至 `~/Movies/Donby`，离线状态下仍保留完整剧集分组、海报、演职员与观看进度同步。

### 原生 macOS 界面与安全体验
- **Liquid Glass 设计与 120Hz 浏览**：首页与海报网格采用原生 AppKit `NSCollectionView` + `CALayer` + 异步 ImageIO 硬件降采样，支持浅色、深色与纯黑白极简主题，全屏与窗口自适应构图。
- **无弹窗加密凭据库**：使用基于设备硬件 UUID 派生的 HKDF-SHA256 + AES-256-GCM 本地加密保险库（`0600` 权限）存储服务器凭据，彻底告别每次版本更新弹出 macOS 钥匙串密码确认框。
- **内置自动更新**：支持 Stable（正式版）与 Pre-release（预览版）双通道检测、SHA-256 校验与一键原地更新重启。

## 架构概览

| 模块 | 技术栈 | 职责 |
| :--- | :--- | :--- |
| `DonbyApp` | SwiftUI + AppKit | 主窗口、120Hz 媒体库浏览、详情页、播放器控制与 Liquid Glass UI |
| `DonbyMetalRenderer` | Metal + CVDisplayLink | EDR 线性渲染、HDR10/DoVi 色调映射、三缓冲字幕叠层、GPU 截帧 |
| `DonbyKernelC` | C++20 + FFmpeg + VideoToolbox + libass | 解封装、硬解、音画同步、16kHz VAD 音频环、双语字幕排版与渲染 |
| `DonbyNetwork` | Swift Concurrency + URLSession | Emby / Jellyfin / UHDNow 客户端、Turbo 分片缓存、离线库与自动更新 |
| `DonbyCore` | Swift + Accelerate | 核心模型、Silero VAD 与字幕对齐引擎、AES-256-GCM 凭据库、日志脱敏 |

## 下载与安装

前往 [GitHub Releases](https://github.com/DonJone/Donby/releases) 下载最新正式版 DMG 安装包，打开后将 `Donby.app` 拖入 `Applications` 目录即可。

> 若首次启动提示来自未识别开发者，可在终端执行：
> ```bash
> sudo xattr -rd com.apple.quarantine /Applications/Donby.app
> ```

## 快捷键

| 快捷键 | 功能 |
| :--- | :--- |
| `Space` | 播放 / 暂停 |
| `Left` / `Right` | 快退 / 快进 10 秒 |
| `Up` / `Down` | 调节音量 |
| `F` | 切换全屏 |
| `L` | 打开实时运行日志 |
| `Esc` | 退出播放 |
| `Cmd + L` / `Cmd + R` | 切换服务器线路 / 刷新首页 |

## 源码构建与开发

确保已安装 macOS Command Line Tools（Swift 6+）及 Homebrew 依赖：

```bash
brew install ffmpeg libass
```

克隆仓库后可使用内置开发与打包脚本：

```bash
git clone https://github.com/DonJone/Donby.git
cd Donby

# 快速增量调试编译
./scripts/dev.sh build

# 运行隔离环境核心单元测试 (DonbyCoreTests)
./scripts/dev.sh test

# 构建独立 Release App Bundle (自动捆绑 dylib、Silero VAD 权重并签名)
./build_app.sh
```

## 致谢

- 音视频解封装、解码与字幕渲染基于 [FFmpeg](https://ffmpeg.org/) 与 [libass](https://github.com/libass/libass)。
- 语音端点检测模型基于开源 MIT 协议的 [Silero VAD](https://github.com/snakers4/silero-vad)。
- 界面美学与交互体验汲取了 Apple TV、SenPlayer 与 Infuse 的设计灵感。

## License

Copyright © 2026 [DonJone](https://github.com/DonJone). Released under the [GNU AGPL-3.0 with Commons Clause v1.0](./LICENSE).
