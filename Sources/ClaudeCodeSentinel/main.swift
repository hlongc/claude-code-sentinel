import Foundation
import AppKit
import CoreGraphics

let maxDialogChars = 2600
let maxNotificationChars = 180
let defaultActiveIdleThresholdSeconds = 8.0
let defaultActiveGraceSeconds = 15.0
let activePollIntervalSeconds = 1.0
let dialogMinWidth: CGFloat = 440
let dialogMaxWidth: CGFloat = 520
let managedSettingsPath = "/Library/Application Support/ClaudeCode/managed-settings.json"
var activeDialogHandlers: [NSObject] = []
var dialogMetaLine = ""

func readStdinData() -> Data {
    FileHandle.standardInput.readDataToEndOfFile()
}

func parseHookInput(_ data: Data) throws -> [String: Any] {
    if data.isEmpty {
        return [:]
    }
    guard let raw = String(data: data, encoding: .utf8), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return [:]
    }
    let value = try JSONSerialization.jsonObject(with: data, options: [])
    return value as? [String: Any] ?? [:]
}

func jsonString(_ value: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [])
    return String(data: data, encoding: .utf8)!
}

func prettyJsonString(_ value: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    return String(data: data, encoding: .utf8)!
}

func parseJsonObject(from data: Data) throws -> [String: Any] {
    if data.isEmpty {
        return [:]
    }
    let value = try JSONSerialization.jsonObject(with: data, options: [])
    return value as? [String: Any] ?? [:]
}

func appleQuote(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\r", with: "")
        .replacingOccurrences(of: "\n", with: "\\n")
}

func truncate(_ value: String, _ max: Int) -> String {
    if value.count <= max {
        return value
    }
    let end = value.index(value.startIndex, offsetBy: max - 20)
    return "\(value[..<end])\n... [truncated]"
}

func stringValue(_ input: [String: Any], _ key: String) -> String {
    input[key] as? String ?? ""
}

func dictValue(_ input: [String: Any], _ key: String) -> [String: Any] {
    input[key] as? [String: Any] ?? [:]
}

func arrayValue(_ input: [String: Any], _ key: String) -> [[String: Any]] {
    input[key] as? [[String: Any]] ?? []
}

func sessionSuffix(_ input: [String: Any]) -> String {
    let id = stringValue(input, "session_id")
    if id.isEmpty {
        return "no-session"
    }
    return id.count <= 8 ? id : String(id.suffix(8))
}

func projectName(_ input: [String: Any]) -> String {
    let cwd = stringValue(input, "cwd")
    if cwd.isEmpty {
        return "Claude Code"
    }
    let base = URL(fileURLWithPath: cwd).lastPathComponent
    return base.isEmpty ? "Claude Code" : base
}

func titleFor(_ input: [String: Any], _ label: String) -> String {
    "\(projectName(input)) - \(label) - \(sessionSuffix(input))"
}

func formatToolInput(_ input: [String: Any]) -> String {
    let tool = stringValue(input, "tool_name")
    let toolInput = dictValue(input, "tool_input")

    if tool == "Bash", let command = toolInput["command"] as? String {
        var parts: [String] = []
        if let description = toolInput["description"] as? String, !description.isEmpty {
            parts.append("Description:\n\(description)")
        }
        parts.append("Command:\n\(command)")
        return parts.joined(separator: "\n\n")
    }

    if ["Edit", "Write", "Read"].contains(tool), let filePath = toolInput["file_path"] as? String {
        return "File:\n\(filePath)\n\nInput:\n\(prettyJsonString(toolInput))"
    }

    if tool == "AskUserQuestion", let questions = toolInput["questions"] as? [[String: Any]] {
        return questions.enumerated().map { index, question in
            let text = question["question"] as? String ?? ""
            let options = (question["options"] as? [[String: Any]] ?? [])
                .compactMap { $0["label"] as? String }
                .joined(separator: ", ")
            return "\(index + 1). \(text)\nOptions: \(options)"
        }.joined(separator: "\n\n")
    }

    return prettyJsonString(toolInput)
}

struct ScriptResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

func runOsascript(_ script: String) -> ScriptResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return ScriptResult(status: 1, stdout: "", stderr: String(describing: error))
    }

    let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return ScriptResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
}

struct DialogResult {
    let canceled: Bool
    let button: String?
}

final class DialogButtonHandler: NSObject {
    let onSelect: (String) -> Void

    init(onSelect: @escaping (String) -> Void) {
        self.onSelect = onSelect
    }

    @objc func select(_ sender: NSButton) {
        onSelect(sender.title)
    }
}

final class ChoiceButtonHandler: NSObject {
    let onSelect: (String) -> Void

    init(onSelect: @escaping (String) -> Void) {
        self.onSelect = onSelect
    }

    @objc func select(_ sender: NSButton) {
        onSelect(sender.title)
    }
}

final class MultiChoiceHandler: NSObject {
    let onSubmit: () -> Void
    let onCancel: () -> Void

