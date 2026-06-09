import Foundation
import AppKit
import CoreGraphics

let maxDialogChars = 2600
let maxNotificationChars = 180
let defaultActiveIdleThresholdSeconds = 8.0
let defaultActiveGraceSeconds = 15.0
let defaultIdleAfterStopSuppressionSeconds = 90.0
let activePollIntervalSeconds = 1.0
let dialogMinWidth: CGFloat = 440
let dialogMaxWidth: CGFloat = 520
let managedSettingsPath = "/Library/Application Support/ClaudeCode/managed-settings.json"
let openCodeConfigRelativePath = ".config/opencode/opencode.json"
let openCodePluginRelativePath = ".config/opencode/plugins/claude-code-sentinel.js"
var activeDialogHandlers: [NSObject] = []
var dialogMetaLine = ""

func readStdinData() -> Data {
    FileHandle.standardInput.readDataToEndOfFile()
}

func readPayloadData() throws -> Data {
    let args = CommandLine.arguments
    if let index = args.firstIndex(of: "--payload-base64"), index + 1 < args.count {
        let encoded = args[index + 1]
        guard let data = Data(base64Encoded: encoded) else {
            throw NSError(domain: "ClaudeCodeSentinel", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid --payload-base64 value"
            ])
        }
        return data
    }
    return readStdinData()
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

func jsonStringLiteral(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(escaped)\""
}

func prettyJsonString(_ value: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    return String(data: data, encoding: .utf8)!
}

func isMeaningfulText(_ value: String) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

func recursiveStringValue(_ value: Any, keys: Set<String>) -> String? {
    if let dictionary = value as? [String: Any] {
        for key in keys {
            if let text = dictionary[key] as? String, isMeaningfulText(text) {
                return text
            }
        }
        for child in dictionary.values {
            if let text = recursiveStringValue(child, keys: keys) {
                return text
            }
        }
    }
    if let array = value as? [Any] {
        for child in array {
            if let text = recursiveStringValue(child, keys: keys) {
                return text
            }
        }
    }
    return nil
}

func permissionRuleSummary(_ input: [String: Any]) -> String {
    let suggestions = arrayValue(input, "permission_suggestions")
    let ruleLines = suggestions.flatMap { suggestion -> [String] in
        let behavior = suggestion["behavior"] as? String ?? "allow"
        let rules = suggestion["rules"] as? [[String: Any]] ?? []
        return rules.map { rule in
            let name = rule["toolName"] as? String ?? stringValue(input, "tool_name")
            let content = rule["ruleContent"] as? String ?? "*"
            return "- \(behavior): \(name)\(content.isEmpty ? "" : " \(content)")"
        }
    }
    return ruleLines.joined(separator: "\n")
}

func inferredPermissionPrompt(tool: String, filePath: String?) -> String {
    guard let filePath, isMeaningfulText(filePath) else {
        return "Claude Code is requesting permission for \(tool.isEmpty ? "this tool" : tool)."
    }

    let fileName = URL(fileURLWithPath: filePath).lastPathComponent
    switch tool {
    case "Write":
        return "Do you want to create \(fileName.isEmpty ? filePath : fileName)?"
    case "Edit":
        return "Do you want to edit \(fileName.isEmpty ? filePath : fileName)?"
    case "Read":
        return "Do you want to read \(fileName.isEmpty ? filePath : fileName)?"
    default:
        return "Claude Code is requesting permission for \(tool)."
    }
}

