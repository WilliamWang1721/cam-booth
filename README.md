# Cam Booth

macOS 原生拍照 / 录像软件，定位是 Photo Booth 的平替：打开即用，高级功能默认收起。

## 设计原则
- **最小必要**：只做拍照、录像、选摄像头；其余收进"高级设置"。
- **高性能靠系统，不靠自己搬帧**：采集、预览、硬件编码（H.264/HEVC）全部交给 AVFoundation / VideoToolbox，帧数据不经过我们的代码。
- **Rust 核心保持很小**：只放不依赖系统的纯逻辑（文件命名、时长格式化），无第三方依赖，C ABI 暴露给 Swift。
- **系统原生**：SwiftUI + 系统组件；MacBook 摄像头的人像 / 居中前台 / 影棚光 / 桌上视角由系统提供，App 里一键打开系统面板。

## 结构
- `core/`：Rust 核心（`cargo test` 可在 Linux 上跑）。
- `app/`：SwiftUI 应用，工程由 XcodeGen 从 `app/project.yml` 生成（不提交 `.xcodeproj`）。
- `.github/workflows/ci.yml`：Linux 上测核心；macOS runner 上编译通用二进制 App 并产出 `CamBooth.zip`。**本机 Mac 不参与构建。**

## 当前功能（v0.1）
照片 / 视频切换、空格快门、摄像头选择（内置、外接、iPhone 连续互通）、720p/1080p/4K（按设备支持）、镜像、HEVC、录制计时、在访达中显示。
文件保存到 `~/Pictures/Cam Booth` 和 `~/Movies/Cam Booth`。

## 状态
Rust 核心已测试通过。Swift 部分**尚未在 macOS 上编译过**，等推送到 GitHub 后由 CI 首次验证。
暂未启用 App Sandbox（保存到用户目录更简单）；上架 App Store 前需要补。
