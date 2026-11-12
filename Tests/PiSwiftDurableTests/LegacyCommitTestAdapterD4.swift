import PiSwiftChord
@testable import PiSwiftDurable

// v1.5.2 D4: session/session.ts:1766–1818,1843–1850. Existing storage and
// adoption tests use a callback and cancel token. Keep that test syntax inside
// this test target while exercising the public observeCommits implementation.
extension Session {
    func subscribeCommits(_ listener: @escaping @Sendable (CommitPublication, ChordContext) -> Void) throws -> SessionSubscription {
        let observation = try observeCommits(.init(
            advance: { publication, context in listener(publication, context) },
            end: { _ in }))
        return SessionSubscription { observation.detach() }
    }
}

extension Harness {
    func subscribeCommits(_ listener: @escaping @Sendable (CommitPublication, ChordContext) -> Void) throws -> SessionSubscription {
        let observation = try observeCommits(.init(
            advance: { publication, context in listener(publication, context) },
            end: { _ in }))
        return SessionSubscription { observation.detach() }
    }
}
