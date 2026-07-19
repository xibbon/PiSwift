// Code Review Extension (ported from pi-review/review.ts)
//
// Provides a `/review` command that prompts the agent to review code changes.
// Supports multiple review modes:
// - Review a GitHub pull request (checks out the PR locally)
// - Review against a base branch (PR style)
// - Review uncommitted changes
// - Review a specific commit
// - Shared custom review instructions (applied to all review modes when configured)
//
// Usage:
// - `/review` - show interactive selector
// - `/review pr 123` - review PR #123 (checks out locally)
// - `/review pr https://github.com/owner/repo/pull/123` - review PR from URL
// - `/review uncommitted` - review uncommitted changes directly
// - `/review branch main` - review against main branch
// - `/review commit abc123` - review specific commit
// - `/review folder src docs` - review specific folders/files (snapshot, not diff)
// - `/review --extra "focus on performance regressions"` - add extra review instruction
//
// Project-specific review guidelines:
// - If a REVIEW_GUIDELINES.md file exists in the same directory as .pi,
//   its contents are appended to the review prompt.
//
// Note: PR review requires a clean working tree (no uncommitted changes to tracked files).

import Foundation
import PiSwiftAI
import PiSwiftCodingAgent

#if !canImport(UIKit)

// MARK: - State

// State to track fresh session review (where we branched from).
// Only one review can be active at a time — the UI and /end-review command
// assume a single active review, matching the upstream extension.
private actor ReviewSessionStore {
    var reviewOriginId: String?
    var endReviewInProgress = false
    var reviewCustomInstructions: String?

    func setOrigin(_ id: String?) { reviewOriginId = id }
    func setCustomInstructions(_ instructions: String?) {
        let trimmed = instructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        reviewCustomInstructions = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    func beginEndReview() -> Bool {
        if endReviewInProgress { return false }
        endReviewInProgress = true
        return true
    }

    func finishEndReview() { endReviewInProgress = false }
}

private let store = ReviewSessionStore()

private let REVIEW_STATE_TYPE = "review-session"
private let REVIEW_ANCHOR_TYPE = "review-anchor"
private let REVIEW_SETTINGS_TYPE = "review-settings"
private let GH_SETUP_INSTRUCTIONS =
    "Install GitHub CLI (`gh`) from https://cli.github.com/ (macOS: `brew install gh`), then sign in with `gh auth login` and verify with `gh auth status`."
private let PR_CHECKOUT_BLOCKED_BY_PENDING_CHANGES_MESSAGE =
    "Cannot checkout PR: you have uncommitted changes. Please commit or stash them first."

private struct ReviewSessionState {
    var active: Bool
    var originId: String?
}

// MARK: - Review targets

private enum ReviewTarget {
    case uncommitted
    case baseBranch(branch: String)
    case commit(sha: String, title: String?)
    case pullRequest(prNumber: Int, baseBranch: String, title: String)
    case folder(paths: [String])
}

// MARK: - Prompts (adapted from Codex)

private let UNCOMMITTED_PROMPT =
    "Review the current code changes (staged, unstaged, and untracked files) and provide prioritized findings."

private func baseBranchPromptWithMergeBase(_ baseBranch: String, _ mergeBaseSha: String) -> String {
    "Review the code changes against the base branch '\(baseBranch)'. The merge base commit for this comparison is \(mergeBaseSha). Run `git diff \(mergeBaseSha)` to inspect the changes relative to \(baseBranch). Provide prioritized, actionable findings."
}

private func baseBranchPromptFallback(_ branch: String) -> String {
    "Review the code changes against the base branch '\(branch)'. Start by finding the merge diff between the current branch and \(branch)'s upstream e.g. (`git merge-base HEAD \"$(git rev-parse --abbrev-ref \"\(branch)@{upstream}\")\"`), then run `git diff` against that SHA to see what changes we would merge into the \(branch) branch. Provide prioritized, actionable findings."
}

private func commitPrompt(_ sha: String, _ title: String?) -> String {
    if let title, !title.isEmpty {
        return "Review the code changes introduced by commit \(sha) (\"\(title)\"). Provide prioritized, actionable findings."
    }
    return "Review the code changes introduced by commit \(sha). Provide prioritized, actionable findings."
}

private func pullRequestPrompt(_ prNumber: Int, _ title: String, _ baseBranch: String, _ mergeBaseSha: String?) -> String {
    if let mergeBaseSha {
        return "Review pull request #\(prNumber) (\"\(title)\") against the base branch '\(baseBranch)'. The merge base commit for this comparison is \(mergeBaseSha). Run `git diff \(mergeBaseSha)` to inspect the changes that would be merged. Provide prioritized, actionable findings."
    }
    return "Review pull request #\(prNumber) (\"\(title)\") against the base branch '\(baseBranch)'. Start by finding the merge base between the current branch and \(baseBranch) (e.g., `git merge-base HEAD \(baseBranch)`), then run `git diff` against that SHA to see the changes that would be merged. Provide prioritized, actionable findings."
}

private func folderReviewPrompt(_ paths: [String]) -> String {
    "Review the code in the following paths: \(paths.joined(separator: ", ")). This is a snapshot review (not a diff). Read the files directly in these paths and provide prioritized, actionable findings."
}

// The detailed review rubric (adapted from Codex's review_prompt.md)
private let REVIEW_RUBRIC = #"""
# Review Guidelines

You are acting as a code reviewer for a proposed code change made by another engineer.

Below are default guidelines for determining what to flag. These are not the final word — if you encounter more specific guidelines elsewhere (in a developer message, user message, file, or project review guidelines appended below), those override these general instructions.

## Determining what to flag

Flag issues that:
1. Meaningfully impact the accuracy, performance, security, or maintainability of the code.
2. Are discrete and actionable (not general issues or multiple combined issues).
3. Don't demand rigor inconsistent with the rest of the codebase.
4. Were introduced in the changes being reviewed (not pre-existing bugs).
5. The author would likely fix if aware of them.
6. Don't rely on unstated assumptions about the codebase or author's intent.
7. Have provable impact on other parts of the code — it is not enough to speculate that a change may disrupt another part, you must identify the parts that are provably affected.
8. Are clearly not intentional changes by the author.
9. Be particularly careful with untrusted user input and follow the specific guidelines to review.
10. Treat silent local error recovery (especially parsing/IO/network fallbacks) as high-signal review candidates unless there is explicit boundary-level justification.

## Untrusted User Input

1. Be careful with open redirects, they must always be checked to only go to trusted domains (?next_page=...)
2. Always flag SQL that is not parametrized
3. In systems with user supplied URL input, http fetches always need to be protected against access to local resources (intercept DNS resolver!)
4. Escape, don't sanitize if you have the option (eg: HTML escaping)

## Comment guidelines

1. Be clear about why the issue is a problem.
2. Communicate severity appropriately - don't exaggerate.
3. Be brief - at most 1 paragraph.
4. Keep code snippets under 3 lines, wrapped in inline code or code blocks.
5. Use ```suggestion blocks ONLY for concrete replacement code (minimal lines; no commentary inside the block). Preserve the exact leading whitespace of the replaced lines.
6. Explicitly state scenarios/environments where the issue arises.
7. Use a matter-of-fact tone - helpful AI assistant, not accusatory.
8. Write for quick comprehension without close reading.
9. Avoid excessive flattery or unhelpful phrases like "Great job...".

## Review priorities

1. Surface critical non-blocking human callouts (migrations, dependency churn, auth/permissions, compatibility, destructive operations) at the end.
2. Prefer simple, direct solutions over wrappers or abstractions without clear value.
3. Treat back pressure handling as critical to system stability.
4. Apply system-level thinking; flag changes that increase operational risk or on-call wakeups.
5. Ensure that errors are always checked against codes or stable identifiers, never error messages.

## Fail-fast error handling (strict)

When reviewing added or modified error handling, default to fail-fast behavior.

1. Evaluate every new or changed `try/catch`: identify what can fail and why local handling is correct at that exact layer.
2. Prefer propagation over local recovery. If the current scope cannot fully recover while preserving correctness, rethrow (optionally with context) instead of returning fallbacks.
3. Flag catch blocks that hide failure signals (e.g. returning `null`/`[]`/`false`, swallowing JSON parse failures, logging-and-continue, or "best effort" silent recovery).
4. JSON parsing/decoding should fail loudly by default. Quiet fallback parsing is only acceptable with an explicit compatibility requirement and clear tested behavior.
5. Boundary handlers (HTTP routes, CLI entrypoints, supervisors) may translate errors, but must not pretend success or silently degrade.
6. If a catch exists only to satisfy lint/style without real handling, treat it as a bug.
7. When uncertain, prefer crashing fast over silent degradation.

## Required human callouts (non-blocking, at the very end)

After findings/verdict, you MUST append this final section:

## Human Reviewer Callouts (Non-Blocking)

Include only applicable callouts (no yes/no lines):

- **This change adds a database migration:** <files/details>
- **This change introduces a new dependency:** <package(s)/details>
- **This change changes a dependency (or the lockfile):** <files/package(s)/details>
- **This change modifies auth/permission behavior:** <what changed and where>
- **This change introduces backwards-incompatible public schema/API/contract changes:** <what changed and where>
- **This change includes irreversible or destructive operations:** <operation and scope>
- **This change adds or removes feature flags:** <feature flags changed> (call out re-use of dormant feature flags!)
- **This change changes configuration defaults:** <config var changed>

Rules for this section:
1. These are informational callouts for the human reviewer, not fix items.
2. Do not include them in Findings unless there is an independent defect.
3. These callouts alone must not change the verdict.
4. Only include callouts that apply to the reviewed change.
5. Keep each emitted callout bold exactly as written.
6. If none apply, write "- (none)".

## Priority levels

Tag each finding with a priority level in the title:
- [P0] - Drop everything to fix. Blocking release/operations. Only for universal issues that do not depend on assumptions about inputs.
- [P1] - Urgent. Should be addressed in the next cycle.
- [P2] - Normal. To be fixed eventually.
- [P3] - Low. Nice to have.

## Output format

Provide your findings in a clear, structured format:
1. List each finding with its priority tag, file location, and explanation.
2. Findings must reference locations that overlap with the actual diff — don't flag pre-existing code.
3. Keep line references as short as possible (avoid ranges over 5-10 lines; pick the most suitable subrange).
4. Provide an overall verdict: "correct" (no blocking issues) or "needs attention" (has blocking issues).
5. Ignore trivial style issues unless they obscure meaning or violate documented standards.
6. Do not generate a full PR fix — only flag issues and optionally provide short suggestion blocks.
7. End with the required "Human Reviewer Callouts (Non-Blocking)" section and all applicable bold callouts (no yes/no).

Output all findings the author would fix if they knew about them. If there are no qualifying findings, explicitly state the code looks good. Don't stop at the first finding - list every qualifying issue. Then append the required non-blocking callouts section.
"""#

// Custom prompt for review summaries - focuses on preserving actionable findings
private let REVIEW_SUMMARY_PROMPT = #"""
We are leaving a code-review branch and returning to the main coding branch.
Create a structured handoff that can be used immediately to implement fixes.

You MUST summarize the review that happened in this branch so findings can be acted on.
Do not omit findings: include every actionable issue that was identified.

Required sections (in order):

## Review Scope
- What was reviewed (files/paths, changes, and scope)

## Verdict
- "correct" or "needs attention"

## Findings
For EACH finding, include:
- Priority tag ([P0]..[P3]) and short title
- File location (`path/to/file.ext:line`)
- Why it matters (brief)
- What should change (brief, actionable)

## Fix Queue
1. Ordered implementation checklist (highest priority first)

## Constraints & Preferences
- Any constraints or preferences mentioned during review
- Or "(none)"

## Human Reviewer Callouts (Non-Blocking)
Include only applicable callouts (no yes/no lines):
- **This change adds a database migration:** <files/details>
- **This change introduces a new dependency:** <package(s)/details>
- **This change changes a dependency (or the lockfile):** <files/package(s)/details>
- **This change modifies auth/permission behavior:** <what changed and where>
- **This change introduces backwards-incompatible public schema/API/contract changes:** <what changed and where>
- **This change includes irreversible or destructive operations:** <operation and scope>

If none apply, write "- (none)".

These are informational callouts for humans and are not fix items by themselves.

Preserve exact file paths, function names, and error messages where available.
"""#

private let REVIEW_FIX_FINDINGS_PROMPT = #"""
Use the latest review summary in this session and implement the review findings now.

Instructions:
1. Treat the summary's Findings/Fix Queue as a checklist.
2. Fix in priority order: P0, P1, then P2 (include P3 if quick and safe).
3. If a finding is invalid/already fixed/not possible right now, briefly explain why and continue.
4. Treat "Human Reviewer Callouts (Non-Blocking)" as informational only; do not convert them into fix tasks unless there is a separate explicit finding.
5. Follow fail-fast error handling: do not add local catch/fallback recovery unless this scope is an explicit boundary that can safely translate the failure.
6. If you add or keep a `try/catch`, explain the expected failure mode and either rethrow with context or return a boundary-safe error response.
7. JSON parsing/decoding should fail loudly by default; avoid silent fallback parsing.
8. Run relevant tests/checks for touched code where practical.
9. End with: fixed items, deferred/skipped items (with reasons), and verification results.
"""#

// MARK: - Session state helpers

@MainActor
private func setReviewWidget(ui: HookUIContext, hasUI: Bool, active: Bool) {
    guard hasUI else { return }
    if !active {
        ui.setWidget("review", nil)
        return
    }
    let theme = ui.theme
    ui.setWidget("review", .lines([theme.fg(.warning, "Review session active, return with /end-review")]))
}

private func decodeReviewState(_ data: AnyCodable?) -> ReviewSessionState? {
    guard let dict = data?.value as? [String: Any] else { return nil }
    return ReviewSessionState(
        active: dict["active"] as? Bool ?? false,
        originId: dict["originId"] as? String
    )
}

private func getReviewState(_ sessionManager: SessionManager) -> ReviewSessionState? {
    var state: ReviewSessionState?
    for entry in sessionManager.getBranch() {
        if case .custom(let custom) = entry, custom.customType == REVIEW_STATE_TYPE {
            state = decodeReviewState(custom.data)
        }
    }
    return state
}

private func getReviewSettingsCustomInstructions(_ sessionManager: SessionManager) -> String? {
    var instructions: String?
    for entry in sessionManager.getEntries() {
        if case .custom(let custom) = entry, custom.customType == REVIEW_SETTINGS_TYPE {
            let dict = custom.data?.value as? [String: Any]
            instructions = dict?["customInstructions"] as? String
        }
    }
    let trimmed = instructions?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (trimmed?.isEmpty ?? true) ? nil : trimmed
}

private func applyAllReviewState(ui: HookUIContext, hasUI: Bool, sessionManager: SessionManager) async {
    await store.setCustomInstructions(getReviewSettingsCustomInstructions(sessionManager))

    let state = getReviewState(sessionManager)
    if let state, state.active, let originId = state.originId {
        await store.setOrigin(originId)
        await setReviewWidget(ui: ui, hasUI: hasUI, active: true)
        return
    }

    await store.setOrigin(nil)
    await setReviewWidget(ui: ui, hasUI: hasUI, active: false)
}

// MARK: - Project review guidelines

private func loadProjectReviewGuidelines(cwd: String) -> String? {
    var currentDir = URL(fileURLWithPath: cwd).standardizedFileURL.path

    while true {
        let piDir = (currentDir as NSString).appendingPathComponent(".pi")
        let guidelinesPath = (currentDir as NSString).appendingPathComponent("REVIEW_GUIDELINES.md")

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: piDir, isDirectory: &isDir), isDir.boolValue {
            guard let content = try? String(contentsOfFile: guidelinesPath, encoding: .utf8) else {
                return nil
            }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        let parentDir = (currentDir as NSString).deletingLastPathComponent
        if parentDir == currentDir {
            return nil
        }
        currentDir = parentDir
    }
}

// MARK: - Git helpers

/// Run a command, treating spawn failures as a nonzero exit.
private func run(_ pi: ExtensionAPI, _ command: String, _ args: [String]) async -> ExecResult {
    do {
        return try await pi.exec(command, args)
    } catch {
        return ExecResult(stdout: "", stderr: "\(error)", code: 127, killed: false)
    }
}

/// Get the merge base between HEAD and a branch
private func getMergeBase(_ pi: ExtensionAPI, _ branch: String) async -> String? {
    // First try to get the upstream tracking branch
    let upstream = await run(pi, "git", ["rev-parse", "--abbrev-ref", "\(branch)@{upstream}"])
    let upstreamName = upstream.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if upstream.code == 0, !upstreamName.isEmpty {
        let mergeBase = await run(pi, "git", ["merge-base", "HEAD", upstreamName])
        let sha = mergeBase.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if mergeBase.code == 0, !sha.isEmpty {
            return sha
        }
    }

    // Fall back to using the branch directly
    let mergeBase = await run(pi, "git", ["merge-base", "HEAD", branch])
    let sha = mergeBase.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if mergeBase.code == 0, !sha.isEmpty {
        return sha
    }

    return nil
}

/// Get list of local branches
private func getLocalBranches(_ pi: ExtensionAPI) async -> [String] {
    let result = await run(pi, "git", ["branch", "--format=%(refname:short)"])
    guard result.code == 0 else { return [] }
    return result.stdout
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

/// Get list of recent commits
private func getRecentCommits(_ pi: ExtensionAPI, limit: Int = 10) async -> [(sha: String, title: String)] {
    let result = await run(pi, "git", ["log", "--oneline", "-n", "\(limit)"])
    guard result.code == 0 else { return [] }

    return result.stdout
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .map { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            let sha = parts.first.map(String.init) ?? line
            let title = parts.count > 1 ? String(parts[1]) : ""
            return (sha: sha, title: title)
        }
}

/// Check if there are uncommitted changes (staged, unstaged, or untracked)
private func hasUncommittedChanges(_ pi: ExtensionAPI) async -> Bool {
    let result = await run(pi, "git", ["status", "--porcelain"])
    return result.code == 0 && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// Check if there are changes that would prevent switching branches
/// (staged or unstaged changes to tracked files - untracked files are fine)
private func hasPendingChanges(_ pi: ExtensionAPI) async -> Bool {
    let result = await run(pi, "git", ["status", "--porcelain"])
    guard result.code == 0 else { return false }

    let trackedChanges = result.stdout
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("??") }
    return !trackedChanges.isEmpty
}

/// Parse a PR reference (URL or number) and return the PR number
private func parsePrReference(_ ref: String) -> Int? {
    let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)

    if let num = Int(trimmed), num > 0 {
        return num
    }

    // Formats: https://github.com/owner/repo/pull/123
    //          github.com/owner/repo/pull/123
    if let match = trimmed.firstMatch(of: /github\.com\/[^\/]+\/[^\/]+\/pull\/(\d+)/) {
        return Int(match.1)
    }

    return nil
}

/// Get PR information from GitHub CLI
private func getPrInfo(_ pi: ExtensionAPI, _ prNumber: Int) async -> (baseBranch: String, title: String, headBranch: String)? {
    let result = await run(pi, "gh", ["pr", "view", String(prNumber), "--json", "baseRefName,title,headRefName"])
    guard result.code == 0 else { return nil }

    guard let data = result.stdout.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let baseBranch = json["baseRefName"] as? String,
          let title = json["title"] as? String,
          let headBranch = json["headRefName"] as? String
    else {
        return nil
    }

    return (baseBranch: baseBranch, title: title, headBranch: headBranch)
}

/// Checkout a PR using GitHub CLI
private func checkoutPr(_ pi: ExtensionAPI, _ prNumber: Int) async -> (success: Bool, error: String?) {
    let result = await run(pi, "gh", ["pr", "checkout", String(prNumber)])
    if result.code != 0 {
        let error = !result.stderr.isEmpty ? result.stderr : (!result.stdout.isEmpty ? result.stdout : "Failed to checkout PR")
        return (success: false, error: error)
    }
    return (success: true, error: nil)
}

/// Get the current branch name
private func getCurrentBranch(_ pi: ExtensionAPI) async -> String? {
    let result = await run(pi, "git", ["branch", "--show-current"])
    let branch = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return (result.code == 0 && !branch.isEmpty) ? branch : nil
}

/// Get the default branch (main or master)
private func getDefaultBranch(_ pi: ExtensionAPI) async -> String {
    // Try to get from remote HEAD
    let result = await run(pi, "git", ["symbolic-ref", "refs/remotes/origin/HEAD", "--short"])
    let head = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if result.code == 0, !head.isEmpty {
        return head.replacingOccurrences(of: "origin/", with: "")
    }

    // Fall back to checking if main or master exists
    let branches = await getLocalBranches(pi)
    if branches.contains("main") { return "main" }
    if branches.contains("master") { return "master" }

    return "main"
}

// MARK: - Prompt building

private func buildReviewPrompt(_ pi: ExtensionAPI, _ target: ReviewTarget) async -> String {
    switch target {
    case .uncommitted:
        return UNCOMMITTED_PROMPT

    case .baseBranch(let branch):
        if let mergeBase = await getMergeBase(pi, branch) {
            return baseBranchPromptWithMergeBase(branch, mergeBase)
        }
        return baseBranchPromptFallback(branch)

    case .commit(let sha, let title):
        return commitPrompt(sha, title)

    case .pullRequest(let prNumber, let baseBranch, let title):
        let mergeBase = await getMergeBase(pi, baseBranch)
        return pullRequestPrompt(prNumber, title, baseBranch, mergeBase)

    case .folder(let paths):
        return folderReviewPrompt(paths)
    }
}

/// Get user-facing hint for the review target
private func getUserFacingHint(_ target: ReviewTarget) -> String {
    switch target {
    case .uncommitted:
        return "current changes"
    case .baseBranch(let branch):
        return "changes against '\(branch)'"
    case .commit(let sha, let title):
        let shortSha = String(sha.prefix(7))
        if let title, !title.isEmpty {
            return "commit \(shortSha): \(title)"
        }
        return "commit \(shortSha)"
    case .pullRequest(let prNumber, _, let title):
        let shortTitle = title.count > 30 ? String(title.prefix(27)) + "..." : title
        return "PR #\(prNumber): \(shortTitle)"
    case .folder(let paths):
        let joined = paths.joined(separator: ", ")
        return joined.count > 40 ? "folders: \(joined.prefix(37))..." : "folders: \(joined)"
    }
}

// MARK: - Argument parsing

private enum ParsedTarget {
    case target(ReviewTarget)
    case pr(ref: String)
}

private struct ParsedReviewArgs {
    var target: ParsedTarget?
    var extraInstruction: String?
    var error: String?
}

private func tokenizeArgs(_ value: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    var quote: Character? = nil
    var index = value.startIndex

    while index < value.endIndex {
        let char = value[index]

        if let activeQuote = quote {
            if char == "\\", value.index(after: index) < value.endIndex {
                index = value.index(after: index)
                current.append(value[index])
                index = value.index(after: index)
                continue
            }
            if char == activeQuote {
                quote = nil
                index = value.index(after: index)
                continue
            }
            current.append(char)
            index = value.index(after: index)
            continue
        }

        if char == "\"" || char == "'" {
            quote = char
            index = value.index(after: index)
            continue
        }

        if char.isWhitespace {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
            index = value.index(after: index)
            continue
        }

        current.append(char)
        index = value.index(after: index)
    }

    if !current.isEmpty {
        tokens.append(current)
    }

    return tokens
}

private func parseReviewPaths(_ value: String) -> [String] {
    value
        .split(whereSeparator: { $0.isWhitespace })
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

private func parseArgs(_ args: String) -> ParsedReviewArgs {
    let trimmedArgs = args.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedArgs.isEmpty { return ParsedReviewArgs() }

    let rawParts = tokenizeArgs(trimmedArgs)
    var parts: [String] = []
    var extraInstruction: String?

    var i = 0
    while i < rawParts.count {
        let part = rawParts[i]
        if part == "--extra" {
            guard i + 1 < rawParts.count else {
                return ParsedReviewArgs(error: "Missing value for --extra")
            }
            extraInstruction = rawParts[i + 1]
            i += 2
            continue
        }

        if part.hasPrefix("--extra=") {
            extraInstruction = String(part.dropFirst("--extra=".count))
            i += 1
            continue
        }

        parts.append(part)
        i += 1
    }

    if parts.isEmpty {
        return ParsedReviewArgs(extraInstruction: extraInstruction)
    }

    switch parts[0].lowercased() {
    case "uncommitted":
        return ParsedReviewArgs(target: .target(.uncommitted), extraInstruction: extraInstruction)

    case "branch":
        guard parts.count > 1 else { return ParsedReviewArgs(extraInstruction: extraInstruction) }
        return ParsedReviewArgs(target: .target(.baseBranch(branch: parts[1])), extraInstruction: extraInstruction)

    case "commit":
        guard parts.count > 1 else { return ParsedReviewArgs(extraInstruction: extraInstruction) }
        let title = parts.count > 2 ? parts[2...].joined(separator: " ") : nil
        return ParsedReviewArgs(target: .target(.commit(sha: parts[1], title: title)), extraInstruction: extraInstruction)

    case "folder":
        let paths = parseReviewPaths(parts.dropFirst().joined(separator: " "))
        guard !paths.isEmpty else { return ParsedReviewArgs(extraInstruction: extraInstruction) }
        return ParsedReviewArgs(target: .target(.folder(paths: paths)), extraInstruction: extraInstruction)

    case "pr":
        guard parts.count > 1 else { return ParsedReviewArgs(extraInstruction: extraInstruction) }
        return ParsedReviewArgs(target: .pr(ref: parts[1]), extraInstruction: extraInstruction)

    default:
        return ParsedReviewArgs(extraInstruction: extraInstruction)
    }
}

// MARK: - Registration

/// Register the review extension on a `HookAPI`. Call this from a host that
/// constructs its config with `inlineExtensions: [PiReview.inlineExtension]`,
/// or rely on the exported `piExtensionMain` when building this target as a
/// standalone dylib plugin.
public enum PiReview {
    /// In-process extension descriptor for `CodingAgentConfig.inlineExtensions`.
    public static var inlineExtension: InlineExtension {
        InlineExtension(name: "review", factory: { registerReviewExtension($0) })
    }

    public static func register(_ pi: ExtensionAPI) {
        registerReviewExtension(pi)
    }
}

public func registerReviewExtension(_ pi: ExtensionAPI) {
    // MARK: Settings persistence

    @Sendable func persistReviewSettings() async {
        var data: [String: Any] = [:]
        if let instructions = await store.reviewCustomInstructions {
            data["customInstructions"] = instructions
        }
        pi.appendEntry(REVIEW_SETTINGS_TYPE, data)
    }

    @Sendable func setReviewCustomInstructions(_ instructions: String?) async {
        await store.setCustomInstructions(instructions)
        await persistReviewSettings()
    }

    // MARK: GitHub helpers

    @Sendable func ensureGithubCliReady(_ ctx: HookCommandContext) async -> Bool {
        let ghVersion = await run(pi, "gh", ["--version"])
        if ghVersion.code != 0 {
            await ctx.ui.notify("PR review requires GitHub CLI (`gh`). \(GH_SETUP_INSTRUCTIONS)", .error)
            return false
        }

        let ghAuthStatus = await run(pi, "gh", ["auth", "status"])
        if ghAuthStatus.code != 0 {
            await ctx.ui.notify(
                "GitHub CLI is installed, but you're not signed in. Run `gh auth login`, then verify with `gh auth status`.",
                .error
            )
            return false
        }

        return true
    }

    @Sendable func resolvePullRequestTarget(
        _ ctx: HookCommandContext,
        _ ref: String,
        skipInitialPendingChangesCheck: Bool = false
    ) async -> ReviewTarget? {
        guard await ensureGithubCliReady(ctx) else { return nil }

        if !skipInitialPendingChangesCheck, await hasPendingChanges(pi) {
            await ctx.ui.notify(PR_CHECKOUT_BLOCKED_BY_PENDING_CHANGES_MESSAGE, .error)
            return nil
        }

        guard let prNumber = parsePrReference(ref) else {
            await ctx.ui.notify("Invalid PR reference. Enter a number or GitHub PR URL.", .error)
            return nil
        }

        await ctx.ui.notify("Fetching PR #\(prNumber) info...", .info)
        guard let prInfo = await getPrInfo(pi, prNumber) else {
            await ctx.ui.notify(
                "Could not fetch PR #\(prNumber). Make sure it exists and your GitHub auth has access (check with `gh auth status`).",
                .error
            )
            return nil
        }

        // Re-check right before checkout to avoid switching branches with newly introduced changes.
        if await hasPendingChanges(pi) {
            await ctx.ui.notify(PR_CHECKOUT_BLOCKED_BY_PENDING_CHANGES_MESSAGE, .error)
            return nil
        }

        await ctx.ui.notify("Checking out PR #\(prNumber)...", .info)
        let checkoutResult = await checkoutPr(pi, prNumber)
        if !checkoutResult.success {
            await ctx.ui.notify("Failed to checkout PR: \(checkoutResult.error ?? "unknown error")", .error)
            return nil
        }

        await ctx.ui.notify("Checked out PR #\(prNumber) (\(prInfo.headBranch))", .info)

        return .pullRequest(prNumber: prNumber, baseBranch: prInfo.baseBranch, title: prInfo.title)
    }

    // MARK: Lifecycle events

    pi.on("session_start") { (_: SessionStartEvent, ctx: HookContext) -> Any? in
        await applyAllReviewState(ui: ctx.ui, hasUI: ctx.hasUI, sessionManager: ctx.sessionManager)
        return nil
    }

    pi.on("session_tree") { (_: SessionTreeEvent, ctx: HookContext) -> Any? in
        await applyAllReviewState(ui: ctx.ui, hasUI: ctx.hasUI, sessionManager: ctx.sessionManager)
        return nil
    }

    // MARK: Selectors

    /// Determine the smart default review type based on git state
    @Sendable func getSmartDefault() async -> String {
        // Priority 1: If there are uncommitted changes, default to reviewing them
        if await hasUncommittedChanges(pi) {
            return "uncommitted"
        }

        // Priority 2: If on a feature branch (not the default branch), default to PR-style review
        let currentBranch = await getCurrentBranch(pi)
        let defaultBranch = await getDefaultBranch(pi)
        if let currentBranch, currentBranch != defaultBranch {
            return "baseBranch"
        }

        // Priority 3: Default to reviewing a specific commit
        return "commit"
    }

    /// Show branch selector for base branch review
    @Sendable func showBranchSelector(_ ctx: HookCommandContext) async -> ReviewTarget? {
        let branches = await getLocalBranches(pi)
        let currentBranch = await getCurrentBranch(pi)
        let defaultBranch = await getDefaultBranch(pi)

        // Never offer the current branch as a base branch (reviewing against itself is meaningless).
        let candidateBranches = currentBranch != nil ? branches.filter { $0 != currentBranch } : branches

        if candidateBranches.isEmpty {
            let message = currentBranch != nil
                ? "No other branches found (current branch: \(currentBranch!))"
                : "No branches found"
            await ctx.ui.notify(message, .error)
            return nil
        }

        // Sort branches with default branch first
        let sortedBranches = candidateBranches.sorted { a, b in
            if a == defaultBranch { return true }
            if b == defaultBranch { return false }
            return a.localizedCompare(b) == .orderedAscending
        }

        let defaultSuffix = " (default)"
        let options = sortedBranches.map { $0 == defaultBranch ? $0 + defaultSuffix : $0 }
        guard let selection = await ctx.ui.select("Select base branch", options) else {
            return nil
        }

        let branch = selection.hasSuffix(defaultSuffix)
            ? String(selection.dropLast(defaultSuffix.count))
            : selection
        return .baseBranch(branch: branch)
    }

    /// Show commit selector
    @Sendable func showCommitSelector(_ ctx: HookCommandContext) async -> ReviewTarget? {
        let commits = await getRecentCommits(pi, limit: 20)

        if commits.isEmpty {
            await ctx.ui.notify("No commits found", .error)
            return nil
        }

        let options = commits.map { "\($0.sha.prefix(7)) \($0.title)" }
        guard let selection = await ctx.ui.select("Select commit to review", options),
              let index = options.firstIndex(of: selection)
        else {
            return nil
        }

        let commit = commits[index]
        return .commit(sha: commit.sha, title: commit.title)
    }

    /// Show folder input
    @Sendable func showFolderInput(_ ctx: HookCommandContext) async -> ReviewTarget? {
        guard let result = await ctx.ui.editor("Enter folders/files to review (space-separated or one per line):", ".") else {
            return nil
        }
        let paths = parseReviewPaths(result)
        guard !paths.isEmpty else { return nil }
        return .folder(paths: paths)
    }

    /// Show PR input and handle checkout
    @Sendable func showPrInput(_ ctx: HookCommandContext) async -> ReviewTarget? {
        // First check for pending changes that would prevent branch switching
        if await hasPendingChanges(pi) {
            await ctx.ui.notify(PR_CHECKOUT_BLOCKED_BY_PENDING_CHANGES_MESSAGE, .error)
            return nil
        }

        guard let prRef = await ctx.ui.input("Enter PR number or URL (e.g. 123 or https://github.com/owner/repo/pull/123):", nil),
              !prRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        return await resolvePullRequestTarget(ctx, prRef, skipInitialPendingChangesCheck: true)
    }

    /// Show the review preset selector
    @Sendable func showReviewSelector(_ ctx: HookCommandContext) async -> ReviewTarget? {
        let smartDefault = await getSmartDefault()

        // Review preset options (keep this order stable)
        let presets: [(value: String, label: String, description: String)] = [
            ("uncommitted", "Review uncommitted changes", ""),
            ("baseBranch", "Review against a base branch", "(local)"),
            ("commit", "Review a commit", ""),
            ("pullRequest", "Review a pull request", "(GitHub PR)"),
            ("folder", "Review a folder (or more)", "(snapshot, not diff)"),
        ]

        while true {
            let customInstructionsSet = await store.reviewCustomInstructions != nil
            let customInstructionsLabel = customInstructionsSet
                ? "Remove custom review instructions (currently set)"
                : "Add custom review instructions (applies to all review modes)"

            var options: [String] = presets.map { preset in
                var label = preset.label
                if !preset.description.isEmpty { label += " \(preset.description)" }
                if preset.value == smartDefault { label += " — suggested" }
                return label
            }
            options.append(customInstructionsLabel)

            guard let selection = await ctx.ui.select("Select a review preset", options) else {
                return nil
            }

            if selection == customInstructionsLabel {
                if customInstructionsSet {
                    await setReviewCustomInstructions(nil)
                    await ctx.ui.notify("Custom review instructions removed", .info)
                    continue
                }

                let customInstructions = await ctx.ui.editor(
                    "Enter custom review instructions (applies to all review modes):",
                    ""
                )

                guard let customInstructions,
                      !customInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    await ctx.ui.notify("Custom review instructions not changed", .info)
                    continue
                }

                await setReviewCustomInstructions(customInstructions)
                await ctx.ui.notify("Custom review instructions saved", .info)
                continue
            }

            guard let index = options.firstIndex(of: selection), index < presets.count else {
                return nil
            }

            switch presets[index].value {
            case "uncommitted":
                return .uncommitted

            case "baseBranch":
                if let target = await showBranchSelector(ctx) { return target }

            case "commit":
                if let target = await showCommitSelector(ctx) { return target }

            case "folder":
                if let target = await showFolderInput(ctx) { return target }

            case "pullRequest":
                if let target = await showPrInput(ctx) { return target }

            default:
                return nil
            }
        }
    }

    // MARK: Review execution

    @Sendable func executeReview(
        _ ctx: HookCommandContext,
        _ target: ReviewTarget,
        useFreshSession: Bool,
        extraInstruction: String?
    ) async -> Bool {
        // Check if we're already in a review
        if await store.reviewOriginId != nil {
            await ctx.ui.notify("Already in a review. Use /end-review to finish first.", .warning)
            return false
        }

        // Handle fresh session mode
        if useFreshSession {
            // Store current position (where we'll return to).
            // In an empty session there is no leaf yet, so create a lightweight anchor first.
            var originId = ctx.sessionManager.getLeafId()
            if originId == nil {
                pi.appendEntry(REVIEW_ANCHOR_TYPE, ["createdAt": ISO8601DateFormatter().string(from: Date())])
                originId = ctx.sessionManager.getLeafId()
            }
            guard let lockedOriginId = originId else {
                await ctx.ui.notify("Failed to determine review origin.", .error)
                return false
            }
            await store.setOrigin(lockedOriginId)

            // Find the first user message in the session.
            // If none exists (e.g. brand-new session), we'll stay on the current leaf.
            let firstUserMessage = ctx.sessionManager.getEntries().first { entry in
                if case .message(let msg) = entry, case .user = msg.message { return true }
                return false
            }

            if let firstUserMessage {
                // Navigate to first user message to create a new branch from that point.
                // Label it as "code-review" so it's visible in the tree.
                let result = await ctx.navigateTree(
                    firstUserMessage.id,
                    HookNavigateTreeOptions(summarize: false, label: "code-review")
                )
                if result.cancelled {
                    await store.setOrigin(nil)
                    return false
                }

                // Clear the editor (navigating to user message fills it with the message text)
                await ctx.ui.setEditorText("")
            }

            // Restore origin after navigation events (session_tree can reset it)
            await store.setOrigin(lockedOriginId)

            // Show widget indicating review is active
            await setReviewWidget(ui: ctx.ui, hasUI: ctx.hasUI, active: true)

            // Persist review state so tree navigation can restore/reset it
            pi.appendEntry(REVIEW_STATE_TYPE, ["active": true, "originId": lockedOriginId])
        }

        let prompt = await buildReviewPrompt(pi, target)
        let hint = getUserFacingHint(target)
        let projectGuidelines = loadProjectReviewGuidelines(cwd: ctx.cwd)

        // Combine the review rubric with the specific prompt
        var fullPrompt = "\(REVIEW_RUBRIC)\n\n---\n\nPlease perform a code review with the following focus:\n\n\(prompt)"

        if let customInstructions = await store.reviewCustomInstructions {
            fullPrompt += "\n\nShared custom review instructions (applies to all reviews):\n\n\(customInstructions)"
        }

        if let extra = extraInstruction?.trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty {
            fullPrompt += "\n\nAdditional user-provided review instruction:\n\n\(extra)"
        }

        if let projectGuidelines {
            fullPrompt += "\n\nThis project has additional instructions for code reviews:\n\n\(projectGuidelines)"
        }

        let modeHint = useFreshSession ? " (fresh session)" : ""
        await ctx.ui.notify("Starting review: \(hint)\(modeHint)", .info)

        // Send as a user message that triggers a turn
        pi.sendUserMessage(fullPrompt)
        return true
    }

    // MARK: /review command

    pi.registerCommand("review", description: "Review code changes (PR, uncommitted, branch, commit, or folder)") { args, ctx in
        if !ctx.hasUI {
            await ctx.ui.notify("Review requires interactive mode", .error)
            return
        }

        // Check if we're already in a review
        if await store.reviewOriginId != nil {
            await ctx.ui.notify("Already in a review. Use /end-review to finish first.", .warning)
            return
        }

        // Check if we're in a git repository
        let gitCheck = await run(pi, "git", ["rev-parse", "--git-dir"])
        if gitCheck.code != 0 {
            await ctx.ui.notify("Not a git repository", .error)
            return
        }

        // Try to parse direct arguments
        var target: ReviewTarget?
        var fromSelector = false
        let parsed = parseArgs(args)
        if let error = parsed.error {
            await ctx.ui.notify(error, .error)
            return
        }
        let extraInstruction = parsed.extraInstruction?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch parsed.target {
        case .target(let parsedTarget):
            target = parsedTarget
        case .pr(let ref):
            // Handle PR checkout (async operation)
            target = await resolvePullRequestTarget(ctx, ref)
            if target == nil {
                await ctx.ui.notify("PR review failed. Returning to review menu.", .warning)
            }
        case nil:
            break
        }

        // If no args or invalid args, show selector
        if target == nil {
            fromSelector = true
        }

        while true {
            if target == nil, fromSelector {
                target = await showReviewSelector(ctx)
            }

            guard let resolvedTarget = target else {
                await ctx.ui.notify("Review cancelled", .info)
                return
            }

            // Determine if we should use fresh session mode.
            // In an empty session, default to fresh review mode so /end-review works consistently.
            let messageCount = ctx.sessionManager.getEntries().filter { entry in
                if case .message = entry { return true }
                return false
            }.count

            var useFreshSession = messageCount == 0

            if messageCount > 0 {
                // Existing session - ask user which mode they want
                let choice = await ctx.ui.select("Start review in:", ["Empty branch", "Current session"])

                guard let choice else {
                    if fromSelector {
                        target = nil
                        continue
                    }
                    await ctx.ui.notify("Review cancelled", .info)
                    return
                }

                useFreshSession = choice == "Empty branch"
            }

            _ = await executeReview(ctx, resolvedTarget, useFreshSession: useFreshSession, extraInstruction: extraInstruction)
            return
        }
    }

    // MARK: /end-review command

    @Sendable func getActiveReviewOrigin(_ ctx: HookCommandContext) async -> String? {
        if let originId = await store.reviewOriginId {
            return originId
        }

        let state = getReviewState(ctx.sessionManager)
        if let state, state.active, let originId = state.originId {
            await store.setOrigin(originId)
            return originId
        }

        if let state, state.active {
            await setReviewWidget(ui: ctx.ui, hasUI: ctx.hasUI, active: false)
            pi.appendEntry(REVIEW_STATE_TYPE, ["active": false])
            await ctx.ui.notify("Review state was missing origin info; cleared review status.", .warning)
        }

        return nil
    }

    @Sendable func clearReviewState(_ ctx: HookCommandContext) async {
        await setReviewWidget(ui: ctx.ui, hasUI: ctx.hasUI, active: false)
        await store.setOrigin(nil)
        pi.appendEntry(REVIEW_STATE_TYPE, ["active": false])
    }

    // action ∈ {"returnOnly", "returnAndFix", "returnAndSummarize"}
    @Sendable func executeEndReviewAction(_ ctx: HookCommandContext, _ action: String) async {
        guard let originId = await getActiveReviewOrigin(ctx) else {
            if getReviewState(ctx.sessionManager)?.active != true {
                await ctx.ui.notify("Not in a review branch (use /review first, or review was started in current session mode)", .info)
            }
            return
        }

        if action == "returnOnly" {
            let result = await ctx.navigateTree(originId, HookNavigateTreeOptions(summarize: false))
            if result.cancelled {
                await ctx.ui.notify("Navigation cancelled. Use /end-review to try again.", .info)
                return
            }

            await clearReviewState(ctx)
            await ctx.ui.notify("Review complete! Returned to original position.", .info)
            return
        }

        await ctx.ui.notify("Returning and summarizing review branch...", .info)
        let result = await ctx.navigateTree(
            originId,
            HookNavigateTreeOptions(
                summarize: true,
                customInstructions: REVIEW_SUMMARY_PROMPT,
                replaceInstructions: true
            )
        )

        if result.cancelled {
            await ctx.ui.notify("Navigation cancelled. Use /end-review to try again.", .info)
            return
        }

        await clearReviewState(ctx)

        if action == "returnAndSummarize" {
            if await ctx.ui.getEditorText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await ctx.ui.setEditorText("Act on the review findings")
            }
            await ctx.ui.notify("Review complete! Returned and summarized.", .info)
            return
        }

        pi.sendUserMessage(REVIEW_FIX_FINDINGS_PROMPT, options: HookSendMessageOptions(deliverAs: .followUp))
        await ctx.ui.notify("Review complete! Returned and queued a follow-up to fix findings.", .info)
    }

    pi.registerCommand("end-review", description: "Complete review and return to original position") { _, ctx in
        if !ctx.hasUI {
            await ctx.ui.notify("End-review requires interactive mode", .error)
            return
        }

        guard await store.beginEndReview() else {
            await ctx.ui.notify("/end-review is already running", .info)
            return
        }

        do {
            let choice = await ctx.ui.select("Finish review:", [
                "Return only",
                "Return and fix findings",
                "Return and summarize",
            ])

            guard let choice else {
                await ctx.ui.notify("Cancelled. Use /end-review to try again.", .info)
                await store.finishEndReview()
                return
            }

            let action: String
            switch choice {
            case "Return and fix findings":
                action = "returnAndFix"
            case "Return and summarize":
                action = "returnAndSummarize"
            default:
                action = "returnOnly"
            }

            await executeEndReviewAction(ctx, action)
        }

        await store.finishEndReview()
    }
}

// MARK: - Dylib entry point

/// Standard plugin entry point so this target can also be built as a dynamic
/// library and dropped into `~/.pi/agent/extensions/` for dlopen-based loading.
@_cdecl("piExtensionMain")
public func piExtensionMain(_ raw: UnsafeMutableRawPointer) {
    let api = Unmanaged<HookAPI>.fromOpaque(raw).takeUnretainedValue()
    registerReviewExtension(api)
}

#else

/// The review extension shells out to `git`/`gh`, which is unavailable on
/// UIKit platforms. Registration is a no-op there.
public enum PiReview {
    public static func register(_ pi: ExtensionAPI) {}
}

#endif
