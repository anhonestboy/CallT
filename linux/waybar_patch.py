#!/usr/bin/env python3
"""Aggiunge la voce di Recap a waybar (config.jsonc + style.css), con backup. Idempotente."""
import re
import shutil
import sys
from pathlib import Path

root = Path(sys.argv[1] if len(sys.argv) > 1 else Path.home() / ".config/waybar").expanduser()
config = next((p for p in (root / "config.jsonc", root / "config") if p.exists()), None)
if config is None:
    print("waybar: config non trovata, salto")
    sys.exit(0)

text = config.read_text()
if '"custom/recap"' not in text:
    shutil.copy(config, config.with_name(config.name + ".bak-recap"))
    # 1) prima voce dei moduli di destra
    text, n = re.subn(r'("modules-right"\s*:\s*\[)', r'\1\n        "custom/recap",', text, count=1)
    if n == 0:
        print("waybar: \"modules-right\" non trovato, aggiungi \"custom/recap\" a mano")
        sys.exit(0)
    # 2) definizione del modulo, subito dopo l'elenco dei moduli di destra
    module = '''
    "custom/recap": {
        "exec": "recap-lite status --waybar",
        "return-type": "json",
        "interval": 1,
        "on-click": "recap-lite menu",
        "on-click-right": "recap-lite show",
        "on-click-middle": "recap-lite panel --mini"
    },'''
    end = re.search(r'"modules-right"\s*:\s*\[[^\]]*\]\s*,', text)
    text = text[:end.end()] + module + text[end.end():]
    config.write_text(text)
    print(f"waybar: voce Recap aggiunta a {config.name} (backup .bak-recap)")
else:
    # Versioni precedenti: il clic destro fermava la call. Ora riapre il pannello (o avvia).
    old = text
    text = text.replace('"on-click-right": "recap-lite toggle"', '"on-click-right": "recap-lite show"')
    text = text.replace('"on-click-middle": "recap-lite panel"', '"on-click-middle": "recap-lite panel --mini"')
    if text != old:
        config.write_text(text)
        print(f"waybar: clic della voce Recap aggiornati in {config.name}")

style = root / "style.css"
if style.exists() and "#custom-recap" not in style.read_text():
    with style.open("a") as f:
        f.write("""
/* Recap: icona sempre visibile, rossa con il timer durante la call */
#custom-recap { padding: 0 8px; font-size: 15px; }
#custom-recap.live { color: #ff5d5d; font-weight: bold; }
#custom-recap.finishing { color: @accent; }
#custom-recap.failed { color: @warn; }
""")
    print("waybar: stile della voce Recap aggiunto a style.css")