    init(onSubmit: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    @objc func submit(_ sender: NSButton) {
        onSubmit()
    }

    @objc func cancel(_ sender: NSButton) {
        onCancel()
    }
}

func makeLabel(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = font
    label.textColor = color
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 2
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
}

func makeBodyText(_ text: String, monospaced: Bool = false) -> NSScrollView {
    let textView = NSTextView()
    textView.string = text
    textView.font = monospaced ? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular) : NSFont.systemFont(ofSize: 12.5)
    textView.textColor = monospaced ? NSColor(calibratedWhite: 0.15, alpha: 1) : .labelColor
    textView.backgroundColor = .clear
    textView.isEditable = false
    textView.isSelectable = true
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = true
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.heightTracksTextView = false
    textView.textContainer?.lineBreakMode = .byCharWrapping
    textView.textContainerInset = NSSize(width: monospaced ? 12 : 0, height: monospaced ? 10 : 0)
    textView.textContainer?.lineFragmentPadding = 0

    let scroll = NSScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.documentView = textView
    scroll.hasVerticalScroller = false
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.drawsBackground = monospaced
    scroll.backgroundColor = monospaced ? NSColor(calibratedWhite: 0.955, alpha: 1) : .clear
    if monospaced {
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 9
    }
    return scroll
}

func buttonStyle(_ button: NSButton, primary: Bool = false) {
    button.isBordered = false
    button.wantsLayer = true
    button.layer?.cornerRadius = 7
    button.layer?.backgroundColor = primary
        ? NSColor.systemBlue.cgColor
        : NSColor.controlBackgroundColor.cgColor
    let color = primary ? NSColor.white : NSColor.labelColor
    button.attributedTitle = NSAttributedString(
        string: button.title,
        attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: primary ? .semibold : .medium),
            .foregroundColor: color
        ]
    )
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
    if primary {
        button.keyEquivalent = "\r"
    }
}

func choiceButtonStyle(_ button: NSButton) {
    button.isBordered = false
    button.alignment = .left
    button.wantsLayer = true
    button.layer?.cornerRadius = 8
    button.layer?.backgroundColor = NSColor(calibratedWhite: 0.955, alpha: 1).cgColor
    button.contentTintColor = .labelColor
    button.attributedTitle = NSAttributedString(
        string: button.title,
        attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
    )
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
}

func topRightOrigin(width: CGFloat, height: CGFloat) -> NSPoint {
    let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    let margin: CGFloat = 24
    return NSPoint(
        x: max(screenFrame.minX + margin, screenFrame.maxX - width - margin),
        y: max(screenFrame.minY + margin, screenFrame.maxY - height - margin)
    )
}

func dialogWidth(defaultWidth: CGFloat) -> CGFloat {
    let screenWidth = NSScreen.main?.visibleFrame.width ?? 1280
    return min(dialogMaxWidth, max(defaultWidth, screenWidth * 0.34))
}

