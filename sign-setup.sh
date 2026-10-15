#!/bin/zsh
# Legt einmalig ein lokales Signaturzertifikat „Klar Dev“ an und vertraut ihm für Code-Signierung.
# Danach behält Klar seine Systemfreigaben (Bedienungshilfen, Mikrofon, Bildschirm) über Neubauten hinweg.
# macOS fragt dabei in einem Dialogfenster (nicht im Terminal) nach dem Anmeldepasswort.
set -e
# Das System-OpenSSL (LibreSSL) erzeugt PKCS#12-Dateien, die der macOS-Schlüsselbund importieren kann.
# Das Homebrew-OpenSSL 3.x nutzt neuere Standards, an denen „security import“ scheitert.
OPENSSL=/usr/bin/openssl
step() { echo "→ $1"; }
if security find-identity -v -p codesigning | grep -q "Klar Dev"; then
  echo "Zertifikat „Klar Dev“ ist bereits vorhanden."; exit 0
fi
T=$(mktemp -d)
cat > "$T/klar.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Klar Dev
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CNF
step "Schlüssel und Zertifikat erzeugen"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$T/klar.key" -out "$T/klar.crt" -config "$T/klar.cnf" 2>/dev/null
step "PKCS#12 packen"
"$OPENSSL" pkcs12 -export -inkey "$T/klar.key" -in "$T/klar.crt" -out "$T/klar.p12" -passout pass:klar -name "Klar Dev" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
step "In den Anmelde-Schlüsselbund importieren"
security import "$T/klar.p12" -k ~/Library/Keychains/login.keychain-db -P klar -T /usr/bin/codesign
step "Zertifikat für Code-Signierung vertrauen (macOS fragt jetzt nach dem Anmeldepasswort)"
security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db "$T/klar.crt"
rm -rf "$T"
if security find-identity -v -p codesigning | grep -q "Klar Dev"; then
  echo "Fertig. Jetzt ./build.sh --open ausführen."
else
  echo "Zertifikat wurde importiert, aber nicht als Signatur-Identität erkannt." >&2
  security find-identity -v -p codesigning >&2
  exit 1
fi
