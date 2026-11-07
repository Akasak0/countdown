import AppKit

let application = NSApplication.shared
let delegate = AppController()
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
