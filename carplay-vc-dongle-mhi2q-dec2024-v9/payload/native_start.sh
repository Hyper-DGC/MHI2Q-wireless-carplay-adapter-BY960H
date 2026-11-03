#!/bin/sh
# Arranque de sdDongle con el shim del Type 111 (cuadro en el VC) y con los
# logs acotados. /etc/init.d/S11carplay_init llama a este script en lugar de
# sdDongle (una linea parcheada; ver dongle/dist/).
#
# Lo que hace:
#   - arranca sdDongle con LD_PRELOAD=native111.so (el shim),
#   - manda su salida a $LOGDIR/sdDongle_live.log, con tope y poda propia,
#   - lo mismo con el log del kernel en $LOGDIR/kernel_live.log,
#   - si el shim pide reinicio (self-heal), relanza sdDongle (maximo 3 veces),
#   - si el firmware no es el esperado, arranca sdDongle de fabrica.
#
# Interruptores, en el mismo directorio que este script:
#   native111.off    -> arranca sdDongle de fabrica (sin shim)
#   selfheal.flag    -> si es DIRECTORIO, ningun reinicio automatico
#
# Entorno (solo para pruebas): HOOK_LOGDIR, HOOK_LOG_MAX_KB, HOOK_LOG_KEEP_B,
# HOOK_KLOG_MAX_KB, HOOK_KLOG_KEEP_B
DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -n "$DIR" ] || DIR=/mnt/UDISK/hook
SO=$DIR/native111.so
FLAG=$DIR/selfheal.flag
BIN=/usr/bin/sdDongle
export CLUSTER_DUAL=1
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
# Este firmware es musl sin ABI time64: el shim enlaza los nombres viejos a mano.
unset LD_PRELOAD LD_LIBRARY_PATH

LOGDIR=${HOOK_LOGDIR:-/mnt/UDISK/log}
[ -d "$LOGDIR" ] || LOGDIR=/tmp
# El shim escribe su propio log en /mnt/UDISK/hook/native111.log (ruta compilada
# en la libreria), asi que ese directorio tiene que existir aunque el shim viva
# en otra ruta.
[ -d /mnt/UDISK/hook ] || mkdir -p /mnt/UDISK/hook 2>/dev/null
LOG=$LOGDIR/sdDongle_live.log
KLOG=$LOGDIR/kernel_live.log
LOG_MAX_KB=${HOOK_LOG_MAX_KB:-2048}      # tope del log de la app: 2 MB
LOG_KEEP_B=${HOOK_LOG_KEEP_B:-131072}    # cola que se conserva al podar
KLOG_MAX_KB=${HOOK_KLOG_MAX_KB:-512}     # tope del log del kernel: 512 KB
KLOG_KEEP_B=${HOOK_KLOG_KEEP_B:-65536}

# Este busybox no trae awk, cut ni stat: la talla es el 5o campo de ls -l.
fsize() {
    set -- $(ls -l "$1" 2>/dev/null)
    case "${5:-}" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$5" ;;
    esac
}

# trim <vivo> <cola> <tope_en_KB> <bytes_que_se_guardan>
# El fichero vivo se abre en modo append (mas abajo), asi que vaciarlo no deja
# hueco: la siguiente escritura empieza en 0. La cola va a un fichero aparte,
# que nadie escribe, para poder mirar las ultimas lineas de antes de la poda.
trim() {
    _sz=$(fsize "$1")
    [ "$_sz" -gt $(($3 * 1024)) ] || return 0
    if [ "$4" -gt 0 ]; then tail -c "$4" "$1" >"$2" 2>/dev/null; fi
    : >"$1"
}

trim_all() {
    trim "$LOG" "$LOG.last" "$LOG_MAX_KB" "$LOG_KEEP_B"
    trim "$KLOG" "$KLOG.last" "$KLOG_MAX_KB" "$KLOG_KEEP_B"
}

