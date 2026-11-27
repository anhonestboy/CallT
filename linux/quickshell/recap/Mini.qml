import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Pannello ridotto: pillola sotto la barra, in alto a destra (come la barretta compatta del Mac).
// Timer, segna, riapri il pannello, ferma. Si mostra con "Riduci" nel pannello o
// `qs ipc -c recap call mini show`; sparisce da sola a call conclusa, dopo aver offerto le note.
PanelWindow {
    id: mini
    property bool shown: false
    property real t: 0
    Behavior on t { NumberAnimation { duration: mini.shown ? 240 : 150; easing.type: Easing.OutCubic } }
    onShownChanged: { t = shown ? 1 : 0; if (shown) poll() }
    visible: shown || t > 0.01

    color: "transparent"
    anchors { top: true; right: true }
    margins { top: 42; right: 12 }
    implicitWidth: pill.implicitWidth
    implicitHeight: pill.implicitHeight
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "recap-mini"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    readonly property string bin: Quickshell.env("HOME") + "/.local/bin/recap-lite"
    property var st: ({ phase: "idle" })
    property real now: Date.now() / 1000
    readonly property bool live: st.phase === "live" || st.phase === "starting"

    Process {
        id: statusProc
        command: [mini.bin, "status", "--json"]
        stdout: StdioCollector { onStreamFinished: { try { mini.st = JSON.parse(text) } catch (e) { } } }
    }
    function poll() { if (!statusProc.running) statusProc.running = true }
    Timer { interval: 1000; running: mini.shown; repeat: true; onTriggered: { mini.now = Date.now() / 1000; mini.poll() } }
    // Nessuna sessione: la pillola non serve.
    onStChanged: if (shown && (st.phase === "idle" || st.phase === "failed")) shown = false

    function run(args, sound) {
        Quickshell.execDetached([mini.bin].concat(args))
        if (sound) Quickshell.execDetached(["qs", "ipc", "-c", "extras", "call", "sfx", "play", sound])
    }
    function clock(seconds) {
        const s = Math.max(0, Math.floor(seconds)), h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), x = s % 60
        return (h ? h + ":" + String(m).padStart(2, "0") : String(m).padStart(2, "0")) + ":" + String(x).padStart(2, "0")
    }

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
    component Round: Rectangle {
        id: r
        property string icon: ""
        property color tint: "transparent"
        property color ink: Theme.fg
        signal clicked()
        implicitWidth: 32; implicitHeight: 32; radius: 16
        color: tint.a > 0 ? (rma.containsMouse ? Qt.lighter(tint, 1.1) : tint)
                          : (rma.containsMouse ? Theme.cardHi : "transparent")
        Icon { anchors.centerIn: parent; name: r.icon; size: 18; color: r.ink; filled: r.tint.a > 0 }
        MouseArea { id: rma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: r.clicked() }
    }

    Rectangle {
        id: pill
        implicitWidth: row.implicitWidth + 24
        implicitHeight: 52
        radius: 26
        color: Theme.surface
        border.color: Theme.line
        opacity: mini.t
        scale: 0.96 + 0.04 * mini.t

        RowLayout {
            id: row
            anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 16 }
            spacing: 6

            // in call: puntino, timer, azioni
            Rectangle {
                visible: mini.live
                implicitWidth: 10; implicitHeight: 10; radius: 5; color: Theme.red
                SequentialAnimation on opacity { running: mini.live && mini.shown; loops: Animation.Infinite
                    NumberAnimation { to: 0.35; duration: 800 } NumberAnimation { to: 1; duration: 800 } }
            }
            Text {
                visible: mini.live
                text: mini.clock(mini.now - (mini.st.startedAt || mini.now))
                color: Theme.fg; font.pixelSize: 17; font.weight: Font.DemiBold
                Layout.leftMargin: 4; Layout.rightMargin: 8
            }
            Round { visible: mini.live; icon: "star"; onClicked: mini.run(["mark"], "select") }
            Round { visible: mini.live; icon: "open_in_full"; onClicked: { mini.run(["panel", "--show"]); mini.shown = false } }
            Round { visible: mini.live; icon: "stop"; tint: Theme.red; ink: "white"; onClicked: mini.run(["stop-async"], "switch-off") }

            // note in preparazione / pronte
            Text {
                visible: !mini.live
                text: mini.st.phase === "finishing" ? (mini.st.phaseMessage || "Scrivo le note…") : "Note pronte"
                color: mini.st.phase === "done" ? Theme.green : Theme.fg
                font.pixelSize: 13.5; font.weight: Font.Medium
                Layout.rightMargin: 6
            }
            Round { visible: mini.st.phase === "done" && !!mini.st.notesFile; icon: "description"
                    onClicked: { Quickshell.execDetached(["xdg-open", mini.st.notesFile]); mini.shown = false } }
            Round { visible: !mini.live; icon: "close"; onClicked: mini.shown = false }
        }
    }
}
