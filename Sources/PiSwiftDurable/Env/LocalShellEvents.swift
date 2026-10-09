#if os(macOS)
import Darwin
import Dispatch
import Synchronization

/// One kernel event queue for a command. Only the worker changes pipe and process filters.
internal final class LocalShellEvents: Sendable {
    private let descriptor: Int32
    // A spill writer can trigger an event from another thread. Serialize trigger and close to prevent fd reuse.
    private let openDescriptor: Mutex<Int32?>
    let childExitedBeforeRegistration: Bool
    private static let spillIdentifier: UInt = 1

    init(pid: pid_t, stdout: Int32, stderr: Int32) throws {
        let fd = kqueue()
        guard fd >= 0 else { throw LocalShell.posixError(.unknown) }
        let alreadyExited = try Self.register(fd: fd, pid: pid, stdout: stdout, stderr: stderr)
        descriptor = fd; openDescriptor = Mutex(fd); childExitedBeforeRegistration = alreadyExited
    }

    deinit { close() }

    private static func register(fd: Int32, pid: pid_t, stdout: Int32, stderr: Int32) throws -> Bool {
        var success = false
        defer { if !success { _ = Darwin.close(fd) } }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw LocalShell.posixError(.unknown) }
        var changes = [event(ident: UInt(stdout), filter: EVFILT_READ, flags: EV_ADD | EV_ENABLE),
                       event(ident: UInt(stderr), filter: EVFILT_READ, flags: EV_ADD | EV_ENABLE),
                       event(ident: spillIdentifier, filter: EVFILT_USER, flags: EV_ADD | EV_CLEAR)]
        guard kevent(fd, &changes, Int32(changes.count), nil, 0, nil) == 0 else { throw LocalShell.posixError(.unknown) }
        var child = event(ident: UInt(pid), filter: EVFILT_PROC, flags: EV_ADD | EV_ONESHOT, notes: NOTE_EXIT)
        let registered = kevent(fd, &child, 1, nil, 0, nil)
        let alreadyExited = registered < 0 && errno == ESRCH
        guard registered == 0 || alreadyExited else { throw LocalShell.posixError(.unknown) }
        success = true
        return alreadyExited
    }

    private static func event(ident: UInt, filter: Int32, flags: Int32 = 0, notes: UInt32 = 0) -> kevent {
        kevent(ident: ident, filter: Int16(filter), flags: UInt16(flags), fflags: notes, data: 0, udata: nil)
    }

    func setRead(_ fd: Int32, flags: Int32) throws {
        var change = Self.event(ident: UInt(fd), filter: EVFILT_READ, flags: flags)
        guard kevent(descriptor, &change, 1, nil, 0, nil) == 0 else { throw LocalShell.posixError(.unknown) }
    }

    /// Coalesced user events wake the worker when a paused spill drains or fails.
    func triggerSpill() {
        openDescriptor.withLock { fd in
            guard let fd else { return }
            var change = Self.event(ident: Self.spillIdentifier, filter: EVFILT_USER, notes: UInt32(NOTE_TRIGGER))
            // A trigger has no output event list, so this syscall cannot wait for an event.
            while kevent(fd, &change, 1, nil, 0, nil) < 0 && errno == EINTR {}
        }
    }

    /// Blocks only the command's dispatch worker. No cooperative Swift executor thread waits here.
    func wait(until deadline: UInt64?, onWake: @Sendable () -> Void) throws {
        var events: [kevent] = .init(repeating: Self.event(ident: 0, filter: EVFILT_USER), count: 4)
        let count: Int32
        if let deadline {
            let now = DispatchTime.now().uptimeNanoseconds
            let remaining = deadline > now ? deadline - now : 0
            var timeout = timespec(tv_sec: Int(remaining / 1_000_000_000), tv_nsec: Int(remaining % 1_000_000_000))
            count = kevent(descriptor, nil, 0, &events, Int32(events.count), &timeout)
        } else {
            count = kevent(descriptor, nil, 0, &events, Int32(events.count), nil)
        }
        let number = errno
        onWake()
        if count < 0 {
            if number == EINTR { return }
            throw LocalShell.posixError(.unknown, number: number)
        }
        for event in events.prefix(Int(count)) where event.flags & UInt16(EV_ERROR) != 0 {
            throw LocalShell.posixError(.unknown, number: Int32(event.data))
        }
    }

    func close() {
        openDescriptor.withLock { fd in
            if let value = fd { _ = Darwin.close(value); fd = nil }
        }
    }
}
#endif
