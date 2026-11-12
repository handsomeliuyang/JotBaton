import CoreLocalization
import CoreTheme
import CoreUI
import FeatureComments
import FeatureSettings
import FeatureVoice
import AppKit
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

extension PreferencesView {
    @available(macOS 26, *)
    var voiceSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                // Transcription Engine
                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader(L10n.tr("Transcription Engine"), description: L10n.tr("Choose which engine converts speech to text."))

                    settingsRow(L10n.tr("Engine")) {
                        RemarcDropdown(
                            selection: $settings.transcriptionEngine,
                            options: TranscriptionEngineType.availableCases,
                            labelFor: { L10n.lookup($0.rawValue) },
                            trailingAccessoryFor: { engine, cs in
                                switch engine {
                                case .appleSpeech:
                                    return nil
                                case .whisperKit:
                                    return downloadIndicator(
                                        downloaded: modelManager.downloadState == .downloaded,
                                        colorScheme: cs
                                    )
                                case .parakeet:
                                    #if canImport(FluidAudio)
                                    return downloadIndicator(
                                        downloaded: parakeetManager.downloadState == .downloaded,
                                        colorScheme: cs
                                    )
                                    #else
                                    return nil
                                    #endif
                                }
                            },
                            width: Self.pickerWidth
                        )
                    }

