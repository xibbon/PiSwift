import Foundation
import Testing
@testable import PiSwiftCodingAgent

/// Tests for prompt template argument parsing and substitution.
///
/// Tests verify:
/// - Argument parsing with quotes and special characters
/// - Placeholder substitution ($1, $2, $@, $ARGUMENTS)
/// - No recursive substitution of patterns in argument values
/// - Edge cases and integration between parsing and substitution

// MARK: - substituteArgs tests

@Test func substituteArgsReplacesArgumentsWithAllArgsJoined() {
    #expect(substituteArgs("Test: $ARGUMENTS", ["a", "b", "c"]) == "Test: a b c")
}

@Test func substituteArgsReplacesAtWithAllArgsJoined() {
    #expect(substituteArgs("Test: $@", ["a", "b", "c"]) == "Test: a b c")
}

@Test func substituteArgsAtAndArgumentsAreIdentical() {
    let args = ["foo", "bar", "baz"]
    #expect(substituteArgs("Test: $@", args) == substituteArgs("Test: $ARGUMENTS", args))
}

@Test func substituteArgsDoesNotRecursivelySubstitutePatterns() {
    // CRITICAL: argument values containing patterns should remain literal
    #expect(substituteArgs("$ARGUMENTS", ["$1", "$ARGUMENTS"]) == "$1 $ARGUMENTS")
    #expect(substituteArgs("$@", ["$100", "$1"]) == "$100 $1")
    #expect(substituteArgs("$ARGUMENTS", ["$100", "$1"]) == "$100 $1")
}

@Test func substituteArgsSupportsMixedPositionalAndArguments() {
    #expect(substituteArgs("$1: $ARGUMENTS", ["prefix", "a", "b"]) == "prefix: prefix a b")
}

@Test func substituteArgsSupportsMixedPositionalAndAt() {
    #expect(substituteArgs("$1: $@", ["prefix", "a", "b"]) == "prefix: prefix a b")
}

@Test func substituteArgsHandlesEmptyArgsWithArguments() {
    #expect(substituteArgs("Test: $ARGUMENTS", []) == "Test: ")
}

@Test func substituteArgsHandlesEmptyArgsWithAt() {
    #expect(substituteArgs("Test: $@", []) == "Test: ")
}

@Test func substituteArgsHandlesEmptyArgsWithPositional() {
    #expect(substituteArgs("Test: $1", []) == "Test: ")
}

@Test func substituteArgsHandlesMultipleOccurrencesOfArguments() {
    #expect(substituteArgs("$ARGUMENTS and $ARGUMENTS", ["a", "b"]) == "a b and a b")
}

@Test func substituteArgsHandlesMultipleOccurrencesOfAt() {
    #expect(substituteArgs("$@ and $@", ["a", "b"]) == "a b and a b")
}

@Test func substituteArgsHandlesMixedOccurrencesOfAtAndArguments() {
    #expect(substituteArgs("$@ and $ARGUMENTS", ["a", "b"]) == "a b and a b")
}

@Test func substituteArgsHandlesSpecialCharactersInArguments() {
    #expect(substituteArgs("$1 $2: $ARGUMENTS", ["arg100", "@user"]) == "arg100 @user: arg100 @user")
}

@Test func substituteArgsHandlesOutOfRangeNumberedPlaceholders() {
    // Out-of-range placeholders become empty strings
    #expect(substituteArgs("$1 $2 $3 $4 $5", ["a", "b"]) == "a b   ")
}

@Test func substituteArgsHandlesUnicodeCharacters() {
    #expect(substituteArgs("$ARGUMENTS", ["日本語", "🎉", "café"]) == "日本語 🎉 café")
}

@Test func substituteArgsPreservesNewlinesAndTabs() {
    #expect(substituteArgs("$1 $2", ["line1\nline2", "tab\tthere"]) == "line1\nline2 tab\tthere")
}

@Test func substituteArgsHandlesConsecutiveDollarPatterns() {
    #expect(substituteArgs("$1$2", ["a", "b"]) == "ab")
}

@Test func substituteArgsHandlesQuotedArgumentsWithSpaces() {
    #expect(substituteArgs("$ARGUMENTS", ["first arg", "second arg"]) == "first arg second arg")
}

@Test func substituteArgsHandlesSingleArgumentWithArguments() {
    #expect(substituteArgs("Test: $ARGUMENTS", ["only"]) == "Test: only")
}

