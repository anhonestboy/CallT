// Recap Lite — voce nel menu in alto (waybar) con menu flottante, come la barra dei menu del Mac.
// Avvio: `qs -c recap -d` (lo fa da solo `recap-lite menu` se non è attivo).
// IPC: qs ipc -c recap call menu toggleAt <x> <y>   (x,y = puntatore, da `hyprctl cursorpos`)
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

ShellRoot {
    Menu { id: menu }
    // Pillola: una finestra per monitor (come l'isola di Latto), visibile su quello col fuoco.
    Variants {
        model: Quickshell.screens
        delegate: Mini {}
    }

    IpcHandler {
        target: "menu"
        function toggle(): void { menu.toggleAt(-1, -1) }
        function toggleAt(x: string, y: string): void { menu.toggleAt(parseInt(x), parseInt(y)) }
        function close(): void { menu.open = false }
    }

    // Pannello ridotto (pillola sotto la barra)
    IpcHandler {
        target: "mini"
        function show(): void {
            MiniState.screenName = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
            MiniState.shown = true
        }
        function hide(): void { MiniState.shown = false }
        function toggle(): void { if (MiniState.shown) hide(); else show() }
    }
}
