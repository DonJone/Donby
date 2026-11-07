<p align="center">
  <img src="docs/logo.png" width="108" alt="Donby Logo" />
</p>

<h1 align="center">Donby</h1>

<p align="center">
  专为 macOS 打造的原生 Emby / UHDNow 4K HDR 播放器
</p>

<p align="center">
  <a href="https://github.com/DonJone/Donby/actions/workflows/build-dmg.yml"><img src="https://github.com/DonJone/Donby/actions/workflows/build-dmg.yml/badge.svg" alt="Build macOS DMG" /></a>
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
  - 基于 `VideoToolbox` 硬件加速解码（含 `IOSurface` 10-bit 软解无缝回退）与 `.rgba16Float` `extendedLinearDisplayP3` 广色域 EDR 管线。
  - 完整支持 **Dolby Vision（Profile 5 / Profile 8 动态 RPU 矩阵与多项式/MMR 重塑）**、**HDR10（SMPTE ST 2084 PQ）**、**HLG** 以及 **ITU-R BT.2390** 自适应色调映射与等亮度色域压缩。
  - 基于 `AudioToolbox`（`AudioQueue`）硬件采样计数主时钟实现高精度音画同步（兼容 TrueHD Atmos 7.1 下混），支持内封/外挂 `ASS/SSA`、`SRT` 与蓝光 `PGS` 位图字幕渲染及实时切换。
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
3. 自动递归收集并内嵌 `FFmpeg` / `libass` 动态库至 `Contents/Frameworks`（脱离本机 Homebrew 独立运行）
4. 组装并签名输出 `./Donby.app`

### 3. 打包可分发的 `.dmg` 安装镜像

```bash
./scripts/package_dmg.sh
```

执行后将在 `dist/` 目录下生成带 `Applications` 拖拽引导的自包含压缩镜像 `Donby-<version>-macOS-<arch>.dmg` 及 `SHA256SUMS.txt`。

> **CI 自动构建与发布**：仓库已内置 GitHub Actions 工作流（[`.github/workflows/build-dmg.yml`](./.github/workflows/build-dmg.yml)）。每次推送 `main` 分支或手动触发均会自动产出 `.dmg` 构建产物；推送 `v*` 标签（如 `git tag v1.1.0 && git push origin v1.1.0`）将自动创建 GitHub Release 并挂载 `.dmg` 安装包。

---

## 目录结构

```text
Donby/
├── .github/workflows/          # GitHub Actions 自动编译与 DMG 打包发布工作流
├── KernelRust/                 # Rust 滑动内存池与 Dolby Vision RPU/FEL 检测
├── Sources/
│   ├── DonbyKernelC/           # C++20 解封装、VideoToolbox 硬解、AudioQueue 时钟与线程管理
│   ├── DonbyMetalRenderer/     # CAMetalLayer YUV/P010 着色器与 CVDisplayLink 驱动
│   ├── DonbyCore/              # 数据模型、剪贴板线路解析器与运行日志系统
│   ├── DonbyNetwork/           # Emby / UHDNow API、ServerDomains 同步与 302 直链解析
│   ├── DonbyStorage/           # Keychain 安全凭据存储
│   └── DonbyApp/               # 原生 macOS SwiftUI 界面与播放器交互层
├── scripts/generate_icon.swift # macOS 应用图标生成脚本
├── scripts/bundle_dylibs.py    # 第三方动态库递归收集与 @rpath 重写脚本
├── scripts/package_dmg.sh      # macOS DMG 安装镜像打包与校验脚本
├── build_kernel.sh             # 原生播放内核构建脚本
└── build_app.sh                # Donby.app 完整构建与签名脚本
```

---

## 致谢与设计灵感 (Acknowledgements)

- **开源基础组件**：底层媒体解封装、软解回退与字幕排版构建于优秀的开源项目 [FFmpeg](https://ffmpeg.org/) 与 [libass](https://github.com/libass/libass) 之上；云端多线路动态同步对接了 [uhdnow/emby_ext_domains](https://github.com/uhdnow/emby_ext_domains) 协议规范。
- **UI / UX 设计致敬**：Donby 在 macOS 桌面端的媒体库浏览动线、胶囊工具栏与磨砂悬浮控制栏等部分交互视觉细节上，借鉴并致敬了 **SenPlayer**、**Infuse** 以及 **Apple TV** 的优秀设计语言，特此向相关独立开发者与设计团队致以敬意。如果您需要在 iOS / iPadOS / tvOS / macOS 全家桶获得开箱即用的成熟商业客户端体验，非常推荐购买并支持正版 SenPlayer 或 Infuse。
- **独立实现声明**：本项目全部前后端代码、纯代码矢量图形与 C++20 / Rust / Metal 播放渲染内核均由作者独立从零编写（Clean-room implementation），未包含任何第三方商业软件的专有代码、拆包文件或商标资源，且与 SenPlayer、Infuse、Emby 官方不存在任何隶属、合作或背书关系。

---

## License

Copyright © 2026 [DonJone](https://github.com/DonJone). Released under the [GNU AGPL-3.0 with Commons Clause v1.0](./LICENSE).