func formatToolInput(_ input: [String: Any]) -> String {
    let tool = stringValue(input, "tool_name")
    let toolInput = dictValue(input, "tool_input")

    if tool == "Bash" {
        let command = (toolInput["command"] as? String)
            ?? recursiveStringValue(input, keys: ["command", "cmd", "script"])
        var parts: [String] = []
        if let description = (toolInput["description"] as? String)
            ?? recursiveStringValue(input, keys: ["description", "summary"]),
           isMeaningfulText(description) {
            parts.append("Description:\n\(description)")
        }
        if let command, isMeaningfulText(command) {
            parts.append("Command:\n\(command)")
        }
        let rules = permissionRuleSummary(input)
        if isMeaningfulText(rules) {
            parts.append("Permission options:\n\(rules)")
        }
        if !parts.isEmpty {
            return parts.joined(separator: "\n\n")
        }
    }

    if ["Edit", "Write", "Read"].contains(tool) {
        let filePath = (toolInput["file_path"] as? String)
            ?? recursiveStringValue(input, keys: ["file_path", "filePath", "path"])
        var parts = [inferredPermissionPrompt(tool: tool, filePath: filePath)]
        if let filePath, isMeaningfulText(filePath) {
            parts.append("File:\n\(filePath)")
        }
        if !toolInput.isEmpty {
            parts.append("Input:\n\(prettyJsonString(toolInput))")
        }
        let rules = permissionRuleSummary(input)
        if isMeaningfulText(rules) {
            parts.append("Permission options:\n\(rules)")
        }
        return parts.joined(separator: "\n\n")
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

    let renderedInput = toolInput.isEmpty ? "" : prettyJsonString(toolInput)
    if isMeaningfulText(renderedInput) {
        return renderedInput
    }

    let rules = permissionRuleSummary(input)
    if isMeaningfulText(rules) {
        return "Claude Code is requesting permission for \(tool.isEmpty ? "this tool" : tool).\n\nPermission options:\n\(rules)"
    }

    let payload = prettyJsonString(input)
    if isMeaningfulText(payload) {
        return "Claude Code is requesting permission for \(tool.isEmpty ? "this tool" : tool).\n\nHook payload:\n\(payload)"
    }

    return "Claude Code is requesting permission."
}

func openCodePermission(_ input: [String: Any]) -> [String: Any] {
    dictValue(input, "permission")
}

func openCodeDirectory(_ input: [String: Any]) -> String {
    let directory = stringValue(input, "directory")
    if isMeaningfulText(directory) {
        return directory
    }
    let worktree = stringValue(input, "worktree")
    if isMeaningfulText(worktree) {
        return worktree
    }
    return FileManager.default.currentDirectoryPath
}

func openCodeNormalizedInput(_ input: [String: Any]) -> [String: Any] {
    let permission = openCodePermission(input)
    let properties = dictValue(input, "properties")
    return [
        "cwd": openCodeDirectory(input),
        "session_id": stringValue(permission, "sessionID").isEmpty ? stringValue(properties, "sessionID") : stringValue(permission, "sessionID"),
        "tool_name": stringValue(permission, "type")
    ]
}

func stringDescription(_ value: Any?) -> String {
    guard let value else {
        return ""
    }
    if let text = value as? String {
        return text
    }
    return String(describing: value)
}

func lastPathComponent(_ path: String) -> String {
    URL(fileURLWithPath: path).lastPathComponent
}

func firstMeaningfulText(_ values: String...) -> String {
    values.first(where: isMeaningfulText) ?? ""
}

func diffFilePath(_ diff: String) -> String {
    for line in diff.components(separatedBy: .newlines) {
        if line.hasPrefix("Index: ") {
            return String(line.dropFirst("Index: ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if line.hasPrefix("+++ ") {
            let value = String(line.dropFirst("+++ ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.hasPrefix("b/") || value.hasPrefix("a/") ? String(value.dropFirst(2)) : value
        }
    }
    return ""
}

func compactDiffPreview(_ diff: String) -> String {
    var added = 0
    var removed = 0
    var preview: [String] = []
    for line in diff.components(separatedBy: .newlines) {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("Index: ") || line.hasPrefix("====") {
            continue
        }
        if line.hasPrefix("+") {
            added += 1
            if preview.count < 8 {
                preview.append(line)
            }
        } else if line.hasPrefix("-") {
            removed += 1
            if preview.count < 8 {
                preview.append(line)
            }
        }
    }

    var parts = ["Diff: +\(added) -\(removed)"]
    if !preview.isEmpty {
        parts.append("Preview:\n\(preview.joined(separator: "\n"))")
    }
    return parts.joined(separator: "\n\n")
}

func formatOpenCodePermission(_ input: [String: Any]) -> String {
    let permission = openCodePermission(input)
    let permissionType = stringValue(permission, "type")
    let title = stringValue(permission, "title")
    let metadata = dictValue(permission, "metadata")
    let command = firstMeaningfulText(
        stringValue(metadata, "command"),
        stringDescription(permission["command"]),
        stringDescription(permission["pattern"])
    )
    let diff = stringValue(metadata, "diff")
    let path = firstMeaningfulText(
        stringValue(metadata, "path"),
        stringValue(metadata, "file"),
        stringValue(metadata, "filePath"),
        diffFilePath(diff)
    )

    var parts: [String] = []
    if isMeaningfulText(title) {
        parts.append(title)
    } else if isMeaningfulText(command) {
        parts.append("OpenCode wants to run a command.")
    } else if isMeaningfulText(path) {
        parts.append("OpenCode wants to edit \(lastPathComponent(path)).")
    } else {
        parts.append("OpenCode is requesting permission for \(permissionType.isEmpty ? "this action" : permissionType).")
    }
    if isMeaningfulText(command) {
        parts.append("Command:\n\(command)")
    }
    if isMeaningfulText(path) {
        parts.append("File:\n\(path)")
    }
    if isMeaningfulText(diff) {
        parts.append(compactDiffPreview(diff))
    }
    return parts.joined(separator: "\n\n")
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
    let selections: [String]

    init(canceled: Bool, button: String?, selections: [String] = []) {
        self.canceled = canceled
        self.button = button
        self.selections = selections
    }
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

final class HoverChoiceButton: NSButton {
    private let normalBackground = NSColor(calibratedWhite: 0.955, alpha: 1)
    private let hoverBackground = NSColor(calibratedRed: 0, green: 0.36, blue: 1, alpha: 1)
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        prepare()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        prepare()
    }

    private func prepare() {
        isBordered = false
        alignment = .left
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = normalBackground.cgColor
        contentTintColor = .labelColor
        cell?.wraps = true
        cell?.lineBreakMode = .byWordWrapping
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setTitleColor(.labelColor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    private func setHovered(_ hovered: Bool) {
        animateBackground(to: hovered ? hoverBackground : normalBackground)
        setTitleColor(hovered ? .white : .labelColor)
    }

    private func animateBackground(to color: NSColor) {
        guard let layer else {
            return
        }
        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        animation.toValue = color.cgColor
        animation.duration = 0.2
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "backgroundColor")
        layer.backgroundColor = color.cgColor
    }

    private func setTitleColor(_ color: NSColor) {
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: color,
                .paragraphStyle: {
                    let style = NSMutableParagraphStyle()
                    style.lineBreakMode = .byWordWrapping
                    style.alignment = .left
                    return style
                }()
            ]
        )
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
    let initialTextWidth = dialogMaxWidth - 40
    textView.frame = NSRect(x: 0, y: 0, width: initialTextWidth, height: 120)
    textView.autoresizingMask = [.width]
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
    textView.textContainer?.containerSize = NSSize(width: initialTextWidth, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.lineBreakMode = .byCharWrapping
    textView.textContainerInset = NSSize(width: monospaced ? 12 : 0, height: monospaced ? 10 : 0)
    textView.textContainer?.lineFragmentPadding = 0
    if let textContainer = textView.textContainer {
        textView.layoutManager?.ensureLayout(for: textContainer)
    }

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
    button.layer?.cornerRadius = 9
    button.layer?.backgroundColor = NSColor(calibratedWhite: 0.955, alpha: 1).cgColor
    button.contentTintColor = .labelColor
    button.cell?.wraps = true
    button.cell?.lineBreakMode = .byWordWrapping
    button.attributedTitle = NSAttributedString(
        string: button.title,
        attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: {
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byWordWrapping
                style.alignment = .left
                return style
            }()
        ]
    )
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    button.setContentHuggingPriority(.defaultLow, for: .horizontal)
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
        selectedOptions = [value]
        window.close()
        NSApplication.shared.stop(nil)
    }
    let multiHandler = MultiChoiceHandler {
        let selections = options.filter { selectedOptions.contains($0) }
        selected = selections.joined(separator: ", ")
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
            let button = HoverChoiceButton(title: option, target: choiceHandler, action: #selector(ChoiceButtonHandler.select(_:)))
            choiceButtonStyle(button)
            NSLayoutConstraint.activate([button.heightAnchor.constraint(greaterThanOrEqualToConstant: 36)])
            return button
        }
    }

    let optionStack = NSStackView(views: optionViews)
    optionStack.orientation = .vertical
    optionStack.spacing = 8
    optionStack.alignment = .leading
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
    optionStack.widthAnchor.constraint(equalTo: optionScroll.contentView.widthAnchor).isActive = true
    for optionView in optionViews {
        optionView.widthAnchor.constraint(equalTo: optionStack.widthAnchor).isActive = true
    }
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
    let selections = selectedOptions.isEmpty
        ? selected.map { [$0] } ?? []
        : options.filter { selectedOptions.contains($0) }
    return DialogResult(canceled: canceled || selected == nil, button: selected, selections: selections)
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
        body.heightAnchor.constraint(greaterThanOrEqualToConstant: 88),

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

func idleAfterStopSuppressionSeconds() -> Double {
    let raw = ProcessInfo.processInfo.environment["CLAUDE_SENTINEL_IDLE_AFTER_STOP_SECONDS"] ?? ""
    if let value = Double(raw), value >= 0 {
        return value
    }
    return defaultIdleAfterStopSuppressionSeconds
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

func stateDirectory() -> URL {
    let directory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/ClaudeCodeSentinel", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

func recentStopsPath() -> URL {
    stateDirectory().appendingPathComponent("recent-stops.json")
}

func sessionStateKey(_ input: [String: Any]) -> String {
    let session = stringValue(input, "session_id")
    let cwd = stringValue(input, "cwd")
    if session.isEmpty && cwd.isEmpty {
        return "unknown"
    }
    return "\(session)|\(cwd)"
}

func readRecentStops() -> [String: TimeInterval] {
    guard let data = try? Data(contentsOf: recentStopsPath()),
          let decoded = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Double] else {
        return [:]
    }
    return decoded
}

func writeRecentStops(_ stops: [String: TimeInterval]) {
    guard let data = try? JSONSerialization.data(withJSONObject: stops, options: [.sortedKeys]) else {
        return
    }
    try? data.write(to: recentStopsPath(), options: [.atomic])
}

func recordStop(_ input: [String: Any], now: Date = Date()) {
    let cutoff = now.timeIntervalSince1970 - max(idleAfterStopSuppressionSeconds(), 0)
    var stops = readRecentStops().filter { $0.value >= cutoff }
    stops[sessionStateKey(input)] = now.timeIntervalSince1970
    writeRecentStops(stops)
}

func shouldSuppressIdlePromptAfterRecentStop(_ input: [String: Any], now: Date = Date()) -> Bool {
    guard stringValue(input, "notification_type") == "idle_prompt" else {
        return false
    }

    let window = idleAfterStopSuppressionSeconds()
    if window <= 0 {
        return false
    }

    let key = sessionStateKey(input)
    guard let stoppedAt = readRecentStops()[key] else {
        return false
    }

    let age = now.timeIntervalSince1970 - stoppedAt
    if age < 0 || age > window {
        return false
    }

    appendDebugLog([
        "event": "Notification",
        "notificationType": stringValue(input, "notification_type"),
        "project": projectName(input),
        "session": sessionSuffix(input),
        "decision": "suppress-recent-stop",
        "secondsAfterStop": String(format: "%.1f", age),
        "suppressionSeconds": String(format: "%.1f", window)
    ])
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

func handleOpenCodePermission(_ input: [String: Any]) -> [String: Any] {
    let normalized = openCodeNormalizedInput(input)
    if shouldSuppressBecauseUserIsActive(event: "OpenCodePermission", input: normalized) {
        return ["action": "terminal"]
    }

    let permission = openCodePermission(input)
    let permissionType = stringValue(permission, "type")
    let title = titleFor(normalized, "\(permissionType.isEmpty ? "OpenCode" : permissionType) permission")
    let cwd = openCodeDirectory(input)
    dialogMetaLine = "\(permissionType.isEmpty ? "unknown action" : permissionType)  -  \(cwd)"
    let body = truncate(formatOpenCodePermission(input), maxDialogChars)

    let alwaysLabel = "Yes, always"
    let choice = displayDialog(
        title: title,
        message: body,
        buttons: ["No", "Yes", alwaysLabel],
        defaultButton: "Yes",
        cancelButton: "No"
    )

    if choice.canceled || choice.button == "No" {
        return ["response": "reject"]
    }
    if choice.button == alwaysLabel {
        return ["response": "always"]
    }
    return ["response": "once"]
}

func handleOpenCodeNotification(_ input: [String: Any]) {
    let eventType = stringValue(input, "type")
    let normalized = openCodeNormalizedInput(input)
    if shouldSuppressBecauseUserIsActive(event: "OpenCodeNotification", input: normalized) {
        return
    }

    let label = eventType == "session.error" ? "Failed" : (eventType == "tool.question" ? "Question" : "Done")
    let title = titleFor(normalized, label)
    let message: String
    if eventType == "session.error" {
        let error = input["error"] ?? dictValue(input, "properties")["error"] ?? "OpenCode session failed."
        message = String(describing: error)
    } else if eventType == "tool.question" {
        message = "OpenCode is asking a question in the terminal."
    } else {
        message = "OpenCode session is idle."
    }
    displayNotification(title: title, message: message, subtitle: openCodeDirectory(input))
}

func handleOpenCodeQuestion(_ input: [String: Any]) -> [String: Any] {
    let request = dictValue(input, "question")
    let normalized: [String: Any] = [
        "cwd": openCodeDirectory(input),
        "session_id": stringValue(request, "sessionID"),
        "tool_name": "question"
    ]
    if shouldSuppressBecauseUserIsActive(event: "OpenCodeQuestion", input: normalized) {
        return ["action": "terminal"]
    }

    let questions = arrayValue(request, "questions")
    if questions.isEmpty {
        return ["action": "terminal"]
    }

    let meta = "OpenCode question  -  \(openCodeDirectory(input))"
    var answers: [[String]] = []
    for (index, question) in questions.enumerated() {
        let questionText = stringValue(question, "question").isEmpty ? "Choose an option" : stringValue(question, "question")
        let header = stringValue(question, "header")
        let options = arrayValue(question, "options").compactMap { option -> String? in
            let label = stringValue(option, "label")
            return isMeaningfulText(label) ? label : nil
        }
        if options.isEmpty {
            return ["action": "terminal"]
        }

        let multiSelect = question["multiple"] as? Bool ?? false
        let title = titleFor(normalized, "\(header.isEmpty ? "Question" : header) \(index + 1)/\(questions.count)")
        let choice = displayChoiceDialog(
            title: title,
            meta: meta,
            question: questionText,
            options: options,
            multiSelect: multiSelect
        )

        if choice.canceled || choice.selections.isEmpty {
            return ["action": "reject"]
        }
        answers.append(choice.selections)
    }

    return [
        "action": "reply",
        "answers": answers
    ]
}

func handleNotification(_ input: [String: Any]) {
    if shouldSuppressIdlePromptAfterRecentStop(input) {
        return
    }

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
    recordStop(input)

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

func openCodeConfigURL() -> URL {
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(openCodeConfigRelativePath)
}

func openCodePluginURL() -> URL {
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(openCodePluginRelativePath)
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

func readJsonObject(at url: URL) throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: url.path) else {
        return [:]
    }
    return try parseJsonObject(from: Data(contentsOf: url))
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

func openCodePluginSource(commandPath: String) -> String {
    let binary = jsonStringLiteral(commandPath)
    return """
    import { appendFileSync, mkdirSync } from "node:fs"
    import { homedir } from "node:os"
    import { join } from "node:path"

    const sentinel = \(binary)
    const logDir = join(homedir(), "Library", "Logs", "ClaudeCodeSentinel")
    const logFile = join(logDir, "opencode-plugin.log")

    function log(message, extra) {
      try {
        mkdirSync(logDir, { recursive: true })
        const suffix = extra === undefined ? "" : ` ${JSON.stringify(extra)}`
        appendFileSync(logFile, `[${new Date().toISOString()}] ${message}${suffix}\\n`)
      } catch {
        // Never let diagnostic logging break OpenCode.
      }
    }

    function runSentinel(command, payload) {
      const encoded = Buffer.from(JSON.stringify(payload), "utf8").toString("base64")
      const result = Bun.spawnSync([sentinel, command, "--payload-base64", encoded], {
        stdout: "pipe",
        stderr: "pipe",
      })
      if (result.exitCode !== 0) {
        const stderr = new TextDecoder().decode(result.stderr).trim()
        throw new Error(stderr || `claude-code-sentinel ${command} failed`)
      }
      return new TextDecoder().decode(result.stdout).trim()
    }

    function questionQuery(directory, worktree) {
      return worktree?.startsWith?.("wrk")
        ? { directory, workspace: worktree }
        : { directory }
    }

    async function replyQuestion(client, requestID, directory, worktree, answers) {
      if (!client._client?.post) throw new Error("OpenCode raw client is unavailable")
      return await client._client.post({
        url: "/question/{requestID}/reply",
        path: { requestID },
        query: questionQuery(directory, worktree),
        body: { answers },
        headers: { "Content-Type": "application/json" },
      })
    }

    async function rejectQuestion(client, requestID, directory, worktree) {
      if (!client._client?.post) throw new Error("OpenCode raw client is unavailable")
      return await client._client.post({
        url: "/question/{requestID}/reject",
        path: { requestID },
        query: questionQuery(directory, worktree),
        headers: { "Content-Type": "application/json" },
      })
    }

    export const ClaudeCodeSentinel = async ({ client, directory, worktree, serverUrl }) => {
      log("plugin.init", { directory, worktree, serverUrl: String(serverUrl), clientKeys: Object.keys(client || {}) })

      return {
        event: async ({ event }) => {
          if (event.type === "permission.updated" || event.type === "permission.asked") {
            const permission = event.properties
            log("permission.asked", { id: permission.id, sessionID: permission.sessionID, type: permission.type, directory })
            const output = runSentinel("opencode-permission", {
              type: event.type,
              directory,
              worktree,
              permission,
            })
            const result = JSON.parse(output)
            if (result.action === "terminal") {
              log("permission.noop", { id: permission.id, sessionID: permission.sessionID, action: result.action })
              return
            }
            const response = result.response || "reject"
            log("permission.result", { id: permission.id, sessionID: permission.sessionID, response })
            try {
              const reply = await client.postSessionIdPermissionsPermissionId({
                path: {
                  id: permission.sessionID,
                  permissionID: permission.id,
                },
                query: { directory },
                body: { response },
              })
              log("permission.reply.ok", { id: permission.id, reply })
              if (reply?.error) throw new Error(JSON.stringify(reply.error))
            } catch (error) {
              log("permission.reply.error", { id: permission.id, error: String(error), stack: error?.stack })
              throw error
            }
            return
          }

          if (event.type === "question.asked") {
            const question = event.properties
            log("question.asked", { id: question.id, directory, worktree, serverUrl: String(serverUrl), questions: question.questions?.length })
            const output = runSentinel("opencode-question", {
              type: event.type,
              directory,
              worktree,
              question,
            })
            const result = JSON.parse(output)
            log("question.result", { id: question.id, result })
            if (result.action === "reply") {
              try {
                const response = await replyQuestion(client, question.id, directory, worktree, result.answers)
                log("question.reply.ok", { id: question.id, response })
                if (response?.error) throw new Error(JSON.stringify(response.error))
              } catch (error) {
                log("question.reply.error", { id: question.id, error: String(error), stack: error?.stack })
                throw error
              }
            } else if (result.action === "reject") {
              try {
                const response = await rejectQuestion(client, question.id, directory, worktree)
                log("question.reject.ok", { id: question.id, response })
                if (response?.error) throw new Error(JSON.stringify(response.error))
              } catch (error) {
                log("question.reject.error", { id: question.id, error: String(error), stack: error?.stack })
                throw error
              }
            } else {
              log("question.noop", { id: question.id, action: result.action })
            }
            return
          }

          if (event.type === "session.idle" || event.type === "session.error") {
            runSentinel("opencode-notification", {
              type: event.type,
              directory,
              worktree,
              properties: event.properties,
            })
            return
          }

          if (event.type === "tool.execute.before" && event.properties?.tool === "question") {
            runSentinel("opencode-notification", {
              type: "tool.question",
              directory,
              worktree,
              properties: event.properties,
            })
          }
        },
      }
    }
    """
}

func mergedOpenCodeConfig(_ config: [String: Any]) -> [String: Any] {
    var updated = config
    if updated["$schema"] == nil {
        updated["$schema"] = "https://opencode.ai/config.json"
    }

    if updated["permission"] == nil {
        updated["permission"] = [
            "edit": "ask",
            "bash": "ask"
        ]
        return updated
    }

    guard var permissions = updated["permission"] as? [String: Any] else {
        return updated
    }
    if permissions["edit"] == nil {
        permissions["edit"] = "ask"
    }
    if permissions["bash"] == nil {
        permissions["bash"] = "ask"
    }
    updated["permission"] = permissions
    return updated
}

func installOpenCode(commandPath: String) throws {
    let pluginURL = openCodePluginURL()
    try FileManager.default.createDirectory(at: pluginURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try openCodePluginSource(commandPath: commandPath).write(to: pluginURL, atomically: true, encoding: .utf8)

    let configURL = openCodeConfigURL()
    try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let config = try readJsonObject(at: configURL)
    try writeJsonObject(mergedOpenCodeConfig(config), to: configURL)

    print("Installed OpenCode plugin at \(pluginURL.path)")
    print("Updated OpenCode config at \(configURL.path)")
}

func uninstallOpenCode() throws {
    let pluginURL = openCodePluginURL()
    if FileManager.default.fileExists(atPath: pluginURL.path) {
        try FileManager.default.removeItem(at: pluginURL)
        print("Removed OpenCode plugin at \(pluginURL.path)")
    } else {
        print("OpenCode plugin not found at \(pluginURL.path)")
    }
    print("OpenCode permission settings were left unchanged at \(openCodeConfigURL().path)")
}

func runOpenCodeDoctor() {
    let pluginURL = openCodePluginURL()
    let configURL = openCodeConfigURL()
    let fileManager = FileManager.default
    print("Claude Code Sentinel OpenCode doctor")
    print("Plugin: \(pluginURL.path)")
    print("Plugin exists: \(fileManager.fileExists(atPath: pluginURL.path) ? "yes" : "no")")
    print("Config: \(configURL.path)")
    do {
        let config = try readJsonObject(at: configURL)
        let permission = config["permission"]
        print("Config exists: \(fileManager.fileExists(atPath: configURL.path) ? "yes" : "no")")
        print("Permission config: \(permission == nil ? "missing" : "present")")
        if let permissions = permission as? [String: Any] {
            print("edit permission: \(permissions["edit"] ?? "missing")")
            print("bash permission: \(permissions["bash"] ?? "missing")")
        }
    } catch {
        print("OpenCode config read error: \(error)")
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
      claude-code-sentinel opencode-permission  Handle OpenCode permission JSON from stdin
      claude-code-sentinel opencode-notification Handle OpenCode notification JSON from stdin
      claude-code-sentinel opencode-question    Handle OpenCode question JSON from stdin
      claude-code-sentinel print-settings       Print Claude Code hooks JSON
      claude-code-sentinel install-managed      Install hooks into Claude Code managed settings
      claude-code-sentinel install-opencode     Install OpenCode plugin and permission config
      claude-code-sentinel uninstall-managed    Remove hooks from Claude Code managed settings
      claude-code-sentinel uninstall-opencode   Remove OpenCode plugin
      claude-code-sentinel doctor               Check binary and managed hook configuration
      claude-code-sentinel doctor-opencode      Check OpenCode plugin configuration
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
    precondition(formatToolInput([
        "tool_name": "Write",
        "tool_input": ["file_path": "/tmp/bubbleSort.js"]
    ]).contains("Do you want to create bubbleSort.js?"))
    precondition(formatToolInput([
        "tool_name": "Edit",
        "tool_input": [
            "file_path": "/tmp/universalEdit.vue",
            "old_string": "onSearch={(value) => this.handleRuleCodeSearch(value)}",
            "new_string": "onFocus={() => { if (!row.ruleCode) this.ruleOptions = [] }}\nonSearch={(value) => this.handleRuleCodeSearch(value)}"
        ]
    ]).contains("Do you want to edit universalEdit.vue?"))
    precondition(formatToolInput([
        "tool_name": "Bash",
        "tool_input": [:],
        "permission_suggestions": [
            [
                "behavior": "allow",
                "rules": [["toolName": "Bash", "ruleContent": "node *"]]
            ]
        ]
    ]).contains("Permission options"))
    let settings = buildHookSettings(commandPath: "/tmp/claude-code-sentinel")
    let hooks = settings["hooks"] as? [String: Any]
    precondition(hooks?["PermissionRequest"] != nil)
    precondition(hooks?["Notification"] != nil)
    precondition(hooks?["Stop"] != nil)
    precondition(!managedHooks(commandPath: "/tmp/claude-code-sentinel").isEmpty)
    precondition(shellQuote("/tmp/a b/c") == "'/tmp/a b/c'")
    let stopInput: [String: Any] = [
        "session_id": "recent-stop-session",
        "cwd": "/tmp/recent-stop-project",
        "hook_event_name": "Stop"
    ]
    let idleInput: [String: Any] = [
        "session_id": "recent-stop-session",
        "cwd": "/tmp/recent-stop-project",
        "hook_event_name": "Notification",
        "notification_type": "idle_prompt"
    ]
    recordStop(stopInput, now: Date(timeIntervalSince1970: 1_000))
    precondition(shouldSuppressIdlePromptAfterRecentStop(idleInput, now: Date(timeIntervalSince1970: 1_060)))
    precondition(!shouldSuppressIdlePromptAfterRecentStop(idleInput, now: Date(timeIntervalSince1970: 1_200)))
    let openCodeConfig = mergedOpenCodeConfig([
        "$schema": "https://opencode.ai/config.json",
        "mcp": ["existing": ["enabled": true]],
        "permission": ["edit": "deny"]
    ])
    precondition((openCodeConfig["mcp"] as? [String: Any])?["existing"] != nil)
    let openCodePermissions = openCodeConfig["permission"] as? [String: Any]
    precondition(openCodePermissions?["edit"] as? String == "deny")
    precondition(openCodePermissions?["bash"] as? String == "ask")
    let plugin = openCodePluginSource(commandPath: "/tmp/claude-code-sentinel")
    precondition(plugin.contains("const sentinel = \"/tmp/claude-code-sentinel\""))
    precondition(plugin.contains("postSessionIdPermissionsPermissionId"))
    precondition(plugin.contains("permission.reply.ok"))
    precondition(plugin.contains("permission.noop"))
    precondition(plugin.contains("result.action === \"terminal\""))
    precondition(plugin.contains("replyQuestion(client"))
    precondition(plugin.contains("\"/question/{requestID}/reply\""))
    precondition(plugin.contains("\"/question/{requestID}/reject\""))
    precondition(formatOpenCodePermission([
        "permission": [
            "type": "bash",
            "title": "Run npm test",
            "pattern": "npm test",
            "metadata": ["command": "npm test"]
        ]
    ]).contains("Run npm test"))
    let openCodeDiffBody = formatOpenCodePermission([
        "permission": [
            "metadata": [
                "diff": """
                Index: /Users/hulongchao/Documents/code/test-code/bubble-sort.ts
                ===================================================================
                --- /Users/hulongchao/Documents/code/test-code/bubble-sort.ts
                +++ /Users/hulongchao/Documents/code/test-code/bubble-sort.ts
                @@
                +function bubbleSort(items: number[]): number[] {
                +  return items
                +}
                """
            ]
        ]
    ])
    precondition(openCodeDiffBody.contains("OpenCode wants to edit bubble-sort.ts."))
    precondition(openCodeDiffBody.contains("Diff: +3 -0"))
    precondition(!openCodeDiffBody.contains("Metadata:"))
    precondition(!openCodeDiffBody.contains("Permission:"))
    precondition((handleOpenCodeQuestion([
        "question": [
            "id": "question-1",
            "sessionID": "session-12345678",
            "questions": [
                [
                    "question": "Pick one",
                    "header": "Choice",
                    "options": []
                ]
            ]
        ]
    ])["action"] as? String) == "terminal")
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
        case "opencode-permission":
            let input = try parseHookInput(readPayloadData())
            print(jsonString(handleOpenCodePermission(input)))
        case "opencode-notification":
            let input = try parseHookInput(readPayloadData())
            handleOpenCodeNotification(input)
        case "opencode-question":
            let input = try parseHookInput(readPayloadData())
            print(jsonString(handleOpenCodeQuestion(input)))
        case "print-settings":
            print(prettyJsonString(buildHookSettings(commandPath: executablePath())))
        case "install-managed":
            try installManagedSettings(commandPath: executablePath())
        case "install-opencode":
            try installOpenCode(commandPath: executablePath())
        case "uninstall-managed":
            try uninstallManagedSettings()
        case "uninstall-opencode":
            try uninstallOpenCode()
        case "doctor":
            runDoctor()
        case "doctor-opencode":
            runOpenCodeDoctor()
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
