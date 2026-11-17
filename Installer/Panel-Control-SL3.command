#!/bin/bash
clear
echo "=========================================================="
echo "   PANEL DE CONTROL RANE SL3 — by pepelee (@pepeleedj)    "
echo "   Instagram: https://www.instagram.com/pepeleedj/        "
echo "=========================================================="
echo ""
# La app SL 3 Control Panel si esta instalada; si no, el estado en Terminal.
if [ -d "/Applications/SL 3 Control Panel.app" ]; then
    open "/Applications/SL 3 Control Panel.app"
    exit 0
elif [ -x "/usr/local/bin/sl3panel" ]; then
    /usr/local/bin/sl3panel status
else
    echo "La herramienta sl3panel aun no esta instalada en /usr/local/bin/sl3panel."
    echo "Ejecuta primero Instalar-Rane-SL3.command o RaneSL3-macOS-Universal.pkg"
fi
echo ""
read -p "Pulsa ENTER para cerrar esta ventana..."
