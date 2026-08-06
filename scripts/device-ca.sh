#!/bin/sh
#
# Device CA for issuing device certificates.
#
#   ./device-ca.sh create               make rootCA.key and rootCA.crt
#   ./device-ca.sh sign <csr> <serial>  sign one device CSR
#
# Keep rootCA.key off devices and out of git. Anything holding it can mint an
# identity for the whole fleet, which is the one secret this scheme has.

set -e

CA_DIR="${CA_DIR:-./ca}"
DAYS_CA="${DAYS_CA:-3650}"
DAYS_DEVICE="${DAYS_DEVICE:-3650}"

usage() {
    sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

create() {
    mkdir -p "$CA_DIR"

    if [ -f "$CA_DIR/rootCA.key" ]; then
        echo "$CA_DIR/rootCA.key exists; refusing to overwrite it" >&2
        exit 1
    fi

    openssl genrsa -out "$CA_DIR/rootCA.key" 4096
    openssl req -new -x509 -key "$CA_DIR/rootCA.key" -sha256 -days "$DAYS_CA" \
        -subj "/CN=Sige5 Device CA/O=${CA_ORG:-Sige5}" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -addext "subjectKeyIdentifier=hash" \
        -out "$CA_DIR/rootCA.crt"

    chmod 600 "$CA_DIR/rootCA.key"
    echo "$CA_DIR/rootCA.crt"
}

# The CN has to be the serial number: that is the identifier NervesHub creates
# the device under.
sign() {
    csr="$1"
    serial="$2"
    [ -n "$csr" ] && [ -n "$serial" ] || usage

    out="$CA_DIR/$serial.crt"

    openssl x509 -req -in "$csr" \
        -CA "$CA_DIR/rootCA.crt" -CAkey "$CA_DIR/rootCA.key" -CAcreateserial \
        -days "$DAYS_DEVICE" -sha256 \
        -extfile /dev/stdin \
        -out "$out" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=clientAuth
subjectKeyIdentifier=hash
EOF

    subject=$(openssl x509 -in "$out" -noout -subject)
    case "$subject" in
        *"CN=$serial"*) ;;
        *)
            echo "the CSR's CN is not $serial: $subject" >&2
            echo "NervesHub identifies the device by CN, so this would not match" >&2
            rm -f "$out"
            exit 1
            ;;
    esac

    echo "$out"
}

case "$1" in
    create) create ;;
    sign)   sign "$2" "$3" ;;
    *)      usage ;;
esac
