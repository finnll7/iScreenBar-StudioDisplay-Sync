import SwiftUI

// MARK: - 数据快照与动作（由 AppKit 侧填充，SwiftUI 只负责呈现）

struct PresenceDelayOption: Identifiable, Equatable {
    let id: Int
    let label: String
}

struct PanelSnapshot: Equatable {
    var standbyNote: String?
    var lampConnected = false

    var powerOn = false
    var brightness: Double = 60
    var brightnessText = "--%"
    var temperature: Double = 4500
    var temperatureText = "----K"

    var autoLightOn = false
    var autoLightTitle = "自动感光"
    var autoLightEnabled = true
    var presenceOn = false
    var presenceTitle = "入座检测"
    var presenceEnabled = true
    var videoOn = false
    var brightnessFollowOn = false
    var brightnessFollowEnabled = true
    var powerSyncOn = true
    var timeTemperatureOn = false
    var timeTemperatureEnabled = true
    var displayLockOn = false
    var displayLockEnabled = false
    var keepAwakeOn = false
    var readingModeOn = false
    var comboOn = false
    var comboStatus = ""

    var presenceDelay = 180
    var presenceDelayOptions: [PresenceDelayOption] = []
    var presenceSensitivity = 2

    var ambientCloseText = "--"
    var ambientOpenText = "--"
    var ambientStatus = ""
    var ambientRulesOn = false
    var ambientRulesEnabled = false
    var ambientFieldsEnabled = true
    var captureEnabled = false

    var builtinOn = false
    var builtinEnabled = false
    var rotateTitle = "旋转 —"
    var rotateEnabled = false
    var studioOn = false
    var studioEnabled = false
    var displayAutoPresetOn = false
    var displayAutoPresetEnabled = false

    var modeTitle = "我的最爱"
    var modeItems: [String] = []
    var rotationTitle = "竖屏双屏"
    var bindTitle = "绑定应用"
    var version = ""
}

struct PanelActions {
    var setPower: (Bool) -> Void = { _ in }
    var setBrightness: (Double) -> Void = { _ in }
    var brightnessEditing: (Bool) -> Void = { _ in }
    var setTemperature: (Double) -> Void = { _ in }
    var temperatureEditing: (Bool) -> Void = { _ in }
    var setAutoLight: (Bool) -> Void = { _ in }
    var setPresence: (Bool) -> Void = { _ in }
    var setPresenceDelay: (Int) -> Void = { _ in }
    var setPresenceSensitivity: (Int) -> Void = { _ in }
    var setVideoMode: (Bool) -> Void = { _ in }
    var setBrightnessFollow: (Bool) -> Void = { _ in }
    var setPowerSync: (Bool) -> Void = { _ in }
    var setTimeTemperature: (Bool) -> Void = { _ in }
    var setDisplayLock: (Bool) -> Void = { _ in }
    var setKeepAwake: (Bool) -> Void = { _ in }
    var setReadingMode: (Bool) -> Void = { _ in }
    var setCombo: (Bool) -> Void = { _ in }
    var captureClose: () -> Void = {}
    var captureOpen: () -> Void = {}
    var commitClose: (String) -> Void = { _ in }
    var commitOpen: (String) -> Void = { _ in }
    var setAmbientRules: (Bool) -> Void = { _ in }
    var setBuiltin: (Bool) -> Void = { _ in }
    var rotateBuiltin: () -> Void = {}
    var setStudio: (Bool) -> Void = { _ in }
    var setDisplayAutoPreset: (Bool) -> Void = { _ in }
    var applyMode: (Int) -> Void = { _ in }
    var showModeCenter: () -> Void = {}
    var bindCurrentApp: () -> Void = {}
    var applyRotationPreset: () -> Void = {}
    var saveRotationPreset: () -> Void = {}
    var toggleRotationAutomation: () -> Void = {}
    var quit: () -> Void = {}
}

final class PanelModel: ObservableObject {
    @Published var snapshot = PanelSnapshot()
    @Published var actions = PanelActions()
}

// MARK: - 玻璃容器

private struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.tint(.white.opacity(0.06)), in: .rect(cornerRadius: 20))
                .overlay(specularBorder(cornerRadius: 20))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(specularBorder(cornerRadius: 20))
        }
    }
}

/// 玻璃边缘的镜面高光：左上亮、右下暗，制造厚度感。
private func specularBorder(cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .strokeBorder(
            LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08), .white.opacity(0.28)],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing),
            lineWidth: 0.9
        )
        .allowsHitTesting(false)
}

