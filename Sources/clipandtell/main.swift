import AppKit

// clipandtell is a hybrid app: a menu-bar snapshot tool AND a windowed markup
// editor. Unlike clipandcue (an .accessory menu-bar-only utility), it runs as a
// .regular app so editor windows get a Dock icon and standard window behaviour.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