# Prueba de la poda sin arrancar nada:  sh native_start.sh --trim-once
if [ "${1:-}" = "--trim-once" ]; then
    trim_all
    exit 0
fi

[ -x "$BIN" ] || exit 1

# Una sola vez por aparato: los logs de stock (uno por arranque) ya no se
# generan con persist.console.log.nosave=1, pero los viejos se quedan.
if [ ! -f "$DIR/logs_cleaned" ]; then
    rm -f "$LOGDIR"/sdDongle_[0-9]*.log "$LOGDIR"/kernel_[0-9]*.log \
          "$LOGDIR"/sdsdk_[0-9]*.log "$LOGDIR"/log_index_* 2>/dev/null
    touch "$DIR/logs_cleaned" 2>/dev/null
fi

exec >>"$LOG" 2>&1
echo "== native_start $(date) pid=$$ up=$(cat /proc/uptime 2>/dev/null)"

# /proc/kmsg solo admite un lector. Se arranca una vez por encendido y en modo
# append (para que la poda no deje hueco). Si otro ya lo lee, cat sale solo.
if [ ! -f /tmp/hook_kmsg_started ] && [ -r /proc/kmsg ]; then
    cat /proc/kmsg >>"$KLOG" 2>/dev/null &
    touch /tmp/hook_kmsg_started 2>/dev/null
fi

if [ -f "$DIR/native111.off" ] || [ ! -f "$SO" ]; then
    echo 'native111: sin shim (native111.off o falta native111.so), stock'
    exec "$BIN" "$@"
fi
sd=$(md5sum /usr/lib/libSdCarplay.so)
ap=$(md5sum /usr/lib/libAirPlay.so)
cu=$(md5sum /usr/lib/libCoreUtils.so)
case "$sd:$ap:$cu" in
  2609f4cac9c754f396b1f25c354a0b26*:*e126b6067ae670b6f256b537501093cd*:*4b1c2fde23909094cbff9feb533cf5c3*) ;;
  *) echo 'native111: unsupported firmware, starting stock'; exec "$BIN" "$@" ;;
esac
if ! LD_PRELOAD="$SO" /bin/sh -c : ; then
    echo 'native111: loader rejected library, starting stock'
    exec "$BIN" "$@"
fi

# Poda cada minuto, mientras viva este script.
( while kill -0 $$ 2>/dev/null; do sleep 60; trim_all; done ) &

attempt=0
while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    rm -f "$FLAG" 2>/dev/null
    LD_PRELOAD="$SO" "$BIN" "$@" &
    child=$!
    (
        while kill -0 "$child" 2>/dev/null; do
            if [ -f "$FLAG" ]; then
                echo 'native_start: self-heal requested, restarting sdDongle'
                kill "$child" 2>/dev/null
                break
            fi
            sleep 2
        done
    ) &
    echo "native111: running pid=$child (attempt $attempt)"
    wait "$child"
    code=$?
    if [ -f "$FLAG" ]; then
        echo "native111: restarting after self-heal (attempt $attempt/3)"
        # Stock bifurca un worker que sobrevive al padre (medido: seguia vivo y
        # con los sockets del HMI), asi que se barre por nombre antes de relanzar.
        for d in /proc/[0-9]*; do
            [ "$(cat "$d/comm" 2>/dev/null)" = "sdDongle" ] || continue
            kill -9 "${d#/proc/}" 2>/dev/null
        done
        sleep 2
        continue
    fi
    # init para el servicio con killall sdDongle: no es un fallo. Sin esto el
    # envoltorio relanzaba stock y quedaban dos instancias peleando.
    case "$code" in
        143|130|131) echo "native111: stopped by init (rc=$code)"; exit 0 ;;
    esac
    if [ "$attempt" -eq 1 ] && [ "$code" -ne 0 ]; then
        echo "native111: child failed rc=$code, starting stock"
        exec "$BIN" "$@"
    fi
    echo "native111: sdDongle exited rc=$code, not restarting"
    break
done
