#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
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
printf '%s\n' "$result" | grep -Eq '"revision":"[0-9a-f]{64}"'
grep -q '^per_listener_settings true$' "$SNAP_COMMON/mosquitto.conf"
grep -q '^cafile /var/snap/epi-mqtt/current/certs/gateway-client-ca.crt$' "$SNAP_COMMON/mosquitto.conf"
grep -q '^pattern readwrite %u/#$' "$SNAP_COMMON/config/aclfile"
grep -q '^restart epi-mqtt.mosquitto$' "$SNAPCTL_LOG"

configure() {
  EPI_MQTT_SNAPCTL_BIN="$FAKE_SNAPCTL" EPI_MQTT_VERIFY_INTERVAL=0 \
    sh "$ROOT/snap/local/configure-broker.sh" "$@"
}

# Reapply a pre-policy mTLS installation. Old hook invocations retain its ACL.
sed '/^# Gateway topic policy: /d' "$SNAP_COMMON/mosquitto.conf" > "$TEST_ROOT/old-config"
mv "$TEST_ROOT/old-config" "$SNAP_COMMON/mosquitto.conf"
sed '/^gateway_topic_policy=/d' "$SNAP_COMMON/broker-config.state" > "$TEST_ROOT/old-state"
mv "$TEST_ROOT/old-state" "$SNAP_COMMON/broker-config.state"
legacy=$(configure --mode core-mtls)
grep -Fxq 'pattern readwrite %u/#' "$SNAP_COMMON/config/aclfile"
directional=$(configure --mode core-mtls --gateway-topic-policy directional)
printf '%s\n' "$directional" | grep -Fq '"gateway_topic_policy":"directional"'
test "$legacy" != "$directional"
legacy_revision=$(sed -n 's/.*"revision":"\([0-9a-f]*\)".*/\1/p' <<EOF
$legacy
EOF
)
grep -Eq '^revision=[0-9a-f]{64}$' "$SNAP_COMMON/broker-config.state"
test -n "$legacy_revision"
if grep -Fxq "revision=$legacy_revision" "$SNAP_COMMON/broker-config.state"; then exit 1; fi
acl="$SNAP_COMMON/config/aclfile"
grep -Fxq 'pattern read %u/#' "$acl"
grep -Fxq 'pattern read server/broadcast' "$acl"
# Assert the whole externally writable set. This also catches an added wildcard
# or readwrite grant anywhere in the generated ACL.
actual_writes=$(awk '$1 != "pattern" || $2 != "read" {print}' "$acl" | sort)
expected_writes=$(for suffix in ping data events alerts rpc/out commands/out \
    sync/gateway/complete sync/gateway/complete/gzip sync/gateway/delta sync/gateway/delta/gzip \
    sync/nodes/+/complete sync/nodes/+/complete/gzip sync/nodes/+/delta sync/nodes/+/delta/gzip; do
  printf 'pattern write %%u/%s\n' "$suffix"
done | sort)
test "$actual_writes" = "$expected_writes"
grep -Fxq 'gateway_topic_policy=directional' "$SNAP_COMMON/broker-config.state"
saved_acl=$(cksum "$acl")
saved_state=$(cksum "$SNAP_COMMON/broker-config.state")
for mode in local core-password; do
  if configure --mode "$mode" --gateway-topic-policy directional; then exit 1; fi
done
for policy in invalid ''; do
  if configure --mode core-mtls --gateway-topic-policy="$policy"; then exit 1; fi
done
test "$(cksum "$SNAP_COMMON/broker-config.state")" = "$saved_state"

before=$(cksum "$SNAP_COMMON/mosquitto.conf")
cert_before=$(cksum "$SNAP_COMMON/certs/server-fullchain.pem")
key_before=$(cksum "$SNAP_COMMON/certs/server-privkey.pem")
printf 'unusable renewed cert\n' > "$SNAP_DATA/certs/server-fullchain.pem.pending"
printf 'unusable renewed key\n' > "$SNAP_DATA/certs/server-privkey.pem.pending"
printf 'fail\n' > "$SNAPCTL_STATE"
set +e
failure=$(EPI_MQTT_SNAPCTL_BIN="$FAKE_SNAPCTL" EPI_MQTT_VERIFY_INTERVAL=0 \
  sh "$ROOT/snap/local/configure-broker.sh" --mode core-mtls --local-port 1884 --gateway-port 8883 --gateway-topic-policy namespace 2>&1)