func displayChoiceDialog(title: String, meta: String, question: String, options: [String], multiSelect: Bool) -> DialogResult {
    NSApplication.shared.setActivationPolicy(.accessory)

    var selected: String?
    var canceled = false
    var selectedOptions = Set<String>()

    let windowWidth: CGFloat = dialogWidth(defaultWidth: 430)
    let rowHeight: CGFloat = 34
    let optionsHeight = CGFloat(max(options.count, 1)) * rowHeight + CGFloat(max(options.count - 1, 0)) * 8
    let windowHeight = min(max(196 + optionsHeight, 260), 430)
    let origin = topRightOrigin(width: windowWidth, height: windowHeight)

    let window = NSWindow(
        contentRect: NSRect(origin: origin, size: NSSize(width: windowWidth, height: windowHeight)),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.level = .floating
    window.isReleasedWhenClosed = false
    window.backgroundColor = .clear
    window.isOpaque = false
    window.hasShadow = true
    window.isMovableByWindowBackground = true
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    let root = NSView()
    root.wantsLayer = true
    root.layer?.backgroundColor = NSColor(calibratedWhite: 0.99, alpha: 0.98).cgColor
    root.layer?.cornerRadius = 16
    root.layer?.borderWidth = 0.5
    root.layer?.borderColor = NSColor(calibratedWhite: 0.84, alpha: 0.55).cgColor
    root.translatesAutoresizingMaskIntoConstraints = false

    let titleLabel = makeLabel(title, font: NSFont.systemFont(ofSize: 13.5, weight: .semibold))
    let subtitle = makeLabel(multiSelect ? "Select one or more options" : "Select one option", font: NSFont.systemFont(ofSize: 12), color: .secondaryLabelColor)
    let metaLabel = makeLabel(meta, font: NSFont.systemFont(ofSize: 11.5), color: .secondaryLabelColor)
    let questionLabel = makeLabel(question, font: NSFont.systemFont(ofSize: 14, weight: .semibold))
    questionLabel.lineBreakMode = .byWordWrapping

    let optionViews: [NSView]
    let choiceHandler = ChoiceButtonHandler { value in
        selected = value
        window.close()
        NSApplication.shared.stop(nil)
    }
    let multiHandler = MultiChoiceHandler {
        selected = options.filter { selectedOptions.contains($0) }.joined(separator: ", ")
        window.close()
        NSApplication.shared.stop(nil)
    } onCancel: {
        canceled = true
        window.close()
        NSApplication.shared.stop(nil)
    }
    activeDialogHandlers.append(choiceHandler)
    activeDialogHandlers.append(multiHandler)

    if multiSelect {
        optionViews = options.map { option in
            let checkbox = NSButton(checkboxWithTitle: option, target: nil, action: nil)
            checkbox.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            checkbox.translatesAutoresizingMaskIntoConstraints = false
            checkbox.wantsLayer = true
            checkbox.layer?.cornerRadius = 8
            checkbox.layer?.backgroundColor = NSColor(calibratedWhite: 0.955, alpha: 1).cgColor
            let target = MultiSelectTarget { isOn in
                if isOn {
                    selectedOptions.insert(option)
                } else {
                    selectedOptions.remove(option)
                }
            }
            activeDialogHandlers.append(target)
            checkbox.target = target
            checkbox.action = #selector(MultiSelectTarget.toggle(_:))
            NSLayoutConstraint.activate([checkbox.heightAnchor.constraint(equalToConstant: rowHeight)])
            return checkbox
        }
    } else {
        optionViews = options.map { option in
            let button = NSButton(title: option, target: choiceHandler, action: #selector(ChoiceButtonHandler.select(_:)))
            choiceButtonStyle(button)
            NSLayoutConstraint.activate([button.heightAnchor.constraint(equalToConstant: rowHeight)])
            return button
        }
    }

    let optionStack = NSStackView(views: optionViews)
    optionStack.orientation = .vertical
    optionStack.spacing = 8
    optionStack.translatesAutoresizingMaskIntoConstraints = false

    let optionScroll = NSScrollView()
    optionScroll.documentView = optionStack
    optionScroll.hasVerticalScroller = false
    optionScroll.drawsBackground = false
    optionScroll.translatesAutoresizingMaskIntoConstraints = false

    let cancel = NSButton(title: "Cancel", target: multiHandler, action: #selector(MultiChoiceHandler.cancel(_:)))
    let submit = NSButton(title: multiSelect ? "Submit" : "Cancel", target: multiHandler, action: multiSelect ? #selector(MultiChoiceHandler.submit(_:)) : #selector(MultiChoiceHandler.cancel(_:)))
    buttonStyle(cancel)
    buttonStyle(submit, primary: multiSelect)
    let buttons = multiSelect ? [cancel, submit] : [cancel]
    let buttonStack = NSStackView(views: buttons)
    buttonStack.orientation = .horizontal
    buttonStack.spacing = 8
    buttonStack.translatesAutoresizingMaskIntoConstraints = false

    root.addSubview(titleLabel)
    root.addSubview(subtitle)
    root.addSubview(metaLabel)
    root.addSubview(questionLabel)
    root.addSubview(optionScroll)
    root.addSubview(buttonStack)
    window.contentView = root
    window.minSize = NSSize(width: windowWidth, height: 180)
    window.maxSize = NSSize(width: windowWidth, height: 900)
    window.setContentSize(NSSize(width: windowWidth, height: windowHeight))

    NSLayoutConstraint.activate([
        titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
        titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
        titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
        subtitle.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
        subtitle.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
        subtitle.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
        metaLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
        metaLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
        metaLabel.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 8),
        questionLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
        questionLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
        questionLabel.topAnchor.constraint(equalTo: metaLabel.bottomAnchor, constant: 12),
        optionScroll.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
        optionScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
        optionScroll.topAnchor.constraint(equalTo: questionLabel.bottomAnchor, constant: 12),
        optionScroll.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -12),
        buttonStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
        buttonStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -15),
        cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
        cancel.heightAnchor.constraint(equalToConstant: 28)
    ])
    if multiSelect {
        submit.widthAnchor.constraint(greaterThanOrEqualToConstant: 104).isActive = true
        submit.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        if event.keyCode == 53 {
            canceled = true
            window.close()
            NSApplication.shared.stop(nil)
            return nil
        }
        return event
    }

    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.run()
    return DialogResult(canceled: canceled || selected == nil, button: selected)
}

final class MultiSelectTarget: NSObject {
    let onToggle: (Bool) -> Void

    init(_ onToggle: @escaping (Bool) -> Void) {
        self.onToggle = onToggle
    }

    @objc func toggle(_ sender: NSButton) {
        onToggle(sender.state == .on)
    }
}

func displayFloatingDialog(title: String, message: String, buttons: [String], defaultButton: String, cancelButton: String?) -> DialogResult {
    if NSApplication.shared.isRunning {
        return displayDialogWithOsascript(title: title, message: message, buttons: buttons, defaultButton: defaultButton, cancelButton: cancelButton)
    }

    var selected: String?
    var canceled = false

    NSApplication.shared.setActivationPolicy(.accessory)

    let windowWidth: CGFloat = dialogWidth(defaultWidth: dialogMinWidth)
    let windowHeight: CGFloat = 260
    let origin = topRightOrigin(width: windowWidth, height: windowHeight)

    let window = NSWindow(
        contentRect: NSRect(origin: origin, size: NSSize(width: windowWidth, height: windowHeight)),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.level = .floating
    window.isReleasedWhenClosed = false
    window.backgroundColor = .clear
    window.isOpaque = false
    window.hasShadow = true
    window.isMovableByWindowBackground = true
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    let root = NSView()
    root.wantsLayer = true
    root.layer?.backgroundColor = NSColor(calibratedWhite: 0.99, alpha: 0.98).cgColor
    root.layer?.cornerRadius = 16
    root.layer?.borderWidth = 0.5
    root.layer?.borderColor = NSColor(calibratedWhite: 0.84, alpha: 0.55).cgColor
    root.translatesAutoresizingMaskIntoConstraints = false

    let titleLabel = makeLabel(title, font: NSFont.systemFont(ofSize: 13.5, weight: .semibold))
    let subtitle = makeLabel("Claude Code permission request", font: NSFont.systemFont(ofSize: 12), color: .secondaryLabelColor)
    let meta = makeLabel(dialogMetaLine, font: NSFont.systemFont(ofSize: 11.5), color: .secondaryLabelColor)
    let body = makeBodyText(message, monospaced: true)

    let close = NSButton(title: cancelButton ?? buttons.first ?? "No", target: nil, action: nil)
    let allow = NSButton(title: defaultButton, target: nil, action: nil)
    let extraButtons = buttons
        .filter { $0 != close.title && $0 != allow.title }
        .map { NSButton(title: $0, target: nil, action: nil) }

    [close, allow].forEach { buttonStyle($0, primary: $0.title == defaultButton) }
    extraButtons.forEach { buttonStyle($0) }

    let handler = DialogButtonHandler { button in
        selected = button
        canceled = button == cancelButton
        window.close()
        NSApplication.shared.stop(nil)
    }
    activeDialogHandlers.append(handler)

    ([close, allow] + extraButtons).forEach {
        $0.target = handler
        $0.action = #selector(DialogButtonHandler.select(_:))
    }

    let buttonStack = NSStackView(views: [close, allow] + extraButtons)
    buttonStack.orientation = .horizontal
    buttonStack.spacing = 8
    buttonStack.alignment = .centerY
    buttonStack.translatesAutoresizingMaskIntoConstraints = false

    root.addSubview(titleLabel)
    root.addSubview(subtitle)
    root.addSubview(meta)
    root.addSubview(body)
    root.addSubview(buttonStack)
    window.contentView = root
    window.minSize = NSSize(width: windowWidth, height: 220)
    window.maxSize = NSSize(width: windowWidth, height: 900)
    window.setContentSize(NSSize(width: windowWidth, height: windowHeight))

    NSLayoutConstraint.activate([
        titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
        titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
        titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),

        subtitle.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
        subtitle.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
        subtitle.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),

        meta.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
        meta.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
        meta.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 8),

        body.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
        body.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
        body.topAnchor.constraint(equalTo: meta.bottomAnchor, constant: 10),
        body.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -12),

        buttonStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
        buttonStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -15),

        close.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
        close.heightAnchor.constraint(equalToConstant: 28),
        allow.widthAnchor.constraint(greaterThanOrEqualToConstant: 116),
        allow.heightAnchor.constraint(equalToConstant: 28),
        root.widthAnchor.constraint(equalToConstant: windowWidth)
    ])
    for button in extraButtons {
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: min(210, max(124, CGFloat(button.title.count * 7 + 28)))).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        if event.keyCode == 53 {
            selected = cancelButton
            canceled = true
            window.close()
            NSApplication.shared.stop(nil)
            return nil
        }
        return event
    }

    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.run()

    return DialogResult(canceled: canceled, button: selected)
}

