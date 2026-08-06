#!/bin/sh
#
# Give a device an identity backed by its secure world, in one step.
#
#   ./scripts/provision-device.sh <ip-or-hostname>
#
# Asks the device for a certificate request, signs it with the device CA
# (creating the CA the first time), and installs the certificate. Prints the
# serial number to register in NervesHub.
#
# The CA's private key stays here and never goes to a device: anything holding
# it can issue an identity for any board, which is the one secret this scheme
# has. That is why signing is a step on this machine rather than something
# provision/1 does on the device.

set -e

HOST="$1"
[ -n "$HOST" ] || { echo "usage: $0 <ip-or-hostname>" >&2; exit 2; }

CA_DIR="${CA_DIR:-./ca}"
HERE=$(dirname "$0")
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

on_device() {
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$HOST" "$1" 2>/dev/null
}

echo "asking $HOST for a certificate request"
serial=$(on_device 'IO.puts(Sige5Example.SecureKey.serial_number())' | tr -d '\r' | head -1)
[ -n "$serial" ] || { echo "no answer from $HOST" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The console echoes the expression's return value onto the same line as the
# first line of output, so trim anything before the PEM header.
on_device 'IO.puts(Sige5Example.SecureKey.provision().csr)' \
    | tr -d '\r' \
    | sed -n '/-----BEGIN CERTIFICATE REQUEST-----/,/-----END CERTIFICATE REQUEST-----/p' \
    | sed '1s/^.*-----BEGIN/-----BEGIN/' > "$work/device.csr"

[ -s "$work/device.csr" ] || { echo "the device returned no request" >&2; exit 1; }
echo "  serial number: $serial"

if [ ! -f "$CA_DIR/rootCA.key" ]; then
    echo "creating a device CA in $CA_DIR"
    CA_DIR="$CA_DIR" "$HERE/device-ca.sh" create >/dev/null
fi

echo "signing"
cert=$(CA_DIR="$CA_DIR" "$HERE/device-ca.sh" sign "$work/device.csr" "$serial")

echo "installing the certificate on $HOST"
# Send it as one line and let the device put the newlines back, so no quoting
# survives a round trip through the shell and IEx.
flat=$(tr '\n' '~' < "$cert")
on_device "Sige5Example.SecureKey.store_certificate(String.replace(\"$flat\", \"~\", \"\n\"))" >/dev/null

installed=$(on_device 'IO.puts(Sige5Example.SecureKey.status().certificate)' | tr -d '\r' | head -1)
[ "$installed" = "true" ] || { echo "the certificate did not install" >&2; exit 1; }

cat <<EOF

done. $HOST holds a key it cannot export and a certificate for it.

  serial number: $serial
  certificate:   $cert
  CA:            $CA_DIR/rootCA.crt

Add a device with that serial number in NervesHub and upload the certificate
against it.
EOF
