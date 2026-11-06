import AppKit
import GuestpadCore

@main
struct Check {
    static func main() {
        do {
            try PadLink.check()
            let output = try PadLinkOutput()
            defer { output.close() }
            Thread.sleep(forTimeInterval: 0.5)
            var state = ControllerState()
            state.buttons = 0x1000
            state.leftX = 24576
            try output.submit(state)
            Thread.sleep(forTimeInterval: 0.5)
            try output.submit(ControllerState())
            Thread.sleep(forTimeInterval: 0.5)
            print("PadLink accepted neutral, Cross with stick movement, and release.")
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
