import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Pannello ridotto: pillola sotto la barra, in alto a destra (come la barretta compatta del Mac).
// Clic sul timer o su "Apri" riapre il pannello; ⭐ segna; stop chiede conferma.
// Si mostra con `qs ipc -c recap call mini show` (avvio della call, "Riduci" nel pannello) e
// sparisce da sola a call conclusa, dopo aver offerto le note.
//
// Costruita come l'isola di Latto, che su Hyprland funziona: una finestra per monitor, sempre
// mappata e di misura fissa (larga quanto lo schermo, alta quanto basta), sul livello Overlay;
// la maschera d'input copre solo la pillola, e quando è nascosta i clic passano alla barra e
// alle finestre sotto. Niente finestre che compaiono o cambiano misura.
PanelWindow {
    id: mini
    required property var modelData
    screen: modelData

    // Visibile solo sul monitor che aveva il fuoco quando è stata chiamata.
    readonly property bool shown: MiniState.shown
        && (MiniState.screenName === "" || Quickshell.screens.length === 1 || MiniState.screenName === modelData.name)
    property real t: 0
    Behavior on t { NumberAnimation { duration: mini.shown ? 240 : 150; easing.type: Easing.OutCubic } }
    onShownChanged: {
        t = shown ? 1 : 0
        confirmStop = false
        if (shown) { st = ({ phase: "" }); poll() }  // "Recap…" finché non arriva lo stato
    }
    function hide() { MiniState.shown = false }

    readonly property int barHeight: 36
    color: "transparent"
    anchors { top: true; left: true; right: true }
    implicitHeight: barHeight + 6 + 52 + 12
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "recap-mini"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    mask: Region { item: mini.shown ? pill : null }

    readonly property string bin: Quickshell.env("HOME") + "/.local/bin/recap-lite"
    property var st: ({ phase: "" })
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
    onStChanged: if (shown && (st.phase === "idle" || st.phase === "failed")) hide()

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
    // Bottone tondo; con `label` diventa una pillola con icona e testo.
    component Round: Rectangle {
        id: r
        property string icon: ""
        property string label: ""
        property color tint: "transparent"
        property color ink: Theme.fg
        signal clicked()
        implicitWidth: label ? rrow.implicitWidth + 22 : 32
        implicitHeight: 32; radius: 16
        color: tint.a > 0 ? (rma.containsMouse ? Qt.lighter(tint, 1.1) : tint)
                          : (rma.containsMouse ? Theme.cardHi : "transparent")
        Behavior on implicitWidth { NumberAnimation { duration: 120 } }
        Row {
            id: rrow
            anchors.centerIn: parent
            spacing: 5
            Icon { name: r.icon; size: 18; color: r.ink; filled: r.tint.a > 0; anchors.verticalCenter: parent.verticalCenter }
            Text { visible: r.label !== ""; text: r.label; color: r.ink; font.pixelSize: 13; font.weight: Font.DemiBold
                   anchors.verticalCenter: parent.verticalCenter }
        }
        MouseArea { id: rma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: r.clicked() }
    }

    function expand() { mini.run(["panel", "--show"]); mini.hide() }

    // Il primo clic su stop chiede conferma: un clic sbagliato non chiude la call.
    property bool confirmStop: false
    Timer { id: confirmT; interval: 3000; onTriggered: mini.confirmStop = false }

    Rectangle {
        id: pill
        anchors { right: parent.right; rightMargin: 12 }
        y: mini.barHeight + 6 - (1 - mini.t) * 6
        width: row.implicitWidth + 16
        height: 52
        transformOrigin: Item.TopRight
        radius: 26
        color: Theme.surface
        border.color: Theme.line
        opacity: mini.t
        scale: 0.96 + 0.04 * mini.t

        RowLayout {
            id: row
            anchors { verticalCenter: parent.verticalCenter; left: parent.left; leftMargin: 8 }
            spacing: 4

            // in call: puntino e timer (clic = riapri il pannello), poi le azioni
            Rectangle {
                visible: mini.live
                implicitWidth: timeRow.implicitWidth + 20; implicitHeight: 36; radius: 18
                color: tma.containsMouse ? Theme.cardHi : "transparent"
                Row {
                    id: timeRow
                    anchors.centerIn: parent
                    spacing: 9
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 10; height: 10; radius: 5; color: Theme.red
                        SequentialAnimation on opacity { running: mini.live && mini.shown; loops: Animation.Infinite
                            NumberAnimation { to: 0.35; duration: 800 } NumberAnimation { to: 1; duration: 800 } }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: mini.clock(mini.now - (mini.st.startedAt || mini.now))
                        color: Theme.fg; font.pixelSize: 17; font.weight: Font.DemiBold
                    }
                }
                MouseArea { id: tma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: mini.expand() }
            }
            Round { visible: mini.live; icon: "star"; onClicked: mini.run(["mark"], "select") }
            Round { visible: mini.live; icon: "open_in_full"; label: "Apri"; onClicked: mini.expand() }
            Item { visible: mini.live; implicitWidth: 6 }
            Round {
                visible: mini.live
                icon: "stop"; label: mini.confirmStop ? "Ferma?" : ""
                tint: Theme.red; ink: "white"
                onClicked: {
                    if (!mini.confirmStop) { mini.confirmStop = true; confirmT.restart(); return }
                    mini.confirmStop = false
                    mini.run(["stop-async"], "switch-off")
                }
            }

            // note in preparazione / pronte
            Text {
                visible: !mini.live
                text: mini.st.phase === "finishing" ? (mini.st.phaseMessage || "Scrivo le note…")
                    : mini.st.phase === "done" ? "Note pronte" : "Recap…"
                color: mini.st.phase === "done" ? Theme.green : Theme.fg
                font.pixelSize: 14; font.weight: Font.Medium
                Layout.leftMargin: 10; Layout.rightMargin: 6
            }
            Round { visible: mini.st.phase === "done" && !!mini.st.notesFile; icon: "description"; label: "Apri"
                    onClicked: { Quickshell.execDetached(["xdg-open", mini.st.notesFile]); mini.hide() } }
            Round { visible: !mini.live; icon: "close"; onClicked: mini.hide() }
        }
    }
}
