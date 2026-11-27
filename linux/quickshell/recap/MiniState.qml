pragma Singleton
import Quickshell
import Quickshell.Io

// Stato della pillola, condiviso dalle finestre dei vari monitor, e la sua posizione
// (distanza dal bordo destro e dall'alto), salvata in ~/.config/recap-lite/pill.json.
Singleton {
    property bool shown: false
    property string screenName: ""  // monitor con il fuoco quando è stata chiamata

    readonly property real defaultRight: 12
    readonly property real defaultTop: 42  // sotto waybar (36)
    readonly property real right: place.right
    readonly property real top: place.top

    function moveTo(right, top) { place.right = Math.round(right); place.top = Math.round(top) }
    function reset() { moveTo(defaultRight, defaultTop) }

    FileView {
        path: Quickshell.env("HOME") + "/.config/recap-lite/pill.json"
        onAdapterUpdated: writeAdapter()
        JsonAdapter {
            id: place
            property real right: 12
            property real top: 42
        }
    }
}