func displayDialog(title: String, message: String, buttons: [String], defaultButton: String, cancelButton: String?) -> DialogResult {
    displayFloatingDialog(title: title, message: message, buttons: buttons, defaultButton: defaultButton, cancelButton: cancelButton)
}

func displayDialogWithOsascript(title: String, message: String, buttons: [String], defaultButton: String, cancelButton: String?) -> DialogResult {
    let buttonList = buttons.map { "\"\(appleQuote($0))\"" }.joined(separator: ", ")
    let cancelClause = cancelButton.map { " cancel button \"\(appleQuote($0))\"" } ?? ""
    let script = [
        "display dialog \"\(appleQuote(message))\"",
        "with title \"\(appleQuote(title))\"",
        "buttons {\(buttonList)}",
        "default button \"\(appleQuote(defaultButton))\"",
        cancelClause,
        "with icon caution"
    ].filter { !$0.isEmpty }.joined(separator: " ")

    let result = runOsascript(script)
    if result.status != 0 {
        return DialogResult(canceled: true, button: nil)
    }

    let prefix = "button returned:"
    if let range = result.stdout.range(of: prefix) {
        let button = result.stdout[range.upperBound...]
            .split(separator: "\n", maxSplits: 1)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        return DialogResult(canceled: false, button: button)
    }
    return DialogResult(canceled: false, button: nil)
}

