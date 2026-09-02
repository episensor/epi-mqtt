#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

SNAP_COMMON="$TEST_ROOT/common"
SNAP_DATA="$TEST_ROOT/data"
SNAP_NAME=epi-mqtt
SNAPCTL_LOG="$TEST_ROOT/snapctl.log"
SNAPCTL_STATE="$TEST_ROOT/snapctl.state"
FAKE_SNAPCTL="$TEST_ROOT/snapctl"
export SNAP_COMMON SNAP_DATA SNAP_NAME SNAPCTL_LOG SNAPCTL_STATE

mkdir -p "$SNAP_COMMON/config" "$SNAP_COMMON/certs" "$SNAP_DATA/certs"
cat > "$FAKE_SNAPCTL" <<'EOF'
#!/bin/sh
echo "$*" >> "$SNAPCTL_LOG"
case "$1" in
  restart)
    [ "$(cat "$SNAPCTL_STATE" 2>/dev/null || true)" != fail ]
    ;;
  services)
    if [ "$(cat "$SNAPCTL_STATE" 2>/dev/null || true)" = inactive ]; then
      printf 'Service Startup Current Notes\nepi-mqtt.mosquitto enabled inactive -\n'
    else
      printf 'Service Startup Current Notes\nepi-mqtt.mosquitto enabled active -\n'
    fi
    ;;
  *) exit 64 ;;
esac
EOF
chmod +x "$FAKE_SNAPCTL"

printf 'server cert\n' > "$SNAP_COMMON/certs/server-fullchain.pem"
printf 'server key\n' > "$SNAP_COMMON/certs/server-privkey.pem"
printf 'client ca\n' > "$SNAP_DATA/certs/gateway-client-ca.crt"
result=$(EPI_MQTT_SNAPCTL_BIN="$FAKE_SNAPCTL" EPI_MQTT_VERIFY_INTERVAL=0 \
  sh "$ROOT/snap/local/configure-broker.sh" --mode core-mtls --local-port 1883 --gateway-port 8883)
printf '%s\n' "$result" | grep -q '"applied":true'
printf '%s\n' "$result" | grep -q '"verified":true'
grep -q '^per_listener_settings true$' "$SNAP_COMMON/mosquitto.conf"
grep -q '^cafile /var/snap/epi-mqtt/current/certs/gateway-client-ca.crt$' "$SNAP_COMMON/mosquitto.conf"
grep -q '^pattern readwrite %u/#$' "$SNAP_COMMON/config/aclfile"
grep -q '^restart epi-mqtt.mosquitto$' "$SNAPCTL_LOG"

before=$(cksum "$SNAP_COMMON/mosquitto.conf")
printf 'fail\n' > "$SNAPCTL_STATE"
set +e
failure=$(EPI_MQTT_SNAPCTL_BIN="$FAKE_SNAPCTL" EPI_MQTT_VERIFY_INTERVAL=0 \
  sh "$ROOT/snap/local/configure-broker.sh" --mode local --local-port 1884 2>&1)
status=$?
set -e
test "$status" -ne 0
printf '%s\n' "$failure" | grep -q '"code":"service_verification_failed"'
test "$(cksum "$SNAP_COMMON/mosquitto.conf")" = "$before"

printf 'password hash\n' > "$SNAP_COMMON/config/passwordfile"
rm -f "$SNAPCTL_STATE"
password_result=$(EPI_MQTT_SNAPCTL_BIN="$FAKE_SNAPCTL" EPI_MQTT_VERIFY_INTERVAL=0 \
  sh "$ROOT/snap/local/configure-broker.sh" --mode core-password --username core-user)
printf '%s\n' "$password_result" | grep -q '"mode":"core-password"'
grep -q '^user core-user$' "$SNAP_COMMON/config/aclfile"
grep -q '^username=core-user$' "$SNAP_COMMON/broker-config.state"

set +e
invalid=$(EPI_MQTT_SNAPCTL_BIN="$FAKE_SNAPCTL" sh "$ROOT/snap/local/configure-broker.sh" \
  --mode core-password --local-port 8883 --gateway-port 8883 2>&1)
status=$?
set -e
test "$status" -ne 0
printf '%s\n' "$invalid" | grep -q '"code":"duplicate_listener_port"'

# A process killed between acquiring and releasing the lock must not block all
# future broker changes. Only a lock owned by a live PID remains authoritative.
mkdir "$SNAP_COMMON/.configure-broker.lock"
printf '999999\n' > "$SNAP_COMMON/.configure-broker.lock/owner"
recovered=$(EPI_MQTT_SNAPCTL_BIN="$FAKE_SNAPCTL" EPI_MQTT_VERIFY_INTERVAL=0 \
  sh "$ROOT/snap/local/configure-broker.sh" --mode local --local-port 1884)
printf '%s\n' "$recovered" | grep -q '"applied":true'
test ! -e "$SNAP_COMMON/.configure-broker.lock"

echo "broker configuration tests passed"
