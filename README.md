Eclipse Mosquitto
=================

## EpiSensor Snap Diagnostics

The `epi-mqtt` snap exposes Mosquitto client tools as snap apps. Use these
instead of running binaries directly from `/snap/epi-mqtt/current`, because
`snap run` sets the library paths and confinement environment correctly.

Subscribe to a local topic:

    snap run epi-mqtt.mosquitto-sub -h localhost -p 1883 -t '#' -v

Publish a local test message:

    snap run epi-mqtt.mosquitto-pub -h localhost -p 1883 -t test/topic -m hello

Short aliases are also available:

    snap run epi-mqtt.sub -h localhost -p 1883 -t '#' -v
    snap run epi-mqtt.pub -h localhost -p 1883 -t test/topic -m hello

### Configuration authority

The broker has one durable configuration authority:
`/var/snap/epi-mqtt/common/mosquitto.conf`. On first launch, an older
content-interface config is imported once when no common config exists;
afterward, changes to the old path are ignored. The migration source is
recorded in `/var/snap/epi-mqtt/common/.config-authority-v1`.

Do not write the live file directly. The companion generates the supported
local, Core mTLS, and Core password configurations, publishes them atomically,
restarts its own service, requires three consecutive active-service checks,
and rolls back on failure:

    sudo snap run epi-mqtt.configure --mode local --local-port 1883
    sudo snap run epi-mqtt.configure --mode core-mtls --local-port 1883 --gateway-port 8883
    sudo snap run epi-mqtt.configure --mode core-password --username core-user --local-port 1883 --gateway-port 8883

Certificate, CA, ACL, and password files stay in the snap-owned `common` and
shared `current/certs` paths. Password values are never passed through snap
configuration or written to snapd history.

Mosquitto is an open source implementation of a server for version 5.0, 3.1.1,
and 3.1 of the MQTT protocol. It also includes a C and C++ client library, and
the `mosquitto_pub` and `mosquitto_sub` utilities for publishing and
subscribing.

## Links

See the following links for more information on MQTT:

- Community page: <http://mqtt.org/>
- MQTT v3.1.1 standard: <https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/mqtt-v3.1.1.html>
- MQTT v5.0 standard: <https://docs.oasis-open.org/mqtt/mqtt/v5.0/mqtt-v5.0.html>

Mosquitto project information is available at the following locations:

- Main homepage: <https://mosquitto.org/>
- Find existing bugs or submit a new bug: <https://github.com/eclipse/mosquitto/issues>
- Source code repository: <https://github.com/eclipse/mosquitto>

There is also a public test server available at <https://test.mosquitto.org/>

## Installing

See <https://mosquitto.org/download/> for details on installing binaries for
various platforms.

## Quick start

If you have installed a binary package the broker should have been started
automatically. If not, it can be started with a basic configuration:

    mosquitto

Then use `mosquitto_sub` to subscribe to a topic:

    mosquitto_sub -t 'test/topic' -v

And to publish a message:

    mosquitto_pub -t 'test/topic' -m 'hello world'

## Documentation

Documentation for the broker, clients and client library API can be found in
the man pages, which are available online at <https://mosquitto.org/man/>. There
are also pages with an introduction to the features of MQTT, the
`mosquitto_passwd` utility for dealing with username/passwords, and a
description of the configuration file options available for the broker.

Detailed client library API documentation can be found at <https://mosquitto.org/api/>

## Building from source

To build from source the recommended route for end users is to download the
archive from <https://mosquitto.org/download/>.

On Windows and Mac, use `cmake` to build. On other platforms, just run `make`
to build. For Windows, see also `README-windows.md`.

If you are building from the git repository then the documentation will not
already be built. Use `make binary` to skip building the man pages, or install
`docbook-xsl` on Debian/Ubuntu systems.

### Build Dependencies

* c-ares (libc-ares-dev on Debian based systems) - only when compiled with `make WITH_SRV=yes`
* cJSON - for client JSON output support. Disable with `make WITH_CJSON=no` Auto detected with CMake.
* libwebsockets (libwebsockets-dev) - enable with `make WITH_WEBSOCKETS=yes`
* openssl (libssl-dev on Debian based systems) - disable with `make WITH_TLS=no`
* pthreads - for client library thread support. This is required to support the
  `mosquitto_loop_start()` and `mosquitto_loop_stop()` functions. If compiled
  without pthread support, the library isn't guaranteed to be thread safe.
* uthash / utlist - bundled versions of these headers are provided, disable their use with `make WITH_BUNDLED_DEPS=no`
* xsltproc (xsltproc and docbook-xsl on Debian based systems) - only needed when building from git sources - disable with `make WITH_DOCS=no`

Equivalent options for enabling/disabling features are available when using the CMake build.


## Credits

Mosquitto was written by Roger Light <roger@atchoo.org>
