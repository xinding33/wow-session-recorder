import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Recording", systemImage: "record.circle") { RecordingSettings() }
            Tab("Storage", systemImage: "externaldrive") { StorageSettings() }
            Tab("World of Warcraft", systemImage: "gamecontroller") { GameSettings() }
        }
        .frame(width: 520)
        .onAppear { NSApp.activate() }
    }
}

private struct RecordingSettings: View {
    @Environment(AppModel.self) private var model
    @State private var hasPermission = CGPreflightScreenCaptureAccess()

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Record automatically while WoW is running", isOn: Binding(
                    get: { settings.autoRecord }, set: { model.setAutoRecord($0) }))
                Picker("Record", selection: Binding(
                    get: { settings.recordingScope }, set: { model.setRecordingScope($0) })) {
                    ForEach(RecordingScope.allCases) { Text($0.displayName).tag($0) }
                }
                if model.isRecordingEverythingAsFallback {
                    Label("Combat logging isn't on, so the app can't tell where you are and records everything. Install the helper addon (World of Warcraft tab).",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } footer: {
                if settings.recordingScope == .instancesOnly {
                    Text("Records in dungeons, raids and delves, including Mythic+, and keeps going for 2 minutes after you leave. Battlegrounds and other PvP aren't detected. In the open world, \(Hotkey.bookmark.display) starts a 1-minute recording and \(Hotkey.clip.display) records until you press it again.")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("Resolution", selection: $settings.quality) {
                    ForEach(CaptureQuality.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Frame rate", selection: $settings.fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Toggle("Record game audio", isOn: $settings.captureAudio)
            } footer: {
                Text("Encoded as HEVC on the hardware media engine, roughly 6–9 GB per hour at 1440p60.")
                    .foregroundStyle(.secondary)
            }
            .onChange(of: settings.quality) { model.restartCapture() }
            .onChange(of: settings.fps) { model.restartCapture() }
            .onChange(of: settings.captureAudio) { model.restartCapture() }

            Section("Hotkeys") {
                LabeledContent("Bookmark this moment", value: Hotkey.bookmark.display)
                LabeledContent("Start / stop a clip", value: Hotkey.clip.display)
            }

            Section("Permissions") {
                LabeledContent("Screen Recording") {
                    if hasPermission {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Open System Settings") {
                            CGRequestScreenCaptureAccess()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { hasPermission = CGPreflightScreenCaptureAccess() }
    }
}

private struct StorageSettings: View {
    @Environment(AppModel.self) private var model
    @State private var storageBytes: Int64 = 0

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                LabeledContent("Recordings folder") {
                    Text(settings.recordingsURL.path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([settings.recordingsURL])
                    }
                    Button("Change…") { chooseFolder() }
                }
                LabeledContent("Footage on disk", value: storageBytes.formatted(.byteCount(style: .file)))
            }
            Section {
                Picker("Keep footage outside activities for", selection: $settings.keepUnmarkedHours) {
                    Text("1 hour").tag(1)
                    Text("6 hours").tag(6)
                    Text("24 hours").tag(24)
                    Text("3 days").tag(72)
                    Text("1 week").tag(168)
                    Text("Forever").tag(0)
                }
                Picker("Keep activities for", selection: $settings.keepActivitiesDays) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("Forever").tag(0)
                }
            } footer: {
                Text("Everything is recorded, then trimmed down to your boss pulls, keys, matches and clips. Favorites are never deleted.")
                    .foregroundStyle(.secondary)
            }
            .onChange(of: settings.keepUnmarkedHours) { model.runRetention() }
            .onChange(of: settings.keepActivitiesDays) { model.runRetention() }
        }
        .formStyle(.grouped)
        .task(id: model.segments.count) { storageBytes = model.storageBytes }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.moveRecordings(to: url)
    }
}

private struct GameSettings: View {
    @Environment(AppModel.self) private var model
    @State private var installedAddonVersion: String?
    @State private var addonError: String?

    var body: some View {
        Form {
            Section {
                Picker("Open WoW Session Recorder", selection: Binding(
                    get: { model.settings.launchMode }, set: { model.setLaunchMode($0) })) {
                    ForEach(LaunchMode.allCases) { Text($0.displayName).tag($0) }
                }
                if let error = model.launchModeError {
                    Text(error).foregroundStyle(.red)
                }
            } footer: {
                Text(launchFooter).foregroundStyle(.secondary)
            }

            CompanionAppsSection()

            Section {
                LabeledContent("Install") {
                    if let folder = model.retailFolder {
                        Text(folder.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle)
                    } else {
                        Text("Not found").foregroundStyle(.red)
                    }
                }
                HStack {
                    Spacer()
                    if model.settings.wowRetailPath != nil {
                        Button("Auto-detect") {
                            model.settings.wowRetailPath = nil
                            model.refreshRetailFolder()
                        }
                    }
                    Button("Choose…") { chooseInstall() }
                }
                LabeledContent("Combat log") {
                    if let last = model.combatLogLastWrite {
                        Text("Updated \(last, style: .relative) ago")
                    } else {
                        Text("No writes since launch").foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                LabeledContent("WoW Session Recorder Helper") {
                    if let installed = installedAddonVersion {
                        if installed == HelperAddon.bundledVersion {
                            Label("Installed (\(installed))", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Update") { installAddon() }
                        }
                    } else {
                        Button("Install") { installAddon() }
                            .disabled(model.retailFolder == nil)
                    }
                }
                if let addonError {
                    Text(addonError).foregroundStyle(.red)
                }
            } header: {
                Text("Helper addon")
            } footer: {
                Text("Activities come from the combat log, which WoW turns off at every logout. The helper turns it back on in dungeons, raids, delves and PvP, and enables Advanced Combat Logging. Without it, type /combatlog each session. Type /srh in game for options.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshAddon)
        .onChange(of: model.retailFolder) { refreshAddon() }
    }

    private var launchFooter: String {
        switch model.settings.launchMode {
        case .withWoW: "Opens a few seconds after WoW starts and quits when WoW quits. Nothing runs in between."
        case .atLogin: "Stays in the menu bar and starts recording whenever WoW runs."
        case .manual: "Open WoW Session Recorder yourself before playing."
        }
    }

    private func refreshAddon() {
        installedAddonVersion = model.retailFolder.flatMap(HelperAddon.installedVersion(retail:))
    }

    private func installAddon() {
        guard let folder = model.retailFolder else { return }
        do {
            try HelperAddon.install(retail: folder)
            addonError = nil
        } catch {
            addonError = error.localizedDescription
        }
        refreshAddon()
    }

    private func chooseInstall() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose your World of Warcraft folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let retail = WoWInstall.normalize(url) else {
            addonError = "That folder doesn't contain a _retail_ install."
            return
        }
        model.settings.wowRetailPath = retail.path
        model.refreshRetailFolder()
    }
}

private struct CompanionAppsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Section {
            ForEach(settings.companionAppURLs, id: \.self) { url in
                HStack {
                    Image(nsImage: CompanionApps.icon(for: url))
                        .resizable()
                        .frame(width: 20, height: 20)
                    Text(CompanionApps.displayName(for: url))
                    if !FileManager.default.fileExists(atPath: url.path) {
                        Text("Missing").font(.caption).foregroundStyle(.red)
                    }
                    Spacer()
                    Button("Remove", systemImage: "minus.circle") { model.removeCompanionApp(url) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                Spacer()
                Button("Add App…") { chooseApp() }
            }
            Toggle("Quit them when WoW quits", isOn: $settings.quitCompanionsWithWoW)
                .disabled(settings.companionAppPaths.isEmpty)
        } header: {
            Text("Also open with WoW")
        } footer: {
            Text("Opened in the background when WoW starts. When WoW quits they get 30 seconds to finish syncing, then quit normally.")
                .foregroundStyle(.secondary)
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addCompanionApp(url)
    }
}