@Test func substituteArgsHandlesSingleArgumentWithAt() {
    #expect(substituteArgs("Test: $@", ["only"]) == "Test: only")
}

@Test func substituteArgsHandlesZeroIndex() {
    #expect(substituteArgs("$0", ["a", "b"]) == "")
}

@Test func substituteArgsHandlesDecimalNumberInPattern() {
    // Only integer part matches
    #expect(substituteArgs("$1.5", ["a"]) == "a.5")
}

@Test func substituteArgsHandlesArgumentsAsPartOfWord() {
    #expect(substituteArgs("pre$ARGUMENTS", ["a", "b"]) == "prea b")
}

@Test func substituteArgsHandlesAtAsPartOfWord() {
    #expect(substituteArgs("pre$@", ["a", "b"]) == "prea b")
}

@Test func substituteArgsHandlesEmptyArgumentsInMiddle() {
    #expect(substituteArgs("$ARGUMENTS", ["a", "", "c"]) == "a  c")
}

@Test func substituteArgsHandlesTrailingAndLeadingSpaces() {
    #expect(substituteArgs("$ARGUMENTS", ["  leading  ", "trailing  "]) == "  leading   trailing  ")
}

@Test func substituteArgsHandlesArgumentContainingPatternPartially() {
    #expect(substituteArgs("Prefix $ARGUMENTS suffix", ["ARGUMENTS"]) == "Prefix ARGUMENTS suffix")
}

@Test func substituteArgsHandlesNonMatchingPatterns() {
    #expect(substituteArgs("$A $$ $ $ARGS", ["a"]) == "$A $$ $ $ARGS")
}

@Test func substituteArgsIsCaseSensitive() {
    #expect(substituteArgs("$arguments $Arguments $ARGUMENTS", ["a", "b"]) == "$arguments $Arguments a b")
}

@Test func substituteArgsBothSyntaxesSameResult() {
    let args = ["x", "y", "z"]
    let result1 = substituteArgs("$@ and $ARGUMENTS", args)
    let result2 = substituteArgs("$ARGUMENTS and $@", args)
    #expect(result1 == result2)
    #expect(result1 == "x y z and x y z")
}

@Test func substituteArgsHandlesVeryLongArgumentLists() {
    let args = (0..<100).map { "arg\($0)" }
    let result = substituteArgs("$ARGUMENTS", args)
    #expect(result == args.joined(separator: " "))
}

@Test func substituteArgsHandlesNumberedPlaceholdersSingleDigit() {
    #expect(substituteArgs("$1 $2 $3", ["a", "b", "c"]) == "a b c")
}

@Test func substituteArgsHandlesNumberedPlaceholdersMultipleDigits() {
    let args = (0..<15).map { "val\($0)" }
    #expect(substituteArgs("$10 $12 $15", args) == "val9 val11 val14")
}

@Test func substituteArgsHandlesEscapedDollarSigns() {
    // Note: No escape mechanism exists - backslash is treated as start of \$100 which matches $100
    #expect(substituteArgs("Price: \\$100", []) == "Price: \\")
}

@Test func substituteArgsHandlesMixedNumberedAndWildcard() {
    #expect(substituteArgs("$1: $@ ($ARGUMENTS)", ["first", "second", "third"]) == "first: first second third (first second third)")
}

@Test func substituteArgsSupportsDefaultValuesForMissingArgs() {
    #expect(substituteArgs("Target: ${1:-world}", []) == "Target: world")
    #expect(substituteArgs("Target: ${1:-world}", ["repo"]) == "Target: repo")
}

@Test func substituteArgsUsesDefaultValuesForEmptyArgs() {
    #expect(substituteArgs("${1:-fallback} ${2:-second}", ["", "value"]) == "fallback value")
}

@Test func substituteArgsDefaultValuesAreNotRecursivelyExpanded() {
    #expect(substituteArgs("${1:-$2 $ARGUMENTS}", []) == "$2 $ARGUMENTS")
}

@Test func substituteArgsSupportsArgsFromNthOnward() {
    #expect(substituteArgs("Rest: ${@:2}", ["one", "two", "three"]) == "Rest: two three")
    #expect(substituteArgs("Rest: ${@:1}", ["one", "two"]) == "Rest: one two")
    #expect(substituteArgs("Rest: ${@:0}", ["one", "two"]) == "Rest: one two")
}

