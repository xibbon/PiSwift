import MiniTui
import PiSwiftCodingAgent

@MainActor
public protocol EditorComponent: AnyObject {
    var onSubmit: ((String) -> Void)? { get set }
    var onChange: ((String) -> Void)? { get set }
    var disableSubmit: Bool { get set }
    var borderColor: @Sendable (String) -> String { get set }
    func setText(_ text: String)
    func getText() -> String
    func getExpandedText() -> String
    func insertTextAtCursor(_ text: String)
    func addToHistory(_ text: String)
    func setAutocompleteProvider(_ provider: AutocompleteProvider)
    func setAutocompleteMaxVisible(_ maxVisible: Int)
    func isShowingAutocomplete() -> Bool
    func invalidate()
}

public typealias EditorComponentView = Component & EditorComponent