private extension View {
    func glassCard() -> some View { modifier(GlassCard()) }
}

// MARK: - 面板主体

struct GlassPanelView: View {
    @ObservedObject var model: PanelModel

    @State private var brightnessLocal: Double = 60
    @State private var temperatureLocal: Double = 4500
    @State private var closeText = ""
    @State private var openText = ""

    private var snapshot: PanelSnapshot { model.snapshot }
    private var actions: PanelActions { model.actions }

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            panelContent
        }
        .frame(width: 372, height: 720)
        .background(panelBackdrop)
    }

    /// 很淡的双色渐变：给玻璃提供可折射的内容，否则玻璃看起来像普通灰块。
    private var panelBackdrop: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.16), Color.clear, Color.blue.opacity(0.10)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var panelContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let note = snapshot.standbyNote {
                    Label(note, systemImage: "display.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard()
                }
                quickControls
                if snapshot.comboOn, !snapshot.comboStatus.isEmpty {
                    Text(snapshot.comboStatus)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                lighting
                ambient
                presenceSettings
                displaySection
                presets
                systemSection
            }
            .padding(16)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("iScreen Menu")
                .font(.system(size: 17, weight: .semibold))
            Text("屏幕与灯光控制")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var quickControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("快捷控制")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                toggle("灯光", "power", snapshot.powerOn, snapshot.lampConnected, actions.setPower)
                toggle(snapshot.autoLightTitle, "sun.max", snapshot.autoLightOn, snapshot.autoLightEnabled, actions.setAutoLight)
                toggle(snapshot.presenceTitle, "figure.seated.side", snapshot.presenceOn, snapshot.presenceEnabled, actions.setPresence)
                toggle("视频模式", "video", snapshot.videoOn, snapshot.lampConnected, actions.setVideoMode)
                toggle("亮度跟随", "display", snapshot.brightnessFollowOn, snapshot.brightnessFollowEnabled, actions.setBrightnessFollow)
                toggle("熄屏同步", "moon.zzz", snapshot.powerSyncOn, snapshot.lampConnected, actions.setPowerSync)
                toggle("自动色温", "circle.lefthalf.filled", snapshot.timeTemperatureOn, snapshot.timeTemperatureEnabled, actions.setTimeTemperature)
                toggle("双屏亮度", "rectangle.on.rectangle", snapshot.displayLockOn, snapshot.displayLockEnabled, actions.setDisplayLock)
                toggle("阅读模式", "book", snapshot.readingModeOn, snapshot.lampConnected, actions.setReadingMode)
                toggle("智能组合", "wand.and.stars", snapshot.comboOn, snapshot.lampConnected, actions.setCombo)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var lighting: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("灯光调节")
            labeledSlider("sun.max", "亮度", value: $brightnessLocal, range: 1...100, text: snapshot.brightnessText) { editing in
                actions.brightnessEditing(editing)
            } onChange: { value in
                actions.setBrightness(value)
            }
            labeledSlider("thermometer.medium", "色温", value: $temperatureLocal, range: 2700...6500, text: snapshot.temperatureText) { editing in
                actions.temperatureEditing(editing)
            } onChange: { value in
                actions.setTemperature(value)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .onAppear {
            brightnessLocal = snapshot.brightness
            temperatureLocal = snapshot.temperature
        }
        .onChange(of: snapshot.brightness) { _, newValue in
            if abs(newValue - brightnessLocal) > 0.5, !isDraggingBrightness { brightnessLocal = newValue }
        }
        .onChange(of: snapshot.temperature) { _, newValue in
            if abs(newValue - temperatureLocal) > 0.5, !isDraggingTemperature { temperatureLocal = newValue }
        }
    }

    @State private var isDraggingBrightness = false
    @State private var isDraggingTemperature = false

    private var ambient: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                sectionTitle("环境光标定")
                Spacer()
                Text("启用")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Toggle("", isOn: Binding(get: { snapshot.ambientRulesOn }, set: { actions.setAmbientRules($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(!snapshot.ambientRulesEnabled)
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("明亮关灯")
                        .font(.system(size: 11.5))
                        .frame(width: 62, alignment: .leading)
                    TextField("--", text: $closeText)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.center)
                        .disabled(!snapshot.ambientFieldsEnabled)
                        .onSubmit { actions.commitClose(closeText) }
                    Button("采集") { actions.captureClose() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!snapshot.captureEnabled)
                }
                GridRow {
                    Text("昏暗开灯")
                        .font(.system(size: 11.5))
                        .frame(width: 62, alignment: .leading)
                    TextField("--", text: $openText)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.center)
                        .disabled(!snapshot.ambientFieldsEnabled)
                        .onSubmit { actions.commitOpen(openText) }
                    Button("采集") { actions.captureOpen() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!snapshot.captureEnabled)
                }
            }
            .onAppear {
                closeText = snapshot.ambientCloseText
                openText = snapshot.ambientOpenText
            }
            .onChange(of: snapshot.ambientCloseText) { _, newValue in closeText = newValue }
            .onChange(of: snapshot.ambientOpenText) { _, newValue in openText = newValue }
            Text(snapshot.ambientStatus)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var presenceSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("入座检测设置")
            HStack(spacing: 8) {
                pickerCell("离席时间") {
                    Picker("", selection: Binding(get: { snapshot.presenceDelay }, set: { actions.setPresenceDelay($0) })) {
                        ForEach(snapshot.presenceDelayOptions) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                }
                pickerCell("灵敏度") {
                    Picker("", selection: Binding(get: { snapshot.presenceSensitivity }, set: { actions.setPresenceSensitivity($0) })) {
                        Text("低").tag(0)
                        Text("中").tag(1)
                        Text("高").tag(2)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("显示屏与旋转")
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    toggleCell("内屏", "display", snapshot.builtinOn, snapshot.builtinEnabled, actions.setBuiltin)
                    toggleCell("Studio Display", "display.2", snapshot.studioOn, snapshot.studioEnabled, actions.setStudio)
                }
                GridRow {
                    Button {
                        actions.rotateBuiltin()
                    } label: {
                        Label(snapshot.rotateTitle, systemImage: "arrow.clockwise")
                            .font(.system(size: 11.5))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!snapshot.rotateEnabled)
                    .frame(maxWidth: .infinity)
                    toggleCell("自动预设", "arrow.triangle.2.circlepath", snapshot.displayAutoPresetOn, snapshot.displayAutoPresetEnabled, actions.setDisplayAutoPreset)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("预设")
            HStack(spacing: 8) {
                Menu {
                    ForEach(Array(snapshot.modeItems.enumerated()), id: \.offset) { index, title in
                        Button(title) { actions.applyMode(index) }
                    }
                    Divider()
                    Button("模式中心设置…") { actions.showModeCenter() }
                } label: {
                    Label(snapshot.modeTitle, systemImage: "heart")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)

                Button {
                    actions.bindCurrentApp()
                } label: {
                    Label(snapshot.bindTitle, systemImage: "app.badge")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            HStack(spacing: 8) {
                Menu {
                    Button("应用当前旋转预设") { actions.applyRotationPreset() }
                    Button("保存当前为旋转预设…") { actions.saveRotationPreset() }
                    Divider()
                    Button(snapshot.displayAutoPresetOn ? "关闭连接自动启用" : "连接 Studio Display 时自动启用") {
                        actions.toggleRotationAutomation()
                    }
                } label: {
                    Label(snapshot.rotationTitle, systemImage: "rectangle.portrait.rotate")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                toggleCell("防止休眠", "cup.and.saucer", snapshot.keepAwakeOn, true, actions.setKeepAwake)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var systemSection: some View {
        HStack(spacing: 8) {
            Text(snapshot.version)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                actions.quit()
            } label: {
                Label("退出应用", systemImage: "power")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.horizontal, 4)
    }

    private func pickerCell<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggleCell(_ title: String, _ symbol: String, _ isOn: Bool, _ enabled: Bool, _ action: @escaping (Bool) -> Void) -> some View {
        toggle(title, symbol, isOn, enabled, action)
            .frame(maxWidth: .infinity)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private func toggle(_ title: String, _ symbol: String, _ isOn: Bool, _ enabled: Bool, _ action: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { action($0) })) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .disabled(!enabled)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func labeledSlider(
        _ symbol: String,
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        text: String,
        editing: @escaping (Bool) -> Void,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        VStack(spacing: 4) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.system(size: 11.5))
                Spacer()
                Text(text)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, onEditingChanged: editing)
                .controlSize(.small)
                .onChange(of: value.wrappedValue) { _, newValue in onChange(newValue) }
        }
    }
}