@Test func substituteArgsSupportsArgsSliceLength() {
    #expect(substituteArgs("Slice: ${@:2:2}", ["one", "two", "three", "four"]) == "Slice: two three")
    #expect(substituteArgs("Slice: ${@:3:10}", ["one", "two", "three"]) == "Slice: three")
    #expect(substituteArgs("Slice: ${@:4:1}", ["one", "two", "three"]) == "Slice: ")
}

@Test func substituteArgsHandlesCommandWithNoPlaceholders() {
    #expect(substituteArgs("Just plain text", ["a", "b"]) == "Just plain text")
}

@Test func substituteArgsHandlesCommandWithOnlyPlaceholders() {
    #expect(substituteArgs("$1 $2 $@", ["a", "b", "c"]) == "a b a b c")
}

// MARK: - parseCommandArgs tests

@Test func parseCommandArgsSimpleSpaceSeparated() {
    #expect(parseCommandArgs("a b c") == ["a", "b", "c"])
}

@Test func parseCommandArgsQuotedArgumentsWithSpaces() {
    #expect(parseCommandArgs("\"first arg\" second") == ["first arg", "second"])
}

@Test func parseCommandArgsSingleQuotedArguments() {
    #expect(parseCommandArgs("'first arg' second") == ["first arg", "second"])
}

@Test func parseCommandArgsMixedQuoteStyles() {
    #expect(parseCommandArgs("\"double\" 'single' \"double again\"") == ["double", "single", "double again"])
}

@Test func parseCommandArgsEmptyString() {
    #expect(parseCommandArgs("") == [])
}

@Test func parseCommandArgsExtraSpaces() {
    #expect(parseCommandArgs("a  b   c") == ["a", "b", "c"])
}

@Test func parseCommandArgsTabsAsSeparators() {
    #expect(parseCommandArgs("a\tb\tc") == ["a", "b", "c"])
}

@Test func parseCommandArgsQuotedEmptyString() {
    // Empty quotes are skipped by current implementation
    #expect(parseCommandArgs("\"\" \" \"") == [" "])
}

@Test func parseCommandArgsSpecialCharacters() {
    #expect(parseCommandArgs("$100 @user #tag") == ["$100", "@user", "#tag"])
}

@Test func parseCommandArgsUnicodeCharacters() {
    #expect(parseCommandArgs("日本語 🎉 café") == ["日本語", "🎉", "café"])
}

@Test func parseCommandArgsNewlinesInArguments() {
    #expect(parseCommandArgs("\"line1\nline2\" second") == ["line1\nline2", "second"])
}

@Test func parseCommandArgsEscapedQuotesInQuotedStrings() {
    // This implementation doesn't handle escaped quotes - backslash is literal
    // Input: "quoted \"text\""
    // The \" ends the quote, so we get: quoted \text\
    #expect(parseCommandArgs("\"quoted \\\"text\\\"\"") == ["quoted \\text\\"])
}

@Test func parseCommandArgsTrailingSpaces() {
    #expect(parseCommandArgs("a b c   ") == ["a", "b", "c"])
}

@Test func parseCommandArgsLeadingSpaces() {
    #expect(parseCommandArgs("   a b c") == ["a", "b", "c"])
}

// MARK: - Integration tests

@Test func parseAndSubstituteTogetherCorrectly() {
    let input = "Button \"onClick handler\" \"disabled support\""
    let args = parseCommandArgs(input)
    let template = "Create component $1 with features: $ARGUMENTS"
    let result = substituteArgs(template, args)
    #expect(result == "Create component Button with features: Button onClick handler disabled support")
}

@Test func parseAndSubstituteReadmeExample() {
    let input = "Button \"onClick handler\" \"disabled support\""
    let args = parseCommandArgs(input)
    let template = "Create a React component named $1 with features: $ARGUMENTS"
    let result = substituteArgs(template, args)
    #expect(result == "Create a React component named Button with features: Button onClick handler disabled support")
}

@Test func parseAndSubstituteSameResultWithBothSyntaxes() {
    let args = parseCommandArgs("feature1 feature2 feature3")
    let template1 = "Implement: $@"
    let template2 = "Implement: $ARGUMENTS"
    #expect(substituteArgs(template1, args) == substituteArgs(template2, args))
}
