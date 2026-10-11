import Foundation
import TunnelsCore

// Live harness for the core, no UI:
//   tunnelsctl <host-alias> <localPort> [remotePort] [seconds]
// Opens the forward through a real ssh master, holds it for `seconds`
// (default 20) so you can curl through it, then closes everything.

let args = CommandLine.arguments.dropFirst()
guard args.count >= 2, let localPort = Int(args[args.startIndex + 1]) else {
    FileHandle.standardError.write(Data("usage: tunnelsctl <host-alias> <localPort> [remotePort] [seconds]\n".utf8))
    exit(2)
}
let alias = args[args.startIndex]
let remotePort = args.count >= 3 ? Int(args[args.startIndex + 2]) : nil
let seconds = args.count >= 4 ? Int(args[args.startIndex + 3]) ?? 20 : 20

let socketDir = FileManager.default.temporaryDirectory.appendingPathComponent("tunnelsctl-sockets")
let spec = ForwardSpec(machine: alias, localPort: localPort, remotePort: remotePort)

@MainActor
func main() async {
    var options = SSHOptions(socketDirectory: socketDir)
    options.configPath = ProcessInfo.processInfo.environment["TUNNELS_SSH_CONFIG"].flatMap { $0.isEmpty ? nil : $0 }
    let controller = ForwardController(runner: SystemProcessRunner(), options: options)
    controller.onMasterDropped = { alias, output in
        print("master for \(alias) dropped: \(output)")
    }

    print("opening \(spec.sshArgument) via \(alias) …")
    let id = await controller.addAdHoc(spec)
    print("machine: \(controller.machineState(alias))")
    print("forward: \(controller.forwards.first { $0.id == id }?.state ?? .off)")

    if controller.forwards.first(where: { $0.id == id })?.state == .active {
        print("holding for \(seconds)s. Try: curl -s http://127.0.0.1:\(localPort)/ or nc -z 127.0.0.1 \(localPort)")
        for _ in 0..<seconds {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if controller.forwards.first(where: { $0.id == id })?.state != .active {
                print("forward state changed: \(controller.forwards.first { $0.id == id }?.state ?? .off)")
                break
            }
        }
    }

    print("closing …")
    await controller.shutdown()
    print("done. machine: \(controller.machineState(alias))")
}

// Keep the main queue alive for the main actor; the task exits the process.
Task { @MainActor in
    await main()
    exit(0)
}
dispatchMain()
