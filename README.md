# LuCI App Dashboard

OpenWrt/LEDE dashboard for network status, traffic, devices, application activity, domain activity, and system information.

## Installation

Recommended online install:

```sh
sh -c "$(wget -O- https://github.com/hxzlplp7/luci-app-dashboard/releases/latest/download/install.sh)"
```

Install a fixed release:

```sh
wget -O /tmp/install-dashboard.sh https://github.com/hxzlplp7/luci-app-dashboard/releases/latest/download/install.sh
VERSION=v0.0.1 sh /tmp/install-dashboard.sh
```

The installer downloads and installs:

- `luci-app-dashboard.ipk`
- `luci-i18n-dashboard-zh-cn.ipk`
- `dashboard-core-ARCH` (built from the `dashboard-core/` stage-one backend during release)

If architecture detection does not match your device, set it explicitly:

```sh
DASHBOARD_CORE_ARCH=aarch64_cortex-a53 sh /tmp/install-dashboard.sh
```

## Backend Contract

`dashboard-core` is the required backend binary. It is installed to `/usr/bin/dashboard-core` and managed by `/etc/init.d/dashboard-core`.

The service listens only on localhost:

```text
127.0.0.1:19090
```

LuCI proxies this backend through the authenticated dashboard API. The browser should call LuCI, not the backend port directly:

```text
/admin/dashboard/api/databus
```

`GET /databus` from `dashboard-core` must return a JSON object containing:

- `status`
- `system_status`
- `network_status`
- `interface_traffic`
- `online_apps`
- `app_recognition`
- `domains`
- `realtime_urls`
- `devices`

`interface_traffic` should include:

```json
{
  "interface": "pppoe-wan",
  "tx_bytes": 123456,
  "rx_bytes": 654321,
  "tx_rate": 1024,
  "rx_rate": 4096,
  "sampled_at": 1713859200,
  "source": "dashboard-core"
}
```

`domains` should include:

```json
{
  "source": "dashboard-core",
  "realtime_source": "dashboard-core",
  "top": [{ "domain": "example.com", "count": 10 }],
  "realtime": [{ "domain": "api.example.com", "count": 1 }]
}
```

## Reverse Proxy

For public reverse proxy deployments, expose only the LuCI dashboard/API path. Do not expose `127.0.0.1:19090`.

Proxy one of these LuCI paths back to the router:

```text
/cgi-bin/luci/admin/dashboard/api/databus
/admin/dashboard/api/databus
```

## Build

Put this repository under the OpenWrt SDK `package` directory:

```sh
git clone https://github.com/hxzlplp7/luci-app-dashboard.git package/luci-app-dashboard
./scripts/feeds update -a
./scripts/feeds install -a
make package/luci-app-dashboard/compile V=s
```

The GitHub release workflow builds the LuCI packages and the stage-one backend, then publishes stable asset names for the installer:

- `install.sh`
- `luci-app-dashboard.ipk`
- `luci-i18n-dashboard-zh-cn.ipk`
- `dashboard-core-ARCH`

## OAF Feature Library

The LuCI package ships a built-in OAF-compatible feature library:

- Default bundle: `feature3.0_cn_20250929-free-compat` (`v25.9.29`)
- Built-in path: `/usr/share/luci-app-dashboard/oaf-default/feature.cfg`
- Icon path: `/www/luci-static/resources/app_icons/`

On first install, the package initializes `/etc/appfilter/feature.cfg` if it does not already exist. Package upgrades do not overwrite an existing user feature library.

## License

Apache License 2.0. See `LICENSE`.
