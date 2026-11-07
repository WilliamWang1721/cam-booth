import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraModel()
    @State private var showAdvanced = false

    var body: some View {
        Group {
            switch camera.authorized {
            case .none:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .some(false):
                deniedView
            case .some(true):
                captureView
            }
        }
        .task { camera.start() }
        .onDisappear { camera.stop() }
        .onTapGesture { camera.touch() }
        .toolbar {
            ToolbarItem {
                Picker("摄像头", selection: $camera.selectedID) {
                    ForEach(camera.devices, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                }
                .disabled(camera.isRecording || camera.isSuspended)
            }
            ToolbarItem {
                Button("摄像头效果", systemImage: "person.crop.rectangle", action: camera.showSystemEffects)
                    .help("人像、居中前台、影棚光、桌上视角等系统效果")
            }
            ToolbarItem {
                Button("高级设置", systemImage: "slider.horizontal.3") { showAdvanced.toggle() }
                    .popover(isPresented: $showAdvanced, arrowEdge: .bottom) { advancedView }
            }
        }
        .alert("出错了", isPresented: Binding(get: { camera.errorMessage != nil },
                                            set: { if !$0 { camera.errorMessage = nil } })) {
            Button("好") {}
        } message: {
            Text(camera.errorMessage ?? "")
        }
    }

    private var captureView: some View {
        VStack(spacing: 0) {
            if camera.isSuspended {
                suspendedView
            } else {
                PreviewView(session: camera.session, mirrored: camera.mirrored)
                    .background(Color.black)
                    .overlay(alignment: .center) {
                        if camera.countdownRemaining > 0 { countdownOverlay }
                    }
            }

            if !camera.recent.isEmpty {
                RecentStrip(items: camera.recent,
                            open: { camera.open($0) },
                            reveal: { camera.reveal($0) },
                            trash: { camera.trash($0) },
                            share: { camera.share($0) })
            }

            controlBar
        }
    }

    private var suspendedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "moon.zzz.fill").font(.largeTitle).foregroundStyle(.secondary)
            Text("相机已自动休眠").font(.headline)
            Text("长时间未操作，摄像头已关闭以节省资源。")
                .foregroundStyle(.secondary)
            Button("唤醒相机") { camera.wakeFromIdle() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.space, modifiers: [])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .foregroundStyle(.white)
    }

    private var countdownOverlay: some View {
        VStack(spacing: 8) {
            Text("\(camera.countdownRemaining)")
                .font(.system(size: 130, weight: .thin, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 14)
            Text("按空格取消")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
        }
        .allowsHitTesting(false)
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Picker("模式", selection: $camera.mode) {
                ForEach(CameraModel.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 120)
            .disabled(camera.isBusy || camera.isSuspended)

            Button { camera.mirrored.toggle() } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .foregroundStyle(camera.mirrored ? Color.accentColor : Color.secondary)
            .help(camera.mirrored ? "镜像：开（预览与存盘都镜像）" : "镜像：关")

            Menu {
                Picker("倒计时", selection: $camera.countdownSeconds) {
                    ForEach(CameraModel.countdownChoices, id: \.self) { seconds in
                        Text(seconds == 0 ? "直接开始" : "\(seconds) 秒").tag(seconds)
                    }
                }
            } label: {
                Label(camera.countdownSeconds == 0 ? "无倒计时" : "\(camera.countdownSeconds) 秒",
                      systemImage: "timer")
            }
            .fixedSize()
            .disabled(camera.isBusy)
            .help("倒计时：拍照片和录像前都倒数")

            // Quick share for the most recent capture.
            if let last = camera.recent.first {
                Button { camera.share(last) } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("分享最近的一张/段（系统分享面板：邮件、信息、AirDrop、微信等）")
                .disabled(camera.isRecording)
            }

            Spacer()

            Button(action: camera.shutter) {
                ZStack {
                    Circle().strokeBorder(.secondary, lineWidth: 3).frame(width: 52, height: 52)
                    if camera.mode == .video {
                        RoundedRectangle(cornerRadius: camera.isRecording ? 5 : 20)
                            .fill(.red)
                            .frame(width: camera.isRecording ? 22 : 40, height: camera.isRecording ? 22 : 40)
                    } else if camera.countdownRemaining > 0 {
                        Circle().fill(.orange).frame(width: 40, height: 40)
                    } else {
                        Circle().fill(.white).frame(width: 40, height: 40)
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: camera.isRecording)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .help(shutterHelp)

            Spacer()

            HStack(spacing: 8) {
                if camera.isRecording {
                    Text(camera.elapsed).monospacedDigit().foregroundStyle(.red)
                } else if camera.lastSaved != nil {
                    Button("在访达中显示", systemImage: "folder", action: camera.revealLastSaved)
                        .labelStyle(.iconOnly)
                        .help("在访达中显示最近的文件")
                }
            }
            .frame(width: 120, alignment: .trailing)
        }
        .padding(12)
    }

    private var shutterHelp: String {
        if camera.isSuspended { return "唤醒相机 (空格)" }
        if camera.countdownRemaining > 0 { return "取消倒计时 (空格)" }
        switch camera.mode {
        case .photo: return camera.countdownSeconds > 0
            ? "倒计时后拍照 (空格)" : "拍照 (空格)"
        case .video:
            if camera.isRecording { return "停止录像 (空格)" }
            return camera.countdownSeconds > 0 ? "倒计时后开始录像 (空格)" : "开始录像 (空格)"
        }
    }

    /// Hidden by default: the app works without ever opening this.
    private var advancedView: some View {
        Form {
            Picker("分辨率", selection: $camera.quality) {
                ForEach(camera.supportedQualities) { Text($0.rawValue).tag($0) }
            }
            .disabled(camera.isRecording)
            Toggle("HEVC 编码（文件更小）", isOn: $camera.useHEVC)
                .disabled(camera.isRecording)

            Picker("视频格式", selection: $camera.videoFormat) {
                ForEach(VideoFormat.allCases) { Text($0.label).tag($0) }
            }
            .disabled(camera.isRecording)
            Text("MOV 为硬件直录；其它格式录完后用系统 avconvert 转码，文件名后缀随之变化。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Section("麦克风") {
                if camera.micDevices.isEmpty {
                    Text("未检测到麦克风（或未授予麦克风权限）。")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("输入设备", selection: Binding(
                        get: { camera.selectedMicID },
                        set: { camera.selectMic($0) })) {
                        ForEach(camera.micDevices, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                        Text("无麦克风（静音录像）").tag(nil as String?)
                    }
                    .disabled(camera.isRecording)
                    if camera.micGainAvailable {
                        LabeledContent("输入电平") {
                            HStack {
                                Slider(value: Binding(
                                    get: { camera.micGain },
                                    set: { camera.setMicGain($0) }),
                                    in: 0...1, step: 0.05)
                                    .frame(width: 140)
                                Text("\(Int(camera.micGain * 100))%")
                                    .monospacedDigit()
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }
                        .disabled(camera.isRecording)
                    } else if camera.selectedMicID != nil {
                        Text("此设备不支持在 App 内调节音量，请在 系统设置 → 声音 中调整。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("相机休眠") {
                Picker("无操作后自动休眠", selection: $camera.sleepAfterSeconds) {
                    Text("从不").tag(0)
                    Text("1 分钟").tag(60)
                    Text("2 分钟").tag(120)
                    Text("5 分钟").tag(300)
                }
                .disabled(camera.isRecording)
                Text("休眠会停止摄像头采集以节省资源；点击画面或按钮随时唤醒。录像中不会休眠。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("保存位置") {
                HStack(spacing: 6) {
                    Text(camera.saveDirectoryHint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("选择…") {
                        if SaveLocation.choose() != nil { camera.refreshSaveLocation() }
                    }
                    if SaveLocation.isCustom {
                        Button("下载文件夹") {
                            SaveLocation.resetToDownloads()
                            camera.refreshSaveLocation()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .padding(.vertical, 4)
    }

    private var deniedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill").font(.largeTitle).foregroundStyle(.secondary)
            Text("Cam Booth 没有摄像头权限").font(.headline)
            Text("请在 系统设置 → 隐私与安全性 → 相机 中允许 Cam Booth。")
                .foregroundStyle(.secondary)
            Button("打开系统设置") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