status=$?
set -e
test "$status" -ne 0
printf '%s\n' "$failure" | grep -q '"code":"service_verification_failed"'
test "$(cksum "$SNAP_COMMON/mosquitto.conf")" = "$before"
test "$(cksum "$acl")" = "$saved_acl"
test "$(cksum "$SNAP_COMMON/broker-config.state")" = "$saved_state"
test "$(cksum "$SNAP_COMMON/certs/server-fullchain.pem")" = "$cert_before"
test "$(cksum "$SNAP_COMMON/certs/server-privkey.pem")" = "$key_before"
test -f "$SNAP_DATA/certs/server-fullchain.pem.pending"
test -f "$SNAP_DATA/certs/server-privkey.pem.pending"

printf 'password hash\n' > "$SNAP_COMMON/config/passwordfile"
rm -f "$SNAPCTL_STATE"
# A successful retry promotes both staged files and clears the handoff area.
retry_result=$(EPI_MQTT_SNAPCTL_BIN="$FAKE_SNAPCTL" EPI_MQTT_VERIFY_INTERVAL=0 \
  sh "$ROOT/snap/local/configure-broker.sh" --mode core-mtls --local-port 1883 --gateway-port 8883)
printf '%s\n' "$retry_result" | grep -q '"verified":true'
grep -q '^unusable renewed cert$' "$SNAP_COMMON/certs/server-fullchain.pem"
grep -q '^unusable renewed key$' "$SNAP_COMMON/certs/server-privkey.pem"
test ! -e "$SNAP_DATA/certs/server-fullchain.pem.pending"
test ! -e "$SNAP_DATA/certs/server-privkey.pem.pending"
test "$retry_result" = "$directional"
test "$(cksum "$acl")" = "$saved_acl"
test "$(cksum "$SNAP_COMMON/mosquitto.conf")" = "$before"

# A damaged or partially restored selection must not change the broker on renewal.
cp "$SNAP_COMMON/mosquitto.conf" "$TEST_ROOT/untouched-config"
sed 's/^# Gateway topic policy: directional$/# Gateway topic policy: broken/' \
  "$TEST_ROOT/untouched-config" > "$SNAP_COMMON/mosquitto.conf"
if configure --mode core-mtls; then exit 1; fi
test "$(cksum "$SNAP_COMMON/broker-config.state")" = "$saved_state"
test "$(cksum "$acl")" = "$saved_acl"
mv "$TEST_ROOT/untouched-config" "$SNAP_COMMON/mosquitto.conf"
restored=$(configure --mode core-mtls --gateway-topic-policy=namespace)
test "$restored" = "$legacy"
grep -Fxq 'pattern readwrite %u/#' "$acl"

password_result=$(EPI_MQTT_SNAPCTL_BIN="$FAKE_SNAPCTL" EPI_MQTT_VERIFY_INTERVAL=0 \
  sh "$ROOT/snap/local/configure-broker.sh" --mode core-password --username core-user)
printf '%s\n' "$password_result" | grep -q '"mode":"core-password"'
grep -q '^user core-user$' "$SNAP_COMMON/config/aclfile"
grep -q '^username=core-user$' "$SNAP_COMMON/broker-config.state"
grep -Eq '^revision=[0-9a-f]{64}$' "$SNAP_COMMON/broker-config.state"

set +e
invalid=$(EPI_MQTT_SNAPCTL_BIN="$FAKE_SNAPCTL" sh "$ROOT/snap/local/configure-broker.sh" \
  --mode core-password --local-port 8883 --gateway-port 8883 2>&1)
status=$?
set -e
test "$status" -ne 0
printf '%s\n' "$invalid" | grep -q '"code":"duplicate_listener_port"'

printf 'partial renewal\n' > "$SNAP_DATA/certs/server-fullchain.pem.pending"
set +e
incomplete=$(EPI_MQTT_SNAPCTL_BIN="$FAKE_SNAPCTL" sh "$ROOT/snap/local/configure-broker.sh" \
  --mode core-mtls 2>&1)
status=$?
set -e
test "$status" -ne 0
printf '%s\n' "$incomplete" | grep -q '"code":"incomplete_certificate_stage"'
rm -f "$SNAP_DATA/certs/server-fullchain.pem.pending"

# A process killed between acquiring and releasing the lock must not block all
# future broker changes. Only a lock owned by a live PID remains authoritative.
mkdir "$SNAP_COMMON/.configure-broker.lock"
printf '999999\n' > "$SNAP_COMMON/.configure-broker.lock/owner"
recovered=$(EPI_MQTT_SNAPCTL_BIN="$FAKE_SNAPCTL" EPI_MQTT_VERIFY_INTERVAL=0 \
  sh "$ROOT/snap/local/configure-broker.sh" --mode local --local-port 1884)
printf '%s\n' "$recovered" | grep -q '"applied":true'
test ! -e "$SNAP_COMMON/.configure-broker.lock"

echo "broker configuration tests passed"
