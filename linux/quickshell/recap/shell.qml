// Recap Lite — voce nel menu in alto (waybar) con menu flottante, come la barra dei menu del Mac.
// Avvio: `qs -c recap -d` (lo fa da solo `recap-lite menu` se non è attivo).
// IPC: qs ipc -c recap call menu toggleAt <x> <y>   (x,y = puntatore, da `hyprctl cursorpos`)
import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
    Menu { id: menu }

    IpcHandler {
        target: "menu"
        function toggle(): void { menu.toggleAt(-1, -1) }
        function toggleAt(x: string, y: string): void { menu.toggleAt(parseInt(x), parseInt(y)) }
        function close(): void { menu.open = false }
    }
}
