#!/bin/sh
# Instalador en el aparato: deja el shim del Type 111 (cuadro CarPlay en el VC)
# o lo quita. Corre como root en el propio dongle.
#
#   sh device-install.sh install    instala y parchea /etc/init.d/S11carplay_init
#   sh device-install.sh remove     vuelve al firmware de serie
#
# Lo normal es que lo llame el instalador del PC a traves del CGI de root del
# dongle. El resultado queda en /etc/shttpd/install.txt, que se puede leer por
# HTTP:  http://<ip-del-dongle>/install.txt
#
# Ficheros que espera en /etc/shttpd (los sube el instalador del PC):
#   hk_native111.so             la libreria del shim
#   hk_native_start.sh          el envoltorio de arranque (gestiona los logs)
#   hk_S11carplay_init.stock    el arranque de serie de este firmware, tal cual
DEST=/etc/hook
STAGE=/etc/shttpd
INIT=/etc/init.d/S11carplay_init
OUT=$STAGE/install.txt
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

MD5_SD=2609f4cac9c754f396b1f25c354a0b26
MD5_AP=e126b6067ae670b6f256b537501093cd
MD5_CU=4b1c2fde23909094cbff9feb533cf5c3

exec >"$OUT.tmp" 2>&1
echo "== shim Type 111: $(date) modo=${1:-install}"

fail() {
    echo "FALLO: $*"
    mv -f "$OUT.tmp" "$OUT" 2>/dev/null
    exit 1
}

# El shim depende de tres librerias de este firmware concreto: si no son estas,
# no se toca nada y el dongle arranca como siempre.
check_firmware() {
    for pair in "/usr/lib/libSdCarplay.so $MD5_SD" \
                "/usr/lib/libAirPlay.so $MD5_AP" \
                "/usr/lib/libCoreUtils.so $MD5_CU"; do
        f=${pair% *}
        want=${pair#* }
        got=$(md5sum "$f" 2>/dev/null | sed 's/ .*//')
        [ "$got" = "$want" ] || fail "firmware distinto: $f es '$got', esperaba '$want'"
        echo "ok $f"
    done
}

# El parche se aplica SIEMPRE sobre el arranque de serie que trae el paquete, no
# sobre el que haya puesto: asi reinstalar no acumula parches y quitar siempre
# puede volver al original.
patch_init() {
    src=$STAGE/hk_S11carplay_init.stock
    if grep -q "$DEST/native_start.sh" "$INIT" 2>/dev/null; then
        echo "init ya parcheado ($DEST/native_start.sh)"
        [ -f "$DEST/S11carplay_init.stock" ] || cp "$src" "$DEST/S11carplay_init.stock" 2>/dev/null
        return 0
    fi
    if [ ! -f "$src" ]; then
        echo "AVISO: no vino el arranque de serie ($src); parcheo el que hay"
        src=$INIT
    fi
    [ -f "$DEST/S11carplay_init.stock" ] || cp "$src" "$DEST/S11carplay_init.stock" \
        || fail "no pude guardar $DEST/S11carplay_init.stock"
    [ -f "$DEST/S11carplay_init.orig" ] || cp "$INIT" "$DEST/S11carplay_init.orig" 2>/dev/null
    sed -e "s|^\([[:space:]]*\)sdDongle&|\1$DEST/native_start.sh\&|" \
        -e "s|^\([[:space:]]*\)sdDongle |\1$DEST/native_start.sh |" \
        "$src" >"$INIT.tmp" || fail "sed fallo"
    n=$(grep -c "native_start.sh" "$INIT.tmp")
    if [ "$n" != "2" ]; then
        rm -f "$INIT.tmp"
        fail "no reconozco el arranque de sdDongle ($n lineas); no toco nada"
    fi
    cp "$INIT.tmp" "$INIT" && rm -f "$INIT.tmp" || fail "no pude escribir $INIT"
    # El bit de ejecucion se pierde al reescribirlo (y el arranque lo llama como
    # programa): sin el, el servicio no arranca y no hay CarPlay.
    chmod 755 "$INIT"
    echo "init parcheado ($n lineas -> $DEST/native_start.sh)"
}

case "${1:-install}" in
install)
    check_firmware
    mkdir -p "$DEST" || fail "no pude crear $DEST"
    cp "$STAGE/hk_native111.so" "$DEST/native111.so" || fail "falta $STAGE/hk_native111.so"
    cp "$STAGE/hk_native_start.sh" "$DEST/native_start.sh" || fail "falta $STAGE/hk_native_start.sh"
    chmod 755 "$DEST/native111.so" "$DEST/native_start.sh"
    [ "$(md5sum "$STAGE/hk_native111.so" | sed 's/ .*//')" = \
      "$(md5sum "$DEST/native111.so" | sed 's/ .*//')" ] || fail "copia del .so distinta"
    echo "ficheros en $DEST: $(md5sum "$DEST/native111.so" "$DEST/native_start.sh" 2>/dev/null | tr '\n' ' ')"
    patch_init
    # Logs: el propio envoltorio se encarga (tope de 2 MB con poda). Con
    # nosave=1 stock deja de crear un log por arranque y de leer /proc/kmsg.
    setprop persist.console.log.nosave 1
    echo "persist.console.log.nosave=$(getprop persist.console.log.nosave)"
    # Arranque: se deja como lo trae el firmware. Versiones anteriores de este
    # paquete ponian 30 s aqui; si es lo que hay, se devuelve a su valor de
    # fabrica para no arrastrarlo. (Shim y envoltorio no leen esta propiedad.)
    d=$(getprop persist.sys.boot.delay)
    if [ "$d" = "30" ]; then
        setprop persist.sys.boot.delay 0
        d=0
    fi
    echo "persist.sys.boot.delay=$d (sin tocar)"
    # Ningun reinicio automatico: matar sdDongle deja CarPlay muerto hasta el
    # reenchufe, asi que la marca es un DIRECTORIO y nadie puede escribirla.
    rm -f "$DEST/selfheal.flag" 2>/dev/null
    [ -d "$DEST/selfheal.flag" ] || mkdir "$DEST/selfheal.flag"
    echo "OK: instalado. Reinicia el dongle (desenchufar y enchufar)."
    ;;
remove)
    restored=0
    for src in "$DEST/S11carplay_init.stock" "$DEST/S11carplay_init.orig"; do
        [ -f "$src" ] || continue
        if cp "$src" "$INIT"; then
            chmod 755 "$INIT"
            echo "init restaurado desde $src"
            restored=1
            break
        fi
    done
    if [ "$restored" = "1" ]; then
        rm -f "$DEST/native_start.sh"
    else
        # Sin copia del init de serie no se toca el arranque: se deja el
        # envoltorio, que sin .so arranca sdDongle de fabrica.
        echo "AVISO: no hay copia del init de serie; dejo el envoltorio (arranca stock)"
    fi
    setprop persist.console.log.nosave 2
    setprop persist.sys.boot.delay 0
    rm -f "$DEST/native111.so" "$DEST/logs_cleaned"
    rmdir "$DEST/selfheal.flag" 2>/dev/null
    echo "OK: shim quitado. Reinicia el dongle."
    ;;
*)
    fail "uso: $0 {install|remove}"
    ;;
esac

mv -f "$OUT.tmp" "$OUT" 2>/dev/null
exit 0
