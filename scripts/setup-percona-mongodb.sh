#!/usr/bin/env bash
# =============================================================================
# FraudBuster - Percona Server for MongoDB 7 Kurulumu
#   - tek node'lu replica set (rs0)  → change stream'ler icin ZORUNLU
#   - authentication + keyFile       → kullanici bazli erisim
#   - auditLog                       → kim, ne zaman, ne yapti kaydi
# =============================================================================
# Percona Server for MongoDB, MongoDB Community'nin drop-in karsiligidir:
# ayni wire protocol, ayni driver'lar, ayni port. MongoDB Community'de
# bulunmayan auditLog ozelligini ucretsiz saglar.
#
# Kullanim:
#   sudo bash setup-percona-mongodb.sh '<ADMIN_SIFRE>' '<APP_SIFRE>'
#
# Ubuntu/Debian (apt) ve RHEL/CentOS/Rocky (yum/dnf) destekler.
# =============================================================================
set -euo pipefail

PSMDB_REPO="psmdb-70"
REPL_SET="rs0"
DB_NAME="fraudmanagement"
ADMIN_USER="fraud_admin"
APP_USER="fraud_app"

# Harici VM senaryosu: cluster agdan baglanir; erisim firewall/security group
# ile kisitlanmalidir (27017 yalniz cluster node'larina).
BIND_IP="0.0.0.0"

MONGOD_CONF="/etc/mongod.conf"
KEYFILE="/etc/mongodb-keyfile"
AUDIT_DIR="/var/log/mongodb"
AUDIT_PATH="${AUDIT_DIR}/audit.json"

