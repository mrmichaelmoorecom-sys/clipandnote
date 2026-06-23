// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "clipandnote",
    platforms: [
        // Ventura. Lowered from .v14 to match clipandcue: the only difference
        // between the two binaries was the deployment target (both build with
        // the same SDK), and AppKit gates NSPopover's macOS-14 light-by-default
        // appearance on the linked deployment target — so a .v14 build rendered
        // the menu-bar dropdown light while clipandcue (.v13) rendered it dark.
        // clipandnote uses only Vision APIs available since macOS 10.13–10.15
        // (image request handler, OCR, classification); no macOS-14-only API,
        // so .v13 widens reach AND makes the dropdown match clipandcue with no
        // appearance override.
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "clipandnote",
            path: "Sources/clipandnote"
        )
    ]
)