func displayNotification(title: String, message: String, subtitle: String?) {
    let subtitleClause = subtitle.map { "subtitle \"\(appleQuote($0))\"" } ?? ""
    let script = [
        "display notification \"\(appleQuote(truncate(message, maxNotificationChars)))\"",
        "with title \"\(appleQuote(title))\"",
        subtitleClause
    ].filter { !$0.isEmpty }.joined(separator: " ")
    _ = runOsascript(script)
}

func logPath() -> String {
    let directory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/ClaudeCodeSentinel", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("hooks.log").path
}

func appendDebugLog(_ fields: [String: String]) {
    var items = fields
    let formatter = ISO8601DateFormatter()
    items["time"] = formatter.string(from: Date())
    let line = items
        .sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value.replacingOccurrences(of: "\n", with: "\\n"))" }
        .joined(separator: " ")
        + "\n"

    guard let data = line.data(using: .utf8) else {
        return
    }

    let path = logPath()
    if FileManager.default.fileExists(atPath: path),
       let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

func activeIdleThresholdSeconds() -> Double {
    let raw = ProcessInfo.processInfo.environment["CLAUDE_SENTINEL_ACTIVE_IDLE_SECONDS"] ?? ""
    if let value = Double(raw), value >= 0 {
        return value
    }
    return defaultActiveIdleThresholdSeconds
}

func activeGraceSeconds() -> Double {
    let raw = ProcessInfo.processInfo.environment["CLAUDE_SENTINEL_ACTIVE_GRACE_SECONDS"] ?? ""
    if let value = Double(raw), value >= 0 {
        return value
    }
    return defaultActiveGraceSeconds
}

func systemIdleSeconds() -> Double {
    let anyEvent = CGEventType(rawValue: UInt32.max)!
    let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
    if seconds.isFinite && seconds >= 0 {
        return seconds
    }
    return Double.greatestFiniteMagnitude
}

func frontmostApplicationName() -> String {
    NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
}