log()  { echo "[setup-percona-mongodb] $*"; }
fail() { echo "[setup-percona-mongodb] HATA: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Bu script root ile calistirilmali (sudo)."

ADMIN_PASSWORD="${1:-}"
APP_PASSWORD="${2:-}"
[ -n "$ADMIN_PASSWORD" ] || fail "Admin sifresi verilmedi. Kullanim: sudo bash $0 '<ADMIN_SIFRE>' '<APP_SIFRE>'"
[ -n "$APP_PASSWORD" ]   || fail "Uygulama sifresi verilmedi. Kullanim: sudo bash $0 '<ADMIN_SIFRE>' '<APP_SIFRE>'"

# ── 1. Kurulum ───────────────────────────────────────────────────────────────
if command -v mongod >/dev/null 2>&1 && mongod --version 2>/dev/null | grep -qi percona; then
    log "Percona Server for MongoDB zaten kurulu: $(mongod --version | head -1)"
else
    if command -v mongod >/dev/null 2>&1; then
        fail "Bu makinede MongoDB Community kurulu. Percona'ya gecis icin once mevcut kurulumu kaldirin (veri yedegini aldiktan sonra)."
    fi

    if command -v apt-get >/dev/null 2>&1; then
        log "Ubuntu/Debian tespit edildi, Percona Server for MongoDB kuruluyor..."
        apt-get update -y
        apt-get install -y curl gnupg
        curl -fsSL -o /tmp/percona-release.deb \
            https://repo.percona.com/apt/percona-release_latest.generic_all.deb
        apt-get install -y /tmp/percona-release.deb
        percona-release enable "$PSMDB_REPO" release
        apt-get update -y
        apt-get install -y percona-server-mongodb
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        log "RHEL/CentOS tespit edildi, Percona Server for MongoDB kuruluyor..."
        PKG=$(command -v dnf || command -v yum)
        "$PKG" install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm
        percona-release enable "$PSMDB_REPO" release
        "$PKG" install -y percona-server-mongodb
    else
        fail "Desteklenmeyen paket yoneticisi. Kurulum: https://docs.percona.com/percona-server-for-mongodb/"
    fi
fi

[ -f "$MONGOD_CONF" ] || fail "$MONGOD_CONF bulunamadi."
cp -n "$MONGOD_CONF" "${MONGOD_CONF}.orig" || true

# mongod servisinin calistigi kullanici (Percona paketlerinde 'mongod')
MONGO_USER="$(stat -c '%U' "$AUDIT_DIR" 2>/dev/null || echo mongod)"
id "$MONGO_USER" >/dev/null 2>&1 || MONGO_USER="mongod"

# ── 2. Asama 1: auth KAPALI konfigurasyon (bindIp + replSet + auditLog) ──────
# Kullanicilar olusturulmadan auth acilirsa sunucuya erisim kalmaz; bu yuzden
# once replica set ve auditLog kurulur, kullanicilar yaratilir, auth en sonda
# acilir.
log "Asama 1 konfigurasyonu: bindIp=${BIND_IP}, replSetName=${REPL_SET}, auditLog=${AUDIT_PATH}"

mkdir -p "$AUDIT_DIR"
chown "$MONGO_USER":"$MONGO_USER" "$AUDIT_DIR"

python3 - "$MONGOD_CONF" "$BIND_IP" "$REPL_SET" "$AUDIT_PATH" <<'PYEOF'
import re, sys
path, bind_ip, repl_set, audit_path = sys.argv[1:5]
with open(path) as f:
    conf = f.read()

conf = re.sub(r"bindIp:.*", f"bindIp: {bind_ip}", conf)

# replication
if re.search(r"^replication:", conf, re.M):
    if "replSetName" not in conf:
        conf = re.sub(r"^replication:.*$", f"replication:\n  replSetName: {repl_set}", conf, flags=re.M)
elif re.search(r"^#replication:", conf, re.M):
    conf = re.sub(r"^#replication:.*$", f"replication:\n  replSetName: {repl_set}", conf, flags=re.M)
else:
    conf += f"\nreplication:\n  replSetName: {repl_set}\n"

# auditLog (Percona Server for MongoDB)
conf = re.sub(r"^auditLog:\n(?:[ \t]+.*\n)*", "", conf, flags=re.M)
conf += (
    "\nauditLog:\n"
    "  destination: file\n"
    "  format: JSON\n"
    f"  path: {audit_path}\n"
)

with open(path, "w") as f:
    f.write(conf)
PYEOF

systemctl enable mongod
systemctl restart mongod
log "mongod baslatildi, replica set init bekleniyor..."
sleep 5

# ── 3. Replica set'i baslat (idempotent) ─────────────────────────────────────
mongosh --quiet --eval "
try {
  rs.status();
  print('[setup-percona-mongodb] Replica set zaten aktif.');
} catch(e) {
  rs.initiate({_id: '${REPL_SET}', members: [{_id: 0, host: 'localhost:27017'}]});
  print('[setup-percona-mongodb] Replica set baslatildi: ${REPL_SET}');
}
"
sleep 5

STATE=$(mongosh --quiet --eval "rs.status().members[0].stateStr" || echo "ERROR")
[ "$STATE" = "PRIMARY" ] || fail "Replica set PRIMARY duruma gecemedi (durum: ${STATE})."
log "Replica set PRIMARY."

# ── 4. Kullanicilari olustur (auth henuz KAPALI) ─────────────────────────────
# fraud_admin : admin veritabaninda, kullanici/rol yonetimi + cluster yonetimi
# fraud_app   : fraudmanagement veritabaninda readWrite (change stream dahil)
log "Kullanicilar olusturuluyor: ${ADMIN_USER} (admin), ${APP_USER} (${DB_NAME})"

mongosh --quiet <<EOF
const adminDb = db.getSiblingDB('admin');
if (adminDb.getUser('${ADMIN_USER}') === null) {
  adminDb.createUser({
    user: '${ADMIN_USER}',
    pwd:  '${ADMIN_PASSWORD}',
    roles: [ { role: 'root', db: 'admin' } ]
  });
  print('[setup-percona-mongodb] ${ADMIN_USER} olusturuldu.');
} else {
  print('[setup-percona-mongodb] ${ADMIN_USER} zaten mevcut.');
}

const appDb = db.getSiblingDB('${DB_NAME}');
if (appDb.getUser('${APP_USER}') === null) {
  appDb.createUser({
    user: '${APP_USER}',
    pwd:  '${APP_PASSWORD}',
    roles: [ { role: 'readWrite', db: '${DB_NAME}' } ]
  });
  print('[setup-percona-mongodb] ${APP_USER} olusturuldu.');
} else {
  print('[setup-percona-mongodb] ${APP_USER} zaten mevcut.');
}
EOF

# ── 5. keyFile (replica set internal authentication) ─────────────────────────
if [ ! -f "$KEYFILE" ]; then
    log "keyFile olusturuluyor: $KEYFILE"
    openssl rand -base64 756 > "$KEYFILE"
fi
chown "$MONGO_USER":"$MONGO_USER" "$KEYFILE"
chmod 400 "$KEYFILE"

# ── 6. Asama 2: authentication'i ac ──────────────────────────────────────────
log "Authentication aciliyor (security.authorization + keyFile)"

python3 - "$MONGOD_CONF" "$KEYFILE" <<'PYEOF'
import re, sys
path, keyfile = sys.argv[1:3]
with open(path) as f:
    conf = f.read()

conf = re.sub(r"^security:\n(?:[ \t]+.*\n)*", "", conf, flags=re.M)
conf = re.sub(r"^#security:.*$", "", conf, flags=re.M)
conf += (
    "\nsecurity:\n"
    "  authorization: enabled\n"
    f"  keyFile: {keyfile}\n"
)

with open(path, "w") as f:
    f.write(conf)
PYEOF

systemctl restart mongod
sleep 5

# ── 7. Dogrulama ─────────────────────────────────────────────────────────────
log "Dogrulama yapiliyor..."

# 7a. Kimlik dogrulamasiz erisim reddedilmeli
if mongosh --quiet --eval "db.getSiblingDB('${DB_NAME}').getCollectionNames()" >/dev/null 2>&1; then
    fail "Kimlik dogrulamasiz erisim hala mumkun; security.authorization uygulanmamis."
fi
log "OK - kimlik dogrulamasiz erisim reddediliyor."

# 7b. Uygulama kullanicisi baglanabilmeli
APP_URI="mongodb://${APP_USER}:${APP_PASSWORD}@localhost:27017/${DB_NAME}?replicaSet=${REPL_SET}&directConnection=true"
mongosh "$APP_URI" --quiet --eval "db.runCommand({ping: 1}).ok" >/dev/null \
    || fail "Uygulama kullanicisi (${APP_USER}) baglanamadi."
log "OK - ${APP_USER} baglanabiliyor."

# 7c. Replica set durumu
STATE=$(mongosh "mongodb://${ADMIN_USER}:${ADMIN_PASSWORD}@localhost:27017/admin?directConnection=true" \
    --quiet --eval "rs.status().members[0].stateStr" || echo "ERROR")
[ "$STATE" = "PRIMARY" ] || fail "Replica set PRIMARY degil (durum: ${STATE})."
log "OK - replica set PRIMARY."

# 7d. Audit log yaziliyor mu
sleep 2
if [ -s "$AUDIT_PATH" ]; then
    log "OK - audit log yaziliyor: $AUDIT_PATH ($(wc -l < "$AUDIT_PATH") kayit)"
else
    fail "Audit log olusmadi: $AUDIT_PATH"
fi

chmod 640 "$AUDIT_PATH" || true

# ── 8. Ozet ──────────────────────────────────────────────────────────────────
cat <<EOF

[setup-percona-mongodb] KURULUM TAMAMLANDI

  Surum          : $(mongod --version | head -1)
  Replica set    : ${REPL_SET} (PRIMARY)
  Audit log      : ${AUDIT_PATH}
  Yonetici       : ${ADMIN_USER} (admin veritabani, root rolu)
  Uygulama       : ${APP_USER} (${DB_NAME}, readWrite)

  Chart icin baglanti bilgileri:
    host     : <BU_VM_PRIVATE_IP>
    port     : 27017
    user     : ${APP_USER}
    database : ${DB_NAME}
    params   : replicaSet=${REPL_SET}&directConnection=true&maxPoolSize=50&minPoolSize=10&maxIdleTimeMS=60000&waitQueueTimeoutMS=5000&serverSelectionTimeoutMS=5000

  Audit kayitlarini incelemek icin:
    sudo tail -n 5 ${AUDIT_PATH} | jq .

  NOT: 27017/TCP portu yalnizca cluster node'larina acilmalidir.

EOF
