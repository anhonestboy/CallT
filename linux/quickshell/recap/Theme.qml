pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Colori dallo sfondo (matugen, come gli extras): ~/.config/matugen/out/desk.json, ricaricati al volo.
Singleton {
    FileView {
        path: Quickshell.env("HOME") + "/.config/matugen/out/desk.json"
        watchChanges: true
        onFileChanged: reload()
        JsonAdapter {
            id: m
            property string primary: "#c1c1ff"
            property string fg: "#e4e1e9"
            property string fgDim: "#c7c5d0"
            property string surface: "#131318"
        }
    }
    readonly property color primary: m.primary
    readonly property color fg: m.fg
    readonly property color dim: m.fgDim
    readonly property color surface: Qt.rgba(Qt.color(m.surface).r, Qt.color(m.surface).g, Qt.color(m.surface).b, 0.93)
    readonly property color card: Qt.tint(m.surface, Qt.rgba(1, 1, 1, 0.07))
    readonly property color cardHi: Qt.tint(m.surface, Qt.rgba(1, 1, 1, 0.14))
    readonly property color line: Qt.rgba(1, 1, 1, 0.08)
    readonly property color ink: m.surface
    readonly property color red: "#ff5d5d"
    readonly property color green: "#5ed39b"
    readonly property string icons: "Material Symbols Rounded"
}
