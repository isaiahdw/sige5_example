# sige5_example

Example Nerves firmware for the ArmSoM Sige5 / Banana Pi BPI-M5 Pro (Rockchip
RK3576), built on
[nerves_system_sige5](https://github.com/isaiahdw/nerves_system_sige5).

What it shows:

- Networking — eth0 DHCP, onboard WiFi, usb0 gadget
- SSH with firmware updates, mDNS (`sige5.local`), RingLogger, Toolshed
- A firmware validator that holds out for real connectivity before marking an
  update good, so a bad image reverts on the next boot
- NervesHub over a device key that never leaves the SoC's secure world

## Build and flash

```sh
export MIX_TARGET=sige5
mix deps.get
mix firmware
```

WiFi credentials come from the environment so they stay out of the repository:

```sh
export SIGE5_WIFI_SSID="your-network"
export SIGE5_WIFI_PSK="your-password"
```

Without them the image ships no WiFi configuration; wired and the usb0 gadget
still work, and a network can be added at runtime with `VintageNet.configure/2`.

First flash goes over USB maskrom, which writes the bootloader and filesystems
in one image — see
[docs/flashing.md](https://github.com/isaiahdw/nerves_system_sige5/blob/main/docs/flashing.md).
After that, `mix upload sige5.local` is the normal path.

## On the device

Serial console is UART0 on header pins 8 (TX) / 10 (RX) / 6 (GND), 1500000 8N1.

```elixir
Sige5Example.check()   # a pass/fail line per subsystem
```

## A device key in the secure world

With a secure-world bootloader (`SECURE_WORLD=1 ./scripts/build-uboot.sh` in
the system repo) the device can hold a private key that no software on it can
read. The key is generated inside OP-TEE's PKCS #11 token, marked sensitive and
non-extractable; signing happens in TrustZone and Linux only ever sees
signatures. Taking the eMMC yields ciphertext.

Provisioning takes two machines. The device creates the key and asks for a
certificate; your machine signs it with a CA.

That split is the point of the CA: a device can always make a key and sign for
itself, but only whoever holds the CA key can issue a certificate the fleet
trusts. So the CA key must never be on a device — anything holding it can issue
an identity for any board. In production it belongs in an HSM or on an offline
machine rather than a working directory.

From your machine, in one step:

```sh
mix sige5.provision sige5.local
```

That fetches the request, signs it with the device CA (creating the CA the
first time), installs the certificate, and prints the serial number. Add a
device with that serial number in NervesHub and upload the certificate
against it.

The device half on its own, if you want to move the request by hand:

```elixir
iex> Sige5Example.SecureKey.provision()
%{serial_number: "2a2e1131348a", csr: "-----BEGIN CERTIFICATE REQUEST-----..."}
iex> Sige5Example.SecureKey.store_certificate(pem)
```

What this protects: nobody who takes the board or reads the filesystem can
obtain the private key, because no copy of it exists outside the trusted
application. What it does not: code already running as root can ask the secure
world to sign, the same as any hardware key without a per-use PIN. The token
PIN in the source is not a secret and cannot be one — the device boots
unattended.

### How it fits together

`Sige5Example.SecureKey.Server` keeps `/usr/bin/optee-key` running with one TEE
session open and exchanges a line per request, so many signatures cost one
process. The token PIN reaches it in the environment rather than the arguments,
since that process runs for the life of the node and `/proc/<pid>/cmdline` is
readable by anything on the system. TLS reaches the key through `:ssl`'s
`sign_fun` callback:

```elixir
key: %{algorithm: :ecdsa, sign_fun: &Sige5Example.SecureKey.sign/3}
```
