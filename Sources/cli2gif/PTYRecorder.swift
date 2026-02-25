import Darwin
import Foundation

struct PTYRecorder: Sendable {
    let command: String
    let cols: Int
    let rows: Int
    let timeout: Int

    func run(state: TerminalState, onComplete: @escaping @Sendable () -> Void) {
        var masterFD: Int32 = 0
        var winSize = winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        let pid = forkpty(&masterFD, nil, nil, &winSize)

        if pid == 0 {
            // Child process
            setenv("TERM", "xterm-256color", 1)
            setenv("COLUMNS", "\(cols)", 1)
            setenv("LINES", "\(rows)", 1)
            let args = ["sh", "-c", command]
            let cArgs = args.map { strdup($0) } + [nil]
            execv("/bin/sh", cArgs)
            _exit(127)
        }

        guard pid > 0 else {
            onComplete()
            return
        }

        // Capture fd as a let so the closure captures an immutable value
        let master = masterFD

        // Set master fd to non-blocking
        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        let readQueue = DispatchQueue(label: "cli2gif.pty.read")
        let timeoutDeadline = DispatchTime.now() + .seconds(timeout)

        readQueue.async {
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }

            var childDone = false

            while !childDone {
                if DispatchTime.now() > timeoutDeadline {
                    kill(pid, SIGKILL)
                    break
                }

                let bytesRead = read(master, buffer, bufferSize)
                if bytesRead > 0 {
                    let data = Data(bytes: buffer, count: bytesRead)
                    state.write(data)
                } else if bytesRead == 0 {
                    childDone = true
                } else {
                    let err = errno
                    if err == EAGAIN || err == EWOULDBLOCK {
                        usleep(5000)
                    } else {
                        childDone = true
                    }
                }

                var status: Int32 = 0
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid {
                    while true {
                        let n = read(master, buffer, bufferSize)
                        if n > 0 {
                            state.write(Data(bytes: buffer, count: n))
                        } else {
                            break
                        }
                    }
                    childDone = true
                }
            }

            close(master)
            onComplete()
        }
    }
}
