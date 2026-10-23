import PiSwiftChord

/// Selects whether limits keep the beginning or the end of output.
public typealias OutputRetention = PiSwiftChord.OutputRetention
/// Maximum retained bytes and lines, and which end of the output to keep.
public typealias OutputLimits = PiSwiftChord.OutputLimits
/// Retained output and the counts removed by its limits.
public typealias BoundedOutput = PiSwiftChord.BoundedOutput
/// A retained text range and its byte and line counts.
public typealias OutputSlice = PiSwiftChord.OutputSlice
/// A bounded output stream.
public typealias OutputBuffer = PiSwiftChord.OutputBuffer
/// An output stream cannot apply the supplied skip metadata.
public typealias OutputBufferError = PiSwiftChord.OutputBufferError

/// Removes control characters that must not enter visible tool output.
public func sanitizeOutput(_ text: String) -> String { PiSwiftChord.sanitizeOutput(text) }
/// Retains the selected end of text within byte and line limits.
public func boundOutput(_ text: String, limits: OutputLimits) -> OutputSlice {
    PiSwiftChord.boundOutput(text, limits: limits)
}
internal func characterEnd(_ bytes: [UInt8], at index: Int) -> Int {
    PiSwiftChord.characterEnd(bytes, at: index)
}
