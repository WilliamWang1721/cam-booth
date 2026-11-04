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
        .alert("出错了", isPresented: Binding(get: { camera.errorMessage != nil },
                                            set: { if !$0 { camera.errorMessage = nil } })) {
            Button("好") {}
        } message: {
            Text(camera.errorMessage ?? "")
        }
    }

    private var captureView: some View {
        VStack(spacing: 0) {
            PreviewView(session: camera.session, mirrored: camera.mirrored)
                .background(Color.black)

            HStack {
                Picker("模式", selection: $camera.mode) {
                    ForEach(CameraModel.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
                .disabled(camera.isRecording)

                Spacer()

                Button(action: camera.shutter) {
                    ZStack {
                        Circle().strokeBorder(.secondary, lineWidth: 3).frame(width: 52, height: 52)
                        if camera.mode == .video {
                            RoundedRectangle(cornerRadius: camera.isRecording ? 5 : 20)
                                .fill(.red)
                                .frame(width: camera.isRecording ? 22 : 40, height: camera.isRecording ? 22 : 40)
                        } else {
                            Circle().fill(.white).frame(width: 40, height: 40)
                        }
                    }
                    .animation(.easeInOut(duration: 0.15), value: camera.isRecording)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .help(camera.mode == .photo ? "拍照 (空格)" : (camera.isRecording ? "停止录像 (空格)" : "开始录像 (空格)"))

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
        .toolbar {
            ToolbarItem {
                Picker("摄像头", selection: $camera.selectedID) {
                    ForEach(camera.devices, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                }
                .disabled(camera.isRecording)
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
    }

    /// Hidden by default: the app works without ever opening this.
    private var advancedView: some View {
        Form {
            Picker("分辨率", selection: $camera.quality) {
                ForEach(camera.supportedQualities) { Text($0.rawValue).tag($0) }
            }
            .disabled(camera.isRecording)
            Toggle("镜像画面", isOn: $camera.mirrored)
            Toggle("HEVC 编码（文件更小）", isOn: $camera.useHEVC)
                .disabled(camera.isRecording)
        }
        .formStyle(.grouped)
        .frame(width: 280)
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