                    // Info box
                    VStack(alignment: .leading, spacing: 8) {
                        engineInfoRow(
                            icon: "apple.logo",
                            title: L10n.tr("Apple Speech"),
                            description: L10n.tr("Built-in macOS transcription. No download required. Good accuracy, fully private.")
                        )
                        engineInfoRow(
                            icon: "waveform",
                            title: L10n.tr("WhisperKit"),
                            description: L10n.tr("OpenAI Whisper via CoreML. High accuracy, multiple model sizes.")
                        )
                        #if canImport(FluidAudio)
                        engineInfoRow(
                            icon: "bolt.fill",
                            title: L10n.tr("Parakeet"),
                            description: L10n.tr("NVIDIA Parakeet via CoreML. Fastest inference, excellent accuracy.")
                        )
                        #endif
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.remarcPrimary(for: colorScheme).opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.remarcPrimary(for: colorScheme).opacity(0.15))
                            )
                    )
                }

                if settings.transcriptionEngine == .whisperKit {
                    Divider()

                    // WhisperKit Model
                    VStack(alignment: .leading, spacing: Self.itemSpacing) {
                        sectionHeader(L10n.tr("WhisperKit Model"), description: L10n.tr("Select model size. Larger models are more accurate but use more memory."))

                        pickerRow(L10n.tr("Model"), selection: $settings.whisperKitModel) { $0.label }

                        // Download status
                        modelDownloadStatus
                            .animation(.easeInOut(duration: 0.25), value: modelManager.downloadState)

                        if modelManager.downloadState != .downloaded
                            && modelManager.downloadState != .preparing {
                            if modelManager.hasAnyModelDownloaded() {
                                CalloutView(.info, L10n.tr("Using previously downloaded model until the new one is ready."))
                            } else {
                                CalloutView(.info, L10n.tr("Using Apple Speech until model is ready."))
                            }
                        }
                    }
                    .onChange(of: settings.whisperKitModel) { _, newModel in
                        modelManager.refreshDownloadState(for: newModel)
                    }
                    .onAppear {
                        modelManager.refreshDownloadState(for: settings.whisperKitModel)
                        // Auto-download if not yet downloaded
                        if modelManager.downloadState == .notDownloaded {
                            Task {
                                let _ = await modelManager.prepareModel(settings.whisperKitModel)
                            }
                        }
                    }
                }

                #if canImport(FluidAudio)
                if settings.transcriptionEngine == .parakeet {
                    Divider()

                    // Parakeet Model
                    VStack(alignment: .leading, spacing: Self.itemSpacing) {
                        sectionHeader(L10n.tr("Parakeet Model"), description: L10n.tr("NVIDIA Parakeet on-device model via FluidAudio."))

                        pickerRow(L10n.tr("Model"), selection: $settings.parakeetModelVersion) { $0.label }

                        parakeetDownloadStatus
                            .animation(.easeInOut(duration: 0.25), value: parakeetManager.downloadState)

                        if parakeetManager.downloadState != .downloaded
                            && parakeetManager.downloadState != .preparing {
                            CalloutView(.info, L10n.tr("Using Apple Speech until model is ready."))
                        }
                    }
                    .onChange(of: settings.parakeetModelVersion) { _, newVersion in
                        parakeetManager.refreshDownloadState(for: newVersion)
                    }
                    .onAppear {
                        parakeetManager.refreshDownloadState(for: settings.parakeetModelVersion)
                        if parakeetManager.downloadState == .notDownloaded {
                            Task {
                                let _ = await parakeetManager.prepareModel(settings.parakeetModelVersion)
                            }
                        }
                    }
                }

                #endif

                if settings.transcriptionEngine != .appleSpeech {
                    VStack(alignment: .leading, spacing: SettingsMetrics.descriptionSpacing) {
                        toggleRow(L10n.tr("Keep model in memory"), isOn: $settings.keepModelInMemory)
                        Text(L10n.tr("Prevents the model from being unloaded after use. Faster response times but uses more RAM (~200–500 MB depending on model). Recommended if you have 16 GB+ RAM."))
                            .settingDescriptionStyle()
                    }

                    if settings.keepModelInMemory {
                        VStack(alignment: .leading, spacing: SettingsMetrics.descriptionSpacing) {
                            toggleRow(L10n.tr("Load model on launch"), isOn: $settings.preloadModelOnLaunch)
                            Text(L10n.tr("Loads the model into memory when Remarc starts so dictation is instant on first use."))
                                .settingDescriptionStyle()
                        }
                        .nestedSetting()
                    }
                }

                Divider()

                // Shortcut
                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader(L10n.tr("Shortcut"), description: L10n.tr("Keyboard shortcut for voice comments. Also editable in the Shortcuts tab."))

                    settingsRow(L10n.tr("Voice Input")) {
                        ConflictAwareRecorder(name: .voiceInput)
                    }
                }

                Divider()

                // Behavior
                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader(L10n.tr("Behavior"), description: L10n.tr("Voice input behavior settings."))

                    toggleRow(L10n.tr("Sound effects"), isOn: $settings.soundEffectsEnabled)

                    VStack(alignment: .leading, spacing: SettingsMetrics.descriptionSpacing) {
                        toggleRow(L10n.tr("Mute audio while recording"), isOn: $settings.pauseMusicWhileRecording)
                        Text(L10n.tr("Mutes system audio when you start recording and restores it when you stop."))
                            .settingDescriptionStyle()
                    }

                    VStack(alignment: .leading, spacing: SettingsMetrics.descriptionSpacing) {
                        toggleRow(L10n.tr("Prefer Mac built-in mic"), isOn: $settings.smartMicrophoneSelection)
                        Text(L10n.tr("Uses known studio USB mics when present; otherwise prefers the Mac built-in microphone over AirPods and headset mics."))
                            .settingDescriptionStyle()
                    }

                    VStack(alignment: .leading, spacing: SettingsMetrics.descriptionSpacing) {
                        toggleRow(L10n.tr("Auto-save voice notes"), isOn: $settings.autoSaveVoiceNotes)
                        Text(L10n.tr("Automatically saves comments created with the voice shortcut. Does not apply to comments invoked manually."))
                            .settingDescriptionStyle()
                    }
                    if settings.autoSaveVoiceNotes {
                        pickerRow(L10n.tr("Auto-save delay"), selection: $settings.autoSaveDelay, width: 80) { $0.label }
                    }
                }

                Divider()

                // Dictation
                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader(L10n.tr("Dictation"), description: L10n.tr("Transcribe speech directly into any text field. Uses the same engine selected above."))

                    VStack(alignment: .leading, spacing: SettingsMetrics.descriptionSpacing) {
                        toggleRow(L10n.tr("Enable dictation"), isOn: $settings.dictationEnabled)
                        Text(L10n.tr("When disabled, dictation shortcuts are ignored and the feature is fully off."))
                            .settingDescriptionStyle()
                    }

                    if settings.dictationEnabled {
                        settingsRow(L10n.tr("Push to talk")) {
                            ConflictAwareRecorder(name: .dictation)
                                .disabled(settings.dictationUsesFnKey)
                                .opacity(settings.dictationUsesFnKey ? 0.4 : 1.0)
                        }
                        toggleRow(L10n.tr("Use fn🌐 key"), isOn: $settings.dictationUsesFnKey)

                        pickerRow(L10n.tr("Hands-free mode"), selection: $settings.dictationHandsFreeMode) { L10n.lookup($0.rawValue) }

                        if settings.dictationHandsFreeMode == .customShortcut {
                            settingsRow(L10n.tr("Hands-free shortcut")) {
                                ConflictAwareRecorder(name: .dictationHandsFree)
                                    .disabled(settings.dictationHandsFreeUsesFnKey)
                                    .opacity(settings.dictationHandsFreeUsesFnKey ? 0.4 : 1.0)
                            }
                            toggleRow(L10n.tr("Use fn🌐 key"), isOn: $settings.dictationHandsFreeUsesFnKey)
                        }

                        settingsRow(L10n.tr("Paste last dictation")) {
                            ConflictAwareRecorder(name: .pasteLastTranscription)
                        }

                        VStack(alignment: .leading, spacing: SettingsMetrics.descriptionSpacing) {
                            settingsRow(L10n.tr("History retention")) {
                                RemarcDropdown(
                                    selection: $settings.transcriptionRetentionDays,
                                    options: [1, 7, 30, 90],
                                    labelFor: { days in
                                        switch days {
                                        case 1: return L10n.tr("1 day")
                                        case 7: return L10n.tr("1 week")
                                        case 30: return L10n.tr("1 month")
                                        case 90: return L10n.tr("3 months")
                                        default: return L10n.tr("\(days) days")
                                        }
                                    },
                                    width: Self.pickerWidth
                                )
                            }
                            Text(L10n.tr("How long dictation transcriptions are kept in history."))
                                .settingDescriptionStyle()
                        }

                        // Info card
                        VStack(alignment: .leading, spacing: 8) {
                            engineInfoRow(
                                icon: "hand.point.down",
                                title: L10n.tr("Push to talk"),
                                description: L10n.tr("Hold the shortcut to record. Release to transcribe and paste into the focused text field.")
                            )
                            engineInfoRow(
                                icon: "hand.tap",
                                title: L10n.tr("Hands-free"),
                                description: {
                                    switch settings.dictationHandsFreeMode {
                                    case .singleTap:
                                        return L10n.tr("Tap the shortcut to start hands-free recording. A pill with Stop and Cancel buttons stays on screen.")
                                    case .doubleTap:
                                        return L10n.tr("Double-tap the shortcut to start hands-free recording. A single tap does a quick record-and-paste.")
                                    case .customShortcut:
                                        return L10n.tr("Press the hands-free shortcut to start recording. The push-to-talk shortcut is hold-only.")
                                    }
                                }()
                            )
                            engineInfoRow(
                                icon: "escape",
                                title: L10n.tr("Cancel"),
                                description: L10n.tr("Press Escape or click ✕ to discard without pasting.")
                            )
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.remarcPrimary(for: colorScheme).opacity(0.06))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Color.remarcPrimary(for: colorScheme).opacity(0.15))
                                )
                        )
                    }
                }

            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Model Download Status

    @available(macOS 26, *)
    @ViewBuilder
    var modelDownloadStatus: some View {
        let state = modelManager.downloadState

        switch state {
        case .failed(let message):
            CalloutView(.error, L10n.tr("Download failed: \(message)"), actionLabel: L10n.tr("Retry")) {
                Task {
                    let _ = await modelManager.prepareModel(settings.whisperKitModel)
                }
            }

        default:
            // Unified layout for notDownloaded → downloading → preparing → downloaded
            VStack(alignment: .leading, spacing: 6) {
                // Row 1: Status icon + text + action button
                HStack(spacing: 6) {
                    Group {
                        switch state {
                        case .downloaded:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.remarcSuccess(for: colorScheme))
                        case .downloading, .preparing:
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                        default:
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(.primary.opacity(0.4))
                        }
                    }
                    .font(.system(size: 11))

                    Group {
                        switch state {
                        case .downloaded:
                            Text(L10n.tr("Downloaded"))
                        case .downloading(let progress):
                            Text(L10n.tr("Downloading \(L10n.lookup(settings.whisperKitModel.rawValue))... \(Int(progress * 100))%"))
                        case .preparing:
                            Text(L10n.tr("Preparing model..."))
                        default:
                            Text(settings.whisperKitModel.label)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.6))
                    .contentTransition(.numericText())

                    Spacer()

                    // Action button — always on the status text row
                    switch state {
                    case .downloading:
                        textButton(L10n.tr("Cancel")) {
                            modelManager.cancelDownload()
                        }
                    case .downloaded:
                        textButton(L10n.tr("Delete"), color: Color.remarcError(for: colorScheme).opacity(0.8)) {
                            modelManager.deleteModel(settings.whisperKitModel)
                        }
                    case .notDownloaded:
                        textButton(L10n.tr("Download")) {
                            Task {
                                let _ = await modelManager.prepareModel(settings.whisperKitModel)
                            }
                        }
                    default:
                        EmptyView()
                    }
                }

                // Row 2: Progress bar (full width, no button)
                if case .downloading(let progress) = state {
                    ProgressView(value: progress)
                        .tint(Color.remarcPrimary(for: colorScheme))
                        .transition(.opacity)
                } else if case .preparing = state {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Color.remarcPrimary(for: colorScheme))
                        .transition(.opacity)
                }
            }
        }
    }

    #if canImport(FluidAudio)
    // MARK: - Parakeet Download Status

    @available(macOS 26, *)
    @ViewBuilder
    var parakeetDownloadStatus: some View {
        let state = parakeetManager.downloadState

        switch state {
        case .failed(let message):
            CalloutView(.error, L10n.tr("Download failed: \(message)"), actionLabel: L10n.tr("Retry")) {
                Task {
                    let _ = await parakeetManager.prepareModel(settings.parakeetModelVersion)
                }
            }

        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Group {
                        switch state {
                        case .downloaded:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.remarcSuccess(for: colorScheme))
                        case .downloading, .preparing:
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                        default:
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(.primary.opacity(0.4))
                        }
                    }
                    .font(.system(size: 11))

                    Group {
                        switch state {
                        case .downloaded:
                            Text(L10n.tr("Downloaded"))
                        case .downloading(let progress):
                            Text(L10n.tr("Downloading Parakeet... \(Int(progress * 100))%"))
                        case .preparing:
                            Text(L10n.tr("Preparing model..."))
                        default:
                            Text(settings.parakeetModelVersion.label)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.6))
                    .contentTransition(.numericText())

                    Spacer()

                    switch state {
                    case .downloading:
                        textButton(L10n.tr("Cancel")) {
                            parakeetManager.cancelDownload()
                        }
                    case .downloaded:
                        textButton(L10n.tr("Delete"), color: Color.remarcError(for: colorScheme).opacity(0.8)) {
                            parakeetManager.deleteModel(settings.parakeetModelVersion)
                        }
                    case .notDownloaded:
                        textButton(L10n.tr("Download")) {
                            Task {
                                let _ = await parakeetManager.prepareModel(settings.parakeetModelVersion)
                            }
                        }
                    default:
                        EmptyView()
                    }
                }

                if case .downloading(let progress) = state {
                    ProgressView(value: progress)
                        .tint(Color.remarcPrimary(for: colorScheme))
                        .transition(.opacity)
                } else if case .preparing = state {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Color.remarcPrimary(for: colorScheme))
                        .transition(.opacity)
                }
            }
        }
    }

    #endif

    // MARK: - Download Indicator

    func downloadIndicator(downloaded: Bool, colorScheme cs: ColorScheme) -> AnyView {
        AnyView(
            Image(systemName: downloaded ? "arrow.down.circle.fill" : "arrow.down.circle")
                .font(.system(size: 11))
                .foregroundStyle(downloaded ? Color.remarcSuccess(for: cs) : .primary.opacity(0.4))
        )
    }

    // MARK: - Engine Info Row

    func engineInfoRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Text button with hover state for settings CTAs.

}
