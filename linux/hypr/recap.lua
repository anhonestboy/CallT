-- Recap Lite: scorciatoie e pannello. Caricato da hyprland.lua con:  pcall(require, "recap")
-- Ogni pezzo è in un pcall: un'opzione non riconosciuta non rompe il resto della config.

local function bind(keys, cmd, desc)
    pcall(hl.bind, keys, hl.dsp.exec_cmd(cmd), { description = desc })
end

bind("SUPER + ALT + C", "recap-lite toggle", "Call: Avvia/ferma Recap (note della call)")
bind("SUPER + ALT + N", "recap-lite panel",  "Call: Mostra/nascondi il pannello di Recap")
bind("SUPER + ALT + B", "recap-lite panel --mini", "Call: Riduci il pannello di Recap a pillola")
bind("SUPER + ALT + M", "recap-lite mark",   "Call: Segna questo momento (⭐)")

-- Menu flottante (Quickshell) precaricato all'avvio: il clic sulla voce in waybar lo apre subito.
pcall(hl.on, "hyprland.start", function() hl.exec_cmd("qs -c recap -d") end)

-- Il pannello (Chromium in modalità app): flottante, su tutti i workspace, vetro, in alto a destra
-- sotto la barra (come il pannello del Mac). Si riconosce dalla classe e non dal titolo: le regole
-- guardano il titolo iniziale, e Chromium apre la finestra prima di aver caricato "Recap Lite".
--   recap-lite               con --class=recap-lite (lo aggiunge recap-lite)
--   chrome-127.0.0.1__-...   classe che Chromium dà da solo alle finestre --app
-- Se la regola non prende, recap-lite sistema comunque la finestra con hyprctl.
local classes = { "^(recap-lite)$", "^(chrome-127\\.0\\.0\\.1__.*)$" }
for i, class in ipairs(classes) do
    local ok = pcall(hl.window_rule, {
        name    = "recap-lite-panel-" .. i,
        match   = { class = class },
        float   = true,
        pin     = true,
        size    = { 480, 760 },
        move    = { "monitor_w-492", "48" },
        opacity = "0.96 0.90",
        no_screen_share = true,  -- in condivisione schermo al suo posto c'è un rettangolo nero
    })
    if not ok then
        pcall(hl.window_rule, {
            name  = "recap-lite-panel-" .. i,
            match = { class = class },
            float = true,
            size  = "480 760",
        })
    end
end

-- Pillola e menu (Quickshell) nascosti a chi guarda lo schermo condiviso, come sul Mac.
for _, ns in ipairs({ "recap-mini", "recap-menu" }) do
    pcall(hl.layer_rule, { name = "recap-noshare-" .. ns, match = { namespace = "^" .. ns .. "$" }, no_screen_share = true })
end
