import AppKit

let application = NSApplication.shared
// A separate data directory lets preview builds be tested without touching real timers.
let arguments = CommandLine.arguments
let argumentDirectory = arguments.firstIndex(of: "--data-directory").flatMap { index in
    index + 1 < arguments.count ? URL(fileURLWithPath: arguments[index + 1], isDirectory: true) : nil
}
let bundledDirectory = (Bundle.main.object(forInfoDictionaryKey: "CountdownDataDirectory") as? String)
    .map { URL(fileURLWithPath: $0, isDirectory: true) }
let dataDirectory = argumentDirectory ?? bundledDirectory
let delegate = AppController(dataDirectory: dataDirectory)
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