func frontmostWindowTitle(appName: String) -> String {
    if appName.isEmpty {
        return ""
    }

    let script = """
    tell application "System Events"
      set frontApp to first application process whose frontmost is true
      try
        return name of front window of frontApp
      on error
        return ""
      end try
    end tell
    """
    let result = runOsascript(script)
    if result.status != 0 {
        return ""
    }
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

func isTerminalLikeApp(_ appName: String) -> Bool {
    let name = appName.lowercased()
    let terminalApps = [
        "terminal",
        "iterm",
        "iterm2",
        "warp",
        "wezterm",
        "ghostty",
        "kitty",
        "alacritty",
        "visual studio code",
        "code",
        "cursor"
    ]
    return terminalApps.contains { name.contains($0) }
}

func frontmostLooksLikeThisClaudeSession(appName: String, title: String, input: [String: Any]) -> Bool {
    if !isTerminalLikeApp(appName) {
        return false
    }

    let title = title.lowercased()
    let project = projectName(input).lowercased()
    let cwd = stringValue(input, "cwd").lowercased()

    if title.isEmpty {
        return appName.lowercased().contains("terminal") || appName.lowercased().contains("iterm") || appName.lowercased().contains("warp")
    }

    if title.contains("claude") {
        return true
    }
    if !project.isEmpty && title.contains(project) {
        return true
    }
    if !cwd.isEmpty && title.contains(cwd) {
        return true
    }

    return false
}

struct ActiveState {
    let appName: String
    let title: String
    let idle: Double
    let threshold: Double
    let matchesClaudeTerminal: Bool

    var shouldSuppress: Bool {
        matchesClaudeTerminal && idle <= threshold
    }
}

func currentActiveState(input: [String: Any]) -> ActiveState {
    let appName = frontmostApplicationName()
    let title = frontmostWindowTitle(appName: appName)
    let idle = systemIdleSeconds()
    let threshold = activeIdleThresholdSeconds()
    let matchesClaudeTerminal = frontmostLooksLikeThisClaudeSession(appName: appName, title: title, input: input)
    return ActiveState(
        appName: appName,
        title: title,
        idle: idle,
        threshold: threshold,
        matchesClaudeTerminal: matchesClaudeTerminal
    )
}

func logActiveDecision(event: String, input: [String: Any], state: ActiveState, decision: String, waitedSeconds: Double) {
    appendDebugLog([
        "event": event,
        "tool": stringValue(input, "tool_name"),
        "project": projectName(input),
        "session": sessionSuffix(input),
        "frontApp": state.appName,
        "frontTitle": state.title,
        "idleSeconds": String(format: "%.1f", state.idle),
        "thresholdSeconds": String(format: "%.1f", state.threshold),
        "waitedSeconds": String(format: "%.1f", waitedSeconds),
        "matchesClaudeTerminal": state.matchesClaudeTerminal ? "true" : "false",
        "decision": decision
    ])
}

func shouldSuppressBecauseUserIsActive(event: String, input: [String: Any]) -> Bool {
    var state = currentActiveState(input: input)
    if !state.shouldSuppress {
        logActiveDecision(event: event, input: input, state: state, decision: "show", waitedSeconds: 0)
        return false
    }

    let grace = activeGraceSeconds()
    var waited = 0.0
    while waited < grace {
        let remaining = grace - waited
        let interval = min(activePollIntervalSeconds, remaining)
        Thread.sleep(forTimeInterval: interval)
        waited += interval

        state = currentActiveState(input: input)
        if !state.shouldSuppress {
            logActiveDecision(event: event, input: input, state: state, decision: "show-after-wait", waitedSeconds: waited)
            return false
        }
    }

    logActiveDecision(event: event, input: input, state: state, decision: "suppress", waitedSeconds: waited)
    return true
}

func firstAllowSuggestion(_ input: [String: Any]) -> [String: Any]? {
    arrayValue(input, "permission_suggestions").first { suggestion in
        suggestion["behavior"] as? String == "allow"
    }
}

func allowDecision(updatedPermissions: [[String: Any]]? = nil) -> [String: Any] {
    var decision: [String: Any] = ["behavior": "allow"]
    if let updatedPermissions = updatedPermissions {
        decision["updatedPermissions"] = updatedPermissions
    }
    return [
        "hookSpecificOutput": [
            "hookEventName": "PermissionRequest",
            "decision": decision
        ]
    ]
}

func denyDecision(_ message: String) -> [String: Any] {
    [
        "hookSpecificOutput": [
            "hookEventName": "PermissionRequest",
            "decision": [
                "behavior": "deny",
                "message": message,
                "interrupt": false
            ]
        ]
    ]
}

func preToolUseAllowDecision(updatedInput: [String: Any]) -> [String: Any] {
    [
        "hookSpecificOutput": [
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "updatedInput": updatedInput
        ]
    ]
}

func preToolUseDenyDecision(_ message: String) -> [String: Any] {
    [
        "hookSpecificOutput": [
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": message
        ]
    ]
}

func handlePreToolUse(_ input: [String: Any]) -> [String: Any] {
    if stringValue(input, "tool_name") != "AskUserQuestion" {
        return [:]
    }

    if shouldSuppressBecauseUserIsActive(event: "PreToolUse", input: input) {
        return [:]
    }

    var toolInput = dictValue(input, "tool_input")
    let questions = toolInput["questions"] as? [[String: Any]] ?? []
    if questions.isEmpty {
        return [:]
    }

    let cwd = stringValue(input, "cwd").isEmpty ? "unknown" : stringValue(input, "cwd")
    let meta = "AskUserQuestion  -  \(cwd)"
    var answers: [String: String] = [:]

    for (index, question) in questions.enumerated() {
        let questionText = question["question"] as? String ?? "Choose an option"
        let options = (question["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
        if options.isEmpty {
            continue
        }

        let multiSelect = question["multiSelect"] as? Bool ?? false
        let title = titleFor(input, "Question \(index + 1)/\(questions.count)")
        let choice = displayChoiceDialog(
            title: title,
            meta: meta,
            question: questionText,
            options: options,
            multiSelect: multiSelect
        )

        if choice.canceled || choice.button == nil {
            return preToolUseDenyDecision("User canceled the question from the desktop prompt.")
        }

        answers[questionText] = choice.button ?? ""
    }

    toolInput["answers"] = answers
    return preToolUseAllowDecision(updatedInput: toolInput)
}

func handlePermissionRequest(_ input: [String: Any]) -> [String: Any] {
    if shouldSuppressBecauseUserIsActive(event: "PermissionRequest", input: input) {
        return [:]
    }

    let toolName = stringValue(input, "tool_name")
    let title = titleFor(input, "\(toolName.isEmpty ? "Tool" : toolName) permission")
    let allowSuggestion = firstAllowSuggestion(input)
    let rememberLabel = "Yes, don't ask again"
    let buttons = allowSuggestion == nil ? ["No", "Yes"] : ["No", "Yes", rememberLabel]
    let cwd = stringValue(input, "cwd").isEmpty ? "unknown" : stringValue(input, "cwd")
    dialogMetaLine = "\(toolName.isEmpty ? "unknown tool" : toolName)  -  \(cwd)"
    let body = truncate(formatToolInput(input), maxDialogChars)

    let choice = displayDialog(
        title: title,
        message: body,
        buttons: buttons,
        defaultButton: "Yes",
        cancelButton: "No"
    )

    if choice.canceled || choice.button == "No" {
        return denyDecision("User denied the permission request from the desktop prompt.")
    }

    if choice.button == rememberLabel, let suggestion = allowSuggestion {
        return allowDecision(updatedPermissions: [suggestion])
    }

    return allowDecision()
}

func handleNotification(_ input: [String: Any]) {
    if shouldSuppressBecauseUserIsActive(event: "Notification", input: input) {
        return
    }

    if stringValue(input, "hook_event_name") == "StopFailure" {
        let title = titleFor(input, "Failed")
        let message = stringValue(input, "error").isEmpty ? "Claude Code stopped because of an error." : stringValue(input, "error")
        displayNotification(title: title, message: message, subtitle: stringValue(input, "cwd"))
        return
    }

    let kind = stringValue(input, "notification_type").isEmpty ? "notification" : stringValue(input, "notification_type")
    let suppliedTitle = stringValue(input, "title")
    let title = titleFor(input, suppliedTitle.isEmpty ? kind : suppliedTitle)
    let message = stringValue(input, "message").isEmpty ? "Claude Code needs your attention." : stringValue(input, "message")
    displayNotification(title: title, message: message, subtitle: stringValue(input, "cwd"))
}

func hasActiveBackgroundWork(_ input: [String: Any]) -> Bool {
    !arrayValue(input, "background_tasks").isEmpty || !arrayValue(input, "session_crons").isEmpty
}

func handleStop(_ input: [String: Any]) {
    if shouldSuppressBecauseUserIsActive(event: "Stop", input: input) {
        return
    }

    let label = hasActiveBackgroundWork(input) ? "Paused" : "Done"
    let title = titleFor(input, label)
    let summary = stringValue(input, "last_assistant_message").isEmpty
        ? "Claude Code finished responding."
        : truncate(stringValue(input, "last_assistant_message"), maxNotificationChars)
    displayNotification(title: title, message: summary, subtitle: stringValue(input, "cwd"))
}

func executablePath() -> String {
    let raw = CommandLine.arguments.first ?? "claude-code-sentinel"
    if raw.hasPrefix("/") {
        return raw
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(raw)
        .standardizedFileURL
        .path
}

func buildHookSettings(commandPath: String) -> [String: Any] {
    let command = commandPath.replacingOccurrences(of: "\"", with: "\\\"")
    return [
        "hooks": [
            "PreToolUse": [
                [
                    "matcher": "AskUserQuestion",
                    "hooks": [
                        [
                            "type": "command",
                            "command": "\"\(command)\" pre-tool-use"
                        ]
                    ]
                ]
            ],
            "PermissionRequest": [
                [
                    "matcher": "*",
                    "hooks": [
                        [
                            "type": "command",
                            "command": "\"\(command)\" permission-request"
                        ]
                    ]
                ]
            ],
            "Notification": [
                [
                    "matcher": "permission_prompt",
                    "hooks": [
                        [
                            "type": "command",
                            "command": "\"\(command)\" notification",
                            "async": true
                        ]
                    ]
                ],
                [
                    "matcher": "idle_prompt",
                    "hooks": [
                        [
                            "type": "command",
                            "command": "\"\(command)\" notification",
                            "async": true
                        ]
                    ]
                ]
            ],
            "Stop": [
                [
                    "hooks": [
                        [
                            "type": "command",
                            "command": "\"\(command)\" stop",
                            "async": true
                        ]
                    ]
                ]
            ],
            "StopFailure": [
                [
                    "hooks": [
                        [
                            "type": "command",
                            "command": "\"\(command)\" notification",
                            "async": true
                        ]
                    ]
                ]
            ]
        ]
    ]
}

func managedSettingsURL() -> URL {
    URL(fileURLWithPath: managedSettingsPath)
}

func readManagedSettings() throws -> [String: Any] {
    let url = managedSettingsURL()
    guard FileManager.default.fileExists(atPath: url.path) else {
        return [:]
    }
    return try parseJsonObject(from: Data(contentsOf: url))
}

func managedHooks(commandPath: String) -> [String: Any] {
    buildHookSettings(commandPath: commandPath)["hooks"] as? [String: Any] ?? [:]
}

func writeJsonObject(_ object: [String: Any], to url: URL) throws {
    var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    data.append(0x0A)
    try data.write(to: url)
}

func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

func writeManagedSettingsOrPrintSudo(_ settings: [String: Any]) throws -> Bool {
    let url = managedSettingsURL()
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeJsonObject(settings, to: url)
        return true
    } catch {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-code-sentinel-managed-settings-\(Int(Date().timeIntervalSince1970)).json")
        try writeJsonObject(settings, to: tempURL)
        let command = [
            "sudo mkdir -p",
            shellQuote(url.deletingLastPathComponent().path),
            "&&",
            "sudo cp",
            shellQuote(tempURL.path),
            shellQuote(url.path),
            "&&",
            "sudo chmod 644",
            shellQuote(url.path),
            "&&",
            "rm -f",
            shellQuote(tempURL.path)
        ].joined(separator: " ")

        fputs("""
        Unable to write \(url.path) without administrator privileges.
        Run this command to finish:

        \(command)

        """, stderr)
        return false
    }
}

func installManagedSettings(commandPath: String) throws {
    var settings = try readManagedSettings()
    settings["hooks"] = managedHooks(commandPath: commandPath)
    if try writeManagedSettingsOrPrintSudo(settings) {
        print("Installed managed Claude Code hooks at \(managedSettingsPath)")
    }
}

func uninstallManagedSettings() throws {
    var settings = try readManagedSettings()
    settings.removeValue(forKey: "hooks")
    if try writeManagedSettingsOrPrintSudo(settings) {
        print("Removed managed Claude Code hooks at \(managedSettingsPath)")
    }
}

func commandPaths(in value: Any) -> [String] {
    if let dictionary = value as? [String: Any] {
        return dictionary.flatMap { key, child in
            key == "command" ? [String(describing: child)] : commandPaths(in: child)
        }
    }
    if let array = value as? [Any] {
        return array.flatMap(commandPaths)
    }
    return []
}

func runDoctor() {
    let binary = executablePath()
    let fileManager = FileManager.default
    print("Claude Code Sentinel doctor")
    print("Binary: \(binary)")
    print("Binary exists: \(fileManager.isExecutableFile(atPath: binary) ? "yes" : "no")")
    print("Managed settings: \(managedSettingsPath)")

    do {
        let settings = try readManagedSettings()
        guard let hooks = settings["hooks"] else {
            print("Managed hooks: missing")
            return
        }
        let commands = commandPaths(in: hooks)
        let matching = commands.filter { $0.contains(binary) }
        print("Managed hooks: present")
        print("Hook commands: \(commands.count)")
        print("Commands pointing to this binary: \(matching.count)")
        if matching.count != commands.count {
            print("Warning: some hook commands point to a different binary.")
        }
    } catch {
        print("Managed settings read error: \(error)")
    }
}

func printUsage() {
    print("""
    Claude Code Sentinel

    Commands:
      claude-code-sentinel permission-request   Handle PermissionRequest hook JSON from stdin
      claude-code-sentinel pre-tool-use         Handle PreToolUse hook JSON from stdin
      claude-code-sentinel notification         Handle Notification hook JSON from stdin
      claude-code-sentinel stop                 Handle Stop hook JSON from stdin
      claude-code-sentinel print-settings       Print Claude Code hooks JSON
      claude-code-sentinel install-managed      Install hooks into Claude Code managed settings
      claude-code-sentinel uninstall-managed    Remove hooks from Claude Code managed settings
      claude-code-sentinel doctor               Check binary and managed hook configuration
      claude-code-sentinel sample-permission    Open a sample permission dialog
      claude-code-sentinel sample-stop          Send a sample completion notification
      claude-code-sentinel test                 Run lightweight self-tests
    """)
}

func sampleInput() -> [String: Any] {
    [
        "session_id": "sample-session-12345678",
        "cwd": FileManager.default.currentDirectoryPath,
        "hook_event_name": "PermissionRequest",
        "tool_name": "Bash",
        "tool_input": [
            "command": "npm test",
            "description": "Run the test suite"
        ],
        "permission_suggestions": [
            [
                "type": "addRules",
                "rules": [
                    ["toolName": "Bash", "ruleContent": "npm test"]
                ],
                "behavior": "allow",
                "destination": "localSettings"
            ]
        ]
    ]
}

func runTests() {
    let sample = sampleInput()
    precondition(projectName(["cwd": "/tmp/my-project"]) == "my-project")
    precondition(titleFor(["cwd": "/tmp/my-project", "session_id": "abc123456789"], "Done") == "my-project - Done - 23456789")
    precondition(formatToolInput(sample).contains("npm test"))
    let settings = buildHookSettings(commandPath: "/tmp/claude-code-sentinel")
    let hooks = settings["hooks"] as? [String: Any]
    precondition(hooks?["PermissionRequest"] != nil)
    precondition(hooks?["Notification"] != nil)
    precondition(hooks?["Stop"] != nil)
    precondition(!managedHooks(commandPath: "/tmp/claude-code-sentinel").isEmpty)
    precondition(shellQuote("/tmp/a b/c") == "'/tmp/a b/c'")
    print("All tests passed.")
}

func main() {
    let command = CommandLine.arguments.dropFirst().first ?? "help"

    do {
        switch command {
        case "help", "--help", "-h":
            printUsage()
        case "permission-request":
            let input = try parseHookInput(readStdinData())
            print(jsonString(handlePermissionRequest(input)))
        case "pre-tool-use":
            let input = try parseHookInput(readStdinData())
            print(jsonString(handlePreToolUse(input)))
        case "notification":
            let input = try parseHookInput(readStdinData())
            handleNotification(input)
        case "stop":
            let input = try parseHookInput(readStdinData())
            handleStop(input)
        case "print-settings":
            print(prettyJsonString(buildHookSettings(commandPath: executablePath())))
        case "install-managed":
            try installManagedSettings(commandPath: executablePath())
        case "uninstall-managed":
            try uninstallManagedSettings()
        case "doctor":
            runDoctor()
        case "sample-permission":
            print(prettyJsonString(handlePermissionRequest(sampleInput())))
        case "sample-stop":
            handleStop([
                "session_id": "sample-session-12345678",
                "cwd": FileManager.default.currentDirectoryPath,
                "hook_event_name": "Stop",
                "last_assistant_message": "Sample task finished.",
                "background_tasks": [],
                "session_crons": []
            ])
        case "test":
            runTests()
        case "where":
            print(executablePath())
        default:
            fputs("Unknown command: \(command)\n", stderr)
            printUsage()
            exit(1)
        }
    } catch {
        fputs("\(error)\n", stderr)
        exit(1)
    }
}

main()
