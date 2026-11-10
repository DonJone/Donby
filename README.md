<p align="center">
  <img src="docs/logo.png" width="96" alt="Donby Logo" />
</p>

<h1 align="center">Donby</h1>

<p align="center">
  专为 macOS 打造的原生媒体播放器
</p>

<p align="center">
  <a href="https://github.com/DonJone/Donby/actions/workflows/build-dmg.yml"><img src="https://github.com/DonJone/Donby/actions/workflows/build-dmg.yml/badge.svg" alt="Build macOS DMG" /></a>
  <a href="https://github.com/DonJone/Donby/releases"><img src="https://img.shields.io/github/v/release/DonJone/Donby?style=flat-square&color=FA2D48" alt="Release" /></a>
  <img src="https://img.shields.io/badge/Platform-macOS%2014%2B-111827?style=flat-square&logo=apple" alt="Platform" />
  <a href="./LICENSE"><img src="https://img.shields.io/badge/License-AGPL--3.0%20%2B%20Commons%20Clause-4B5563?style=flat-square" alt="License" /></a>
</p>

<p align="center">
  <img src="docs/screenshots/preview.png" width="900" alt="Donby Preview" />
</p>

Donby 是一款为 macOS 设计的原生流媒体与本地播放器，支持连接 Emby、Jellyfin 服务器与本地媒体库，提供流畅的硬件解码播放和原生系统交互体验。

## 主要特性

- **原生界面设计**：深度适配 macOS，提供浅色、深色与纯黑白极简主题，支持触控板手势滑动等原生交互。
- **多源媒体接入**：原生支持 Emby、Jellyfin 与本地文件夹，自动识别剧集季集信息并同步播放进度。
- **硬件加速播放**：基于 VideoToolbox 硬件解码与 Metal 渲染，流畅支持 4K HDR、Dolby Vision 及主流视频编码。
- **多格式字幕与音轨**：支持 ASS/SSA、SRT、PGS 等内嵌与外挂字幕实时切换，多音轨无缝选择。

## 下载与安装

前往 [Releases](https://github.com/DonJone/Donby/releases) 下载最新 DMG 安装包，打开后将 `Donby.app` 拖移至 `Applications` 目录即可。

> 若首次打开提示未受信任，可在终端执行以下命令解除限制：
> ```bash
> sudo xattr -rd com.apple.quarantine /Applications/Donby.app
> ```

## 源码构建

确保已安装 Xcode 命令行工具及依赖：

```bash
brew install ffmpeg libass
```

克隆并编译：

```bash
git clone https://github.com/DonJone/Donby.git
cd Donby
./build_app.sh
```

## 致谢

- 媒体解封装与字幕渲染基于 [FFmpeg](https://ffmpeg.org/) 与 [libass](https://github.com/libass/libass)。
- 视觉设计与交互体验致敬了 Apple TV、SenPlayer 与 Infuse。

## License

Copyright © 2026 [DonJone](https://github.com/DonJone). Released under the [GNU AGPL-3.0 with Commons Clause v1.0](./LICENSE).
