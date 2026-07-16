#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

SNAP="$TMPDIR/snap"
SNAP_COMMON="$TMPDIR/common"
SNAP_USER_COMMON="/root/snap/epi-mqtt/common"
SNAP_DATA="$TMPDIR/data"
export SNAP SNAP_COMMON SNAP_USER_COMMON SNAP_DATA

mkdir -p "$SNAP/usr/sbin" "$SNAP_COMMON" "$SNAP_DATA"
cp "$ROOT/snap/local/default_config.conf" "$SNAP/default_config.conf"
cp "$ROOT/mosquitto.conf" "$SNAP/mosquitto.conf"
cat > "$SNAP/usr/sbin/mosquitto" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$SNAP_COMMON/mosquitto.args"
EOF
chmod +x "$SNAP/usr/sbin/mosquitto"

run_launcher() {
    rm -f "$SNAP_COMMON/mosquitto.args"
    sh "$ROOT/snap/local/launcher.sh" >/dev/null
    cat "$SNAP_COMMON/mosquitto.args"
}

default_args=$(run_launcher)
test "$default_args" = "-c $SNAP/default_config.conf"

mkdir -p "$SNAP_DATA/config"
printf '%s\n' 'listener 1884 127.0.0.1' > "$SNAP_DATA/config/mosquitto.conf"
content_args=$(run_launcher)
test "$content_args" = "-c $SNAP_DATA/config/mosquitto.conf"

printf '%s\n' 'listener 1885 127.0.0.1' > "$SNAP_COMMON/mosquitto.conf"
legacy_args=$(run_launcher)
test "$legacy_args" = "-c $SNAP_COMMON/mosquitto.conf"

test -f "$SNAP_COMMON/mosquitto_example.conf"
echo "snap launcher tests passed"
