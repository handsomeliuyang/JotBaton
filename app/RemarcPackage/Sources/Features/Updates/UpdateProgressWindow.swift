import AppKit
import Combine
import CoreLocalization

/// A persistent native progress surface, including updates started from the menu bar.
@MainActor
final class UpdateProgressWindow: NSWindowController {
    private weak var manager: UpdateManager?
    private var observation: AnyCancellable?
    private let message = NSTextField(wrappingLabelWithString: "")
    private let indicator = NSProgressIndicator()
    private let cancelButton = NSButton(title: L10n.tr("Cancel Update"), target: nil, action: nil)
    private let resumeButton = NSButton(title: L10n.tr("Upgrade and Restart"), target: nil, action: nil)

    init(manager: UpdateManager) {
        self.manager = manager
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 230),
                              styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.title = L10n.tr("JotBaton Update")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setFrameSize(NSSize(width: 48, height: 48))
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        message.alignment = .center
        message.font = .systemFont(ofSize: 13)
        indicator.style = .bar
        indicator.minValue = 0
        indicator.maxValue = 1
        indicator.widthAnchor.constraint(equalToConstant: 350).isActive = true
        let buttons = NSStackView(views: [cancelButton, resumeButton])
        buttons.spacing = 12
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        resumeButton.target = self
        resumeButton.action = #selector(resume)
        for view in [icon, message, indicator, buttons] { stack.addArrangedSubview(view) }
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            stack.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor),
        ])
        observation = manager.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.render() }
        }
        window.center()
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        render()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func render() {
        guard let manager else { return }
        message.stringValue = manager.status
        if let progress = manager.progress {
            indicator.isIndeterminate = false
            indicator.doubleValue = progress
            indicator.stopAnimation(nil)
        } else {
            indicator.isIndeterminate = true
            indicator.startAnimation(nil)
        }
        cancelButton.isHidden = !manager.canCancelUpdate
        resumeButton.isHidden = !manager.canResumeUpdate
    }

    @objc private func cancel() { manager?.cancelUpdate() }
    @objc private func resume() { manager?.resumeUpdate() }
}
