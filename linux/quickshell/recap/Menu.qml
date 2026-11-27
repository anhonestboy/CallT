import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Il menu: scheda flottante sotto la barra, all'altezza dell'icona. Clic fuori o Esc chiude.
// Dati da `recap-lite status --json` (ogni secondo mentre è aperto) e `recap-lite recent --json`.
PanelWindow {
    id: win
    property bool open: false
    property real t: 0
    Behavior on t { NumberAnimation { duration: win.open ? 220 : 140; easing.type: Easing.OutCubic } }
    onOpenChanged: {
        t = open ? 1 : 0
        if (open) { poll(); recentProc.running = true; focusT.restart() }
    }
    visible: open || t > 0.01
    color: "transparent"
    anchors { top: true; left: true; right: true; bottom: true }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "recap-menu"
    WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    readonly property string bin: Quickshell.env("HOME") + "/.local/bin/recap-lite"
    readonly property int barHeight: 36
    property real anchorX: -1

    function toggleAt(x, y) {
        if (open) { open = false; return }
        anchorX = -1
        if (x >= 0) {
            for (let i = 0; i < Quickshell.screens.length; i++) {
                const s = Quickshell.screens[i]
                if (x >= s.x && x < s.x + s.width) { win.screen = s; anchorX = x - s.x; break }
            }
        }
        open = true
    }

    // ---------- dati ----------
    property var st: ({ phase: "idle" })
    property var recents: []
    property real now: Date.now() / 1000
    readonly property bool live: st.phase === "live" || st.phase === "starting"
    readonly property bool finishing: st.phase === "finishing"
    readonly property bool done: st.phase === "done"

    Process {
        id: statusProc
        command: [win.bin, "status", "--json"]
        stdout: StdioCollector { onStreamFinished: { try { win.st = JSON.parse(text) } catch (e) { } } }
    }
    Process {
        id: recentProc
        command: [win.bin, "recent", "--json"]
        stdout: StdioCollector { onStreamFinished: { try { win.recents = JSON.parse(text) } catch (e) { } } }
    }
    function poll() { if (!statusProc.running) statusProc.running = true }
    Timer { interval: 1000; running: win.open; repeat: true; onTriggered: { win.now = Date.now() / 1000; win.poll() } }
    Timer { id: focusT; interval: 60; onTriggered: keys.forceActiveFocus() }

    function run(args, sound) {
        Quickshell.execDetached([win.bin].concat(args))
        if (sound) Quickshell.execDetached(["qs", "ipc", "-c", "extras", "call", "sfx", "play", sound])
        later.restart()
    }
    function openPath(path) { if (path) Quickshell.execDetached(["xdg-open", path]); win.open = false }
    Timer { id: later; interval: 700; onTriggered: { win.poll(); recentProc.running = true } }

    function clock(seconds) {
        const s = Math.max(0, Math.floor(seconds)), h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), x = s % 60
        return (h ? h + ":" + String(m).padStart(2, "0") : String(m).padStart(2, "0")) + ":" + String(x).padStart(2, "0")
    }
    function ago(epoch) {
        const d = new Date(epoch * 1000), today = new Date()
        const hm = String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0")
        if (d.toDateString() === today.toDateString()) return "oggi, " + hm
        const y = new Date(today); y.setDate(today.getDate() - 1)
        if (d.toDateString() === y.toDateString()) return "ieri, " + hm
        return d.toLocaleDateString(Qt.locale("it_IT"), "d MMM") + ", " + hm
    }

    // ---------- clic fuori / Esc ----------
    MouseArea { anchors.fill: parent; onClicked: win.open = false }
    Item { id: keys; focus: true; Keys.onEscapePressed: win.open = false }

    // ---------- componenti ----------
    component Icon: Text {
        property string name: ""
        property int size: 18
        property bool filled: false
        text: name
        color: Theme.fg
        font.family: Theme.icons
        font.pixelSize: size
        font.variableAxes: ({ "FILL": filled ? 1 : 0, "wght": 500 })
        renderType: Text.NativeRendering
    }
    component Btn: Rectangle {
        id: b
        property string label: ""
        property string icon: ""
        property bool prominent: false
        property color tint: Theme.primary
        signal clicked()
        Layout.fillWidth: true
        implicitHeight: 38
        radius: 12
        color: prominent ? (ma.containsMouse ? Qt.lighter(tint, 1.08) : tint) : (ma.containsMouse ? Theme.cardHi : Theme.card)
        Behavior on color { ColorAnimation { duration: 100 } }
        RowLayout {
            anchors.centerIn: parent
            spacing: 7
            Icon { name: b.icon; visible: b.icon !== ""; filled: b.prominent; color: b.prominent ? Theme.ink : Theme.fg }
            Text { text: b.label; color: b.prominent ? Theme.ink : Theme.fg; font.pixelSize: 14
                   font.weight: b.prominent ? Font.DemiBold : Font.Normal }
        }
        MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: b.clicked() }
    }
    component IconBtn: Rectangle {
        id: ib
        property string icon: ""
        property string tip: ""
        signal clicked()
        implicitWidth: 34; implicitHeight: 34; radius: 9
        color: ima.containsMouse ? Theme.cardHi : "transparent"
        Icon { anchors.centerIn: parent; name: ib.icon; size: 19; color: Theme.dim }
        MouseArea { id: ima; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: ib.clicked() }
    }

    // ---------- la scheda ----------
    Rectangle {
        id: card
        width: 340
        height: body.implicitHeight + 32
        x: win.anchorX < 0 ? win.width - width - 10
                           : Math.max(8, Math.min(win.width - width - 8, win.anchorX - width / 2))
        y: win.barHeight + 6 - (1 - win.t) * 8
        opacity: win.t
        scale: 0.97 + 0.03 * win.t
        transformOrigin: Item.Top
        radius: 18
        color: Theme.surface
        border.color: Theme.line
        border.width: 1
        MouseArea { anchors.fill: parent }  // i clic dentro la scheda non la chiudono

        ColumnLayout {
            id: body
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 16 }
            spacing: 14

            // intestazione
            RowLayout {
                spacing: 10
                Icon { name: "graphic_eq"; size: 22; color: Theme.primary }
                Text { text: "Recap"; color: Theme.fg; font.pixelSize: 17; font.weight: Font.DemiBold; Layout.fillWidth: true }
                Text {
                    text: win.live ? "In call" : win.finishing ? "Note…" : win.done ? "Pronte" : ""
                    visible: text !== ""
                    color: win.live ? Theme.red : Theme.dim
                    font.pixelSize: 12; font.weight: Font.Medium
                }
            }

            // inattivo: avvia
            ColumnLayout {
                visible: !win.live && !win.finishing
                Layout.fillWidth: true
                spacing: 8
                Btn { label: "Avvia sessione"; icon: "radio_button_checked"; prominent: true; implicitHeight: 44
                      onClicked: { win.run(["start"], "switch-on"); win.open = false } }
                Text {
                    Layout.fillWidth: true
                    text: "Trascrive mentre parlate e scrive le note con l'AI. Super+Alt+C per avviare e fermare."
                    color: Theme.dim; font.pixelSize: 12; wrapMode: Text.WordWrap
                }
            }

            // in call
            Rectangle {
                visible: win.live
                Layout.fillWidth: true
                implicitHeight: liveCol.implicitHeight + 24
                radius: 14
                color: Qt.rgba(1, 0.36, 0.36, 0.09)
                ColumnLayout {
                    id: liveCol
                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
                    spacing: 10
                    RowLayout {
                        spacing: 10
                        Rectangle { implicitWidth: 10; implicitHeight: 10; radius: 5; color: Theme.red
                            SequentialAnimation on opacity { running: win.live && win.open; loops: Animation.Infinite
                                NumberAnimation { to: 0.35; duration: 800 } NumberAnimation { to: 1; duration: 800 } } }
                        Text { text: win.clock(win.now - (win.st.startedAt || win.now)); color: Theme.fg
                               font.pixelSize: 24; font.weight: Font.DemiBold }
                        Item { Layout.fillWidth: true }
                    }
                    Text {
                        Layout.fillWidth: true
                        text: (win.st.error ? "⚠ " + win.st.error
                               : (win.st.notesBusy ? "Aggiorno le note… · " : "")
                                 + (win.st.lineCount || 0) + " frasi · " + (win.st.engine || ""))
                        color: win.st.error ? "#ffb35c" : Theme.dim; font.pixelSize: 12; elide: Text.ElideRight
                    }
                    RowLayout {
                        spacing: 8
                        Btn { label: "Pannello"; icon: "dock_to_left"; onClicked: { win.run(["panel", "--show"]); win.open = false } }
                        Btn { label: "Pillola"; icon: "picture_in_picture_alt"; onClicked: { win.run(["panel", "--mini"]); win.open = false } }
                        Btn { label: "Segna"; icon: "star"; onClicked: win.run(["mark"], "select") }
                    }
                    Btn { label: "Ferma e scrivi le note"; icon: "stop_circle"; prominent: true; tint: Theme.red
                          onClicked: win.run(["stop-async"], "switch-off") }
                }
            }

            // note in preparazione
            RowLayout {
                visible: win.finishing
                spacing: 10
                Icon { name: "progress_activity"; color: Theme.primary
                       RotationAnimation on rotation { running: win.finishing && win.open; from: 0; to: 360; duration: 1000; loops: Animation.Infinite } }
                Text { text: win.st.phaseMessage || "Scrivo le note…"; color: Theme.fg; font.pixelSize: 14 }
            }

            // pronte
            RowLayout {
                visible: win.done && !!win.st.notesFile
                spacing: 8
                Btn { label: "Apri note"; icon: "description"; prominent: true; onClicked: win.openPath(win.st.notesFile) }
                Btn { label: "Cartella"; icon: "folder_open"; onClicked: win.openPath(win.st.folder) }
            }

            // recenti
            ColumnLayout {
                visible: win.recents.length > 0
                Layout.fillWidth: true
                spacing: 4
                Text { text: "Recenti"; color: Theme.dim; font.pixelSize: 12; font.weight: Font.DemiBold; Layout.bottomMargin: 2 }
                Repeater {
                    model: win.recents
                    delegate: Rectangle {
                        required property var modelData
                        Layout.fillWidth: true
                        implicitHeight: 46
                        radius: 10
                        color: rma.containsMouse ? Theme.cardHi : Theme.card
                        MouseArea { id: rma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: win.openPath(modelData.notes || modelData.folder) }
                        RowLayout {
                            anchors { fill: parent; leftMargin: 12; rightMargin: 4 }
                            spacing: 6
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0
                                Text { text: modelData.name; color: Theme.fg; font.pixelSize: 13; elide: Text.ElideMiddle; Layout.fillWidth: true }
                                Text { text: win.ago(modelData.mtime); color: Theme.dim; font.pixelSize: 11 }
                            }
                            IconBtn { icon: "folder_open"; onClicked: win.openPath(modelData.folder) }
                        }
                    }
                }
            }

            // piè di pagina
            Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.line }
            RowLayout {
                spacing: 2
                IconBtn { icon: "folder"; onClicked: win.openPath(win.st.outputDir || "") }
                IconBtn { icon: "tune"; onClicked: win.openPath(win.st.configFile || "") }
                Item { Layout.fillWidth: true }
                Text { text: "whisper " + (win.st.model || "") ; color: Theme.dim; font.pixelSize: 11; visible: !!win.st.model }
            }
        }
    }
}
