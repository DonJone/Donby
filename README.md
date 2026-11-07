<p align="center">
  <img src="docs/logo.png" width="108" alt="Donby Logo" />
</p>

<h1 align="center">Donby</h1>

<p align="center">
  专为 macOS 打造的原生 Emby / UHDNow 4K HDR 播放器
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2014%2B-111827?style=flat-square&logo=apple" alt="Platform" />
  <img src="https://img.shields.io/badge/Renderer-Metal%20%2B%20VideoToolbox-0A84FF?style=flat-square" alt="Metal" />
  <img src="https://img.shields.io/badge/Protocol-Emby%20%2F%20UHDNow-00C2FF?style=flat-square" alt="Protocol" />
  <img src="https://img.shields.io/badge/License-AGPL--3.0%20%2B%20Commons%20Clause-D97706?style=flat-square" alt="License" />
</p>

---

## 界面预览

<p align="center">
  <img src="docs/screenshots/uhd-preview.png" width="920" alt="Donby macOS Preview" />
</p>

---

## 核心特性

- **UHDNow 生态原生支持**：深度对接 [`emby_ext_domains`](https://github.com/uhdnow/emby_ext_domains)（`ServerDomains` 扩展接口），登录后自动拉取全部云端加速节点，支持并发延迟测速、秒级无阻塞切线与最优节点自动优选。
- **开箱即用空槽与剪贴板识别**：默认预置干净的 `UHDNow` 待配置空槽（不含任何演示数据），支持点击直接填写或从剪贴板一键解析导入服务器地址、端口、账号与备用线路。
- **macOS 原生硬解与 Metal 渲染**：
  - 基于 `VideoToolbox` 硬件加速解码与 `CAMetalLayer` 直出渲染（支持 8-bit `NV12`、10-bit `P010` BT.2020 HDR 及 `BGRA` 管线）。
  - 基于 `AudioToolbox`（`AudioQueue`）硬件采样计数主时钟实现高精度音画同步，支持 `libass` 字幕解析与多音轨/多字幕实时切换。
- **原画 302 直连播放**：自动解析 Emby `PlaybackInfo` 与 302 重定向原画直链，实时同步服务端播放进度、续播断点与观看历史。
- **多源媒体管理**：统一支持 Emby / UHDNow / Jellyfin 媒体库、本地大码率视频文件直解以及 M3U IPTV 频道播放。

---

## 环境依赖与编译打包

### 1. 系统与依赖要求
- **macOS 14.0+**（推荐 Apple Silicon）
- Xcode Command Line Tools（Swift 5.10+ / Clang C++20）
- Rust 工具链（`cargo`，用于编译底层环形缓存与 DoVi 元数据解析模块）
- Homebrew 依赖库：

```bash
brew install ffmpeg libass
```

### 2. 一键编译并打包 `Donby.app`

```bash
git clone https://github.com/DonJone/Donby.git
cd Donby
./build_app.sh
```

脚本会自动完成：
1. 编译 `KernelRust` 与 `DonbyKernelC` 静态库（`./build_kernel.sh`）
2. 构建 Release 版 Swift 二进制并生成原生高清 `AppIcon.icns`
3. 组装并签名输出 `./Donby.app`

---

## 目录结构

```text
Donby/
├── KernelRust/                 # Rust 滑动内存池与 Dolby Vision RPU/FEL 检测
├── Sources/
│   ├── DonbyKernelC/           # C++20 解封装、VideoToolbox 硬解、AudioQueue 时钟与线程管理
│   ├── DonbyMetalRenderer/     # CAMetalLayer YUV/P010 着色器与 CVDisplayLink 驱动
│   ├── DonbyCore/              # 数据模型、剪贴板线路解析器与运行日志系统
│   ├── DonbyNetwork/           # Emby / UHDNow API、ServerDomains 同步与 302 直链解析
│   ├── DonbyStorage/           # Keychain 安全凭据存储
│   └── DonbyApp/               # 原生 macOS SwiftUI 界面与播放器交互层
├── scripts/generate_icon.swift # macOS 应用图标生成脚本
├── build_kernel.sh             # 原生播放内核构建脚本
└── build_app.sh                # Donby.app 完整构建与签名脚本
```

---

## License

Copyright © 2026 [DonJone](https://github.com/DonJone). Released under the [GNU AGPL-3.0 with Commons Clause v1.0](./LICENSE).
