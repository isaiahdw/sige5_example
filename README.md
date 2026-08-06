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

Provision a device in one step, from your machine:

```sh
./scripts/provision-device.sh sige5.local
```

That asks the device for a certificate request, signs it with the device CA
(creating the CA the first time), installs the certificate, and prints the
serial number to register in NervesHub. Add a device with that serial number
and upload the certificate against it.

The CA's private key stays on your machine and never goes to a device —
anything holding it can issue an identity for any board. That is the one part
the device cannot do for itself; everything else the script handles.

The individual steps, if you want them:

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
process. TLS reaches the key through `:ssl`'s `sign_fun` callback:

```elixir
key: %{algorithm: :ecdsa, sign_fun: &Sige5Example.SecureKey.sign/3}
```
