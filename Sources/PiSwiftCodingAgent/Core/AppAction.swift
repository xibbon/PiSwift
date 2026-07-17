public enum AppAction: String, CaseIterable, Sendable {
    case interrupt
    case clear
    case exit
    case suspend
    case cycleThinkingLevel
    case cycleModelForward
    case cycleModelBackward
    case selectModel
    case expandTools
    case toggleThinking
    case externalEditor
    case followUp
    case dequeue
    case pasteImage
    case copyMessage
}
