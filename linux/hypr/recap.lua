-- Recap Lite: scorciatoie e pannello. Caricato da hyprland.lua con:  pcall(require, "recap")
-- Ogni pezzo è in un pcall: un'opzione non riconosciuta non rompe il resto della config.

local function bind(keys, cmd, desc)
    pcall(hl.bind, keys, hl.dsp.exec_cmd(cmd), { description = desc })
end

bind("SUPER + ALT + C", "recap-lite toggle", "Call: Avvia/ferma Recap (note della call)")
bind("SUPER + ALT + N", "recap-lite panel",  "Call: Mostra/nascondi il pannello di Recap")
bind("SUPER + ALT + M", "recap-lite mark",   "Call: Segna questo momento (⭐)")

-- Menu flottante (Quickshell) precaricato all'avvio: il clic sulla voce in waybar lo apre subito.
pcall(hl.on, "hyprland.start", function() hl.exec_cmd("qs -c recap -d") end)

-- Il pannello (finestra "Recap Lite" di Chromium): flottante, su tutti i workspace, vetro.
local ok = pcall(hl.window_rule, {
    name    = "recap-lite-panel",
    match   = { title = "^(Recap Lite)$" },
    float   = true,
    pin     = true,
    size    = "480 760",
    opacity = "0.96 0.90",
})
if not ok then
    -- Versione di Hyprland senza "pin" nelle regole: almeno flottante e della misura giusta.
    pcall(hl.window_rule, {
        name  = "recap-lite-panel",
        match = { title = "^(Recap Lite)$" },
        float = true,
        size  = "480 760",
    })
end
