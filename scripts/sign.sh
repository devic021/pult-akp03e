#!/bin/sh
# Signs the installed binary with a local certificate, so macOS keeps trusting
# it across rebuilds.
#
# An unsigned binary's designated requirement contains a hash of its contents,
# so every rebuild looks like a different program and the Accessibility grant
# silently stops applying. Signed with a fixed certificate, the requirement
# becomes `identifier "dev.akp03-deck" and certificate leaf = H"..."`, which
# every later build satisfies.
set -eu

CERT_NAME="akp03-deck local signing"
IDENTIFIER="dev.akp03-deck"
BIN="${1:-$HOME/.local/bin/akp03-deck}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if ! security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
	echo "creating certificate: $CERT_NAME"
	WORK="$(mktemp -d)"
	trap 'rm -rf "$WORK"' EXIT

	cat > "$WORK/req.cnf" <<-CNF
	[req]
	distinguished_name = dn
	x509_extensions = v3
	prompt = no

	[dn]
	CN = $CERT_NAME

	[v3]
	basicConstraints = critical,CA:FALSE
	keyUsage = critical,digitalSignature
	extendedKeyUsage = critical,codeSigning
	CNF

	/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
		-config "$WORK/req.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

	# `security` cannot read a PKCS#12 with an empty password or modern
	# algorithms, so both are kept deliberately old-fashioned. The file is
	# deleted on the way out; the key lives in the keychain.
	/usr/bin/openssl pkcs12 -export -out "$WORK/id.p12" \
		-inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$CERT_NAME" \
		-macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES \
		-passout pass:akp03deck 2>/dev/null

	security import "$WORK/id.p12" -k "$KEYCHAIN" -P akp03deck -T /usr/bin/codesign
else
	echo "certificate already present: $CERT_NAME"
fi

codesign --force --sign "$CERT_NAME" --identifier "$IDENTIFIER" "$BIN"
codesign --verify --verbose=1 "$BIN"
echo
echo "designated requirement:"
codesign -d -r- "$BIN" 2>&1 | grep '^designated'
