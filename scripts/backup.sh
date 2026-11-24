#!/usr/bin/env bash
# Respaldo del repo + logs en un .tgz (sin state.env, .secrets.env ni node_modules) para descargar desde CloudShell
source "$(dirname "$0")/lib.sh"
touch "$ROOT_DIR/.gitignore"; grep -qx 'node_modules/' "$ROOT_DIR/.gitignore" || echo 'node_modules/' >> "$ROOT_DIR/.gitignore"
OUT="$HOME/freshbox-respaldo-$(date +%Y%m%d-%H%M).tgz"
tar czf "$OUT" -C "$(dirname "$ROOT_DIR")" --exclude='state.env' --exclude='.secrets.env' --exclude='node_modules' "$(basename "$ROOT_DIR")"
ok "$OUT ($(du -h "$OUT" | cut -f1))"
log "Descargalo: CloudShell > Actions > Download file > $OUT"
