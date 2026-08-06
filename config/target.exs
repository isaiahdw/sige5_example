import Config

# Use RingLogger as the logger backend and remove :console
config :logger, backends: [RingLogger]

# Use shoehorn to start the main application.
config :shoehorn, init: [:nerves_runtime, :nerves_pack]

# The startup guard is disabled because Sige5Example.FirmwareValidator stands in
# for it, holding out for internet connectivity rather than the guard's "all
# OTP apps started". Running both would be pointless: the stock guard would
# validate on apps-started long before connectivity was ever proven.
#
# The replacement has to do everything the guard does - install the :heart
# callback, acknowledge the initialization handshake, and clear the callback
# only once validation succeeds. Acknowledging the handshake without arming
# the callback disables HEART_INIT_TIMEOUT and leaves nothing to trigger the
# reboot the rollback depends on.
config :nerves_runtime, startup_guard_enabled: false

# Advance the system clock at boot on devices whose RTC isn't set yet.
config :nerves, :erlinit, update_clock: true

# SSH access + firmware updates over SSH
keys =
  System.user_home!()
  |> Path.join(".ssh/id_{rsa,ecdsa,ed25519}.pub")
  |> Path.wildcard()

if keys == [],
  do:
    Mix.raise("""
    No SSH public keys found in ~/.ssh. An ssh authorized key is needed to
    log into the Nerves device and update firmware on it using ssh.
    """)

config :nerves_ssh,
  authorized_keys: Enum.map(keys, &File.read!/1)

# WiFi credentials are read from the environment at build time so they stay
# out of the repository. Export them before `mix firmware`:
#
#     export SIGE5_WIFI_SSID="your-network"
#     export SIGE5_WIFI_PSK="your-password"
#
# Without them the image simply ships no WiFi configuration; wired and the
# usb0 gadget still come up, and a network can be added at runtime with
# VintageNet.configure/2.
#
# That silence is a trap on a board reached over WiFi, so it is announced.
# Building without either variable is legitimate - a wired device needs no
# credentials - but it has to be a choice rather than a forgotten export,
# because the resulting image looks identical and drops the link on flash.
# Setting only one of them is never intentional, and fails the build.
wifi =
  case {System.get_env("SIGE5_WIFI_SSID"), System.get_env("SIGE5_WIFI_PSK")} do
    {ssid, psk} when is_binary(ssid) and is_binary(psk) ->
      [
        {"wlan0",
         %{
           type: VintageNetWiFi,
           vintage_net_wifi: %{
             networks: [%{key_mgmt: :wpa_psk, ssid: ssid, psk: psk}]
           },
           ipv4: %{method: :dhcp}
         }}
      ]

    {nil, nil} ->
      IO.puts(:stderr, """

      ==> no WiFi configuration in this image
          SIGE5_WIFI_SSID and SIGE5_WIFI_PSK are unset. Flashing this to a
          board whose only route is wlan0 will make it unreachable.
      """)

      []

    {ssid, _psk} ->
      missing = if is_binary(ssid), do: "SIGE5_WIFI_PSK", else: "SIGE5_WIFI_SSID"

      raise """
      #{missing} is not set, but the other half of the WiFi credentials is.

      Set both to configure WiFi, or neither to build an image without it.
      """
  end

# Networking: wired first (the RTL8211F PHY path we most want to verify),
# WiFi via the onboard BCM43752, and usb0 gadget networking as a fallback
# console path.
config :vintage_net,
  regulatory_domain: "US",
  config:
    [
      {"usb0", %{type: VintageNetDirect}},
      {"eth0",
       %{
         type: VintageNetEthernet,
         ipv4: %{method: :dhcp}
       }}
    ] ++ wifi

config :mdns_lite,
  hosts: [:hostname, "sige5"],
  ttl: 120,
  services: [
    %{protocol: "ssh", transport: "tcp", port: 22},
    %{protocol: "sftp-ssh", transport: "tcp", port: 22},
    %{protocol: "epmd", transport: "tcp", port: 4369}
  ]

# NervesHub (NervesCloud). The device authenticates with a client certificate
# whose private key is generated inside OP-TEE and never leaves it.
#
# One-time setup on the device:
#
#     iex> Sige5Example.SecureKey.provision()
#     %{serial_number: "...", csr: "-----BEGIN CERTIFICATE REQUEST-----\n..."}
#
# Sign the CSR it returns with a CA (scripts/device-ca.sh), add the device to
# NervesHub under the serial number it prints, upload the certificate there,
# and put the certificate back on the device:
#
#     iex> Sige5Example.SecureKey.store_certificate(pem)
#
# The device identifies itself by serial number, the eMMC's CID here.
#
# Needs a secure-world bootloader; on a board without one the configurator
# logs and leaves the connection unconfigured rather than failing.
config :nerves_hub_link,
  host: "devices.nervescloud.com",
  configurator: Sige5Example.NervesHubOptee,
  connect_wait_for_network: true,
  remote_iex: true
