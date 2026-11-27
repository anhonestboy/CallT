#!/usr/bin/env bash
# Installa Recap Lite per l'utente corrente (nessun sudo).
#   ./install.sh          comando recap-lite + voce nel launcher
#   ./install.sh --hypr   anche scorciatoie e regola del pannello per Hyprland
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

mkdir -p ~/.local/bin ~/.local/share/applications
ln -sf "$here/recap-lite" ~/.local/bin/recap-lite
chmod +x "$here/recap-lite"

cat > ~/.local/share/applications/recap-lite.desktop <<DESKTOP
[Desktop Entry]
Type=Application
Name=Recap Lite
Comment=Note in tempo reale delle call
Exec=$HOME/.local/bin/recap-lite toggle
Icon=audio-input-microphone
Terminal=false
Categories=Office;AudioVideo;
DESKTOP
command -v update-desktop-database >/dev/null && update-desktop-database ~/.local/share/applications || true

if [ "${1:-}" = "--hypr" ]; then
    conf=~/.config/hypr
    cp "$here/hypr/recap.lua" "$conf/recap.lua"
    if ! grep -q 'require, "recap"' "$conf/hyprland.lua"; then
        cp "$conf/hyprland.lua" "$conf/hyprland.lua.bak-recap"
        printf '\n-- Recap Lite (note delle call): scorciatoie Super+Alt+C/N/M e pannello\npcall(require, "recap")\n' >> "$conf/hyprland.lua"
    fi
    # Menu flottante (Quickshell) e voce nella barra (waybar)
    mkdir -p ~/.config/quickshell
    rm -rf ~/.config/quickshell/recap
    cp -R "$here/quickshell/recap" ~/.config/quickshell/recap
    python3 "$here/waybar_patch.py" ~/.config/waybar || true
    command -v hyprctl >/dev/null && hyprctl reload >/dev/null 2>&1 || true
    pkill -f 'qs -c recap' 2>/dev/null || true
    setsid qs -c recap -d >/dev/null 2>&1 < /dev/null &
    pkill -SIGUSR2 waybar 2>/dev/null || true   # ricarica la barra
    echo "Hyprland: Super+Alt+C avvia/ferma · Super+Alt+N pannello · Super+Alt+M segna il momento"
    echo "Barra: clic sull'icona dell'onda per il menu di Recap"
fi

echo
"$HOME/.local/bin/recap-lite" check || true
