#!/usr/bin/env bash
# =============================================================================
# FraudBuster - Host MongoDB 7 Kurulumu (tek node'lu replica set: rs0)
# =============================================================================
# Ubuntu/Debian (apt) ve RHEL/CentOS/Rocky (yum/dnf) destekler.
# Change stream'ler icin replica set SARTTIR; bu script standalone yerine
# tek node'lu rs0 kurar.
#
# Kullanim: sudo bash setup-mongodb.sh
# =============================================================================
set -euo pipefail

MONGO_VERSION="7.0"
REPL_SET="rs0"
DB_NAME="fraudmanagement"

# Eger Docker kullanacaksaniz comment edilmis Docker Bridge satirini kullanin 
#   Yok eger bagimsiz VM kullanacaksaniz mevcut durum ile ilerleyin
#
# Docker bridge'den erisim icin 172.17.0.1 (docker0) da dinlenir.
# BIND_IP="127.0.0.1,172.17.0.1"
#
# Harici VM senaryosu: OpenShift cluster'i agdan baglanir; erisim
# firewall/security group ile kisitlanmalidir (27017 yalniz cluster'a).
BIND_IP="0.0.0.0"

log()  { echo "[setup-mongodb] $*"; }
fail() { echo "[setup-mongodb] HATA: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Bu script root ile calistirilmali (sudo)."

# ── 1. Kurulum ───────────────────────────────────────────────────────────────
if command -v mongod >/dev/null 2>&1; then
    log "mongod zaten kurulu: $(mongod --version | head -1)"
else
    if command -v apt-get >/dev/null 2>&1; then
        log "Ubuntu/Debian tespit edildi, MongoDB ${MONGO_VERSION} kuruluyor..."
        apt-get install -y gnupg curl
        curl -fsSL "https://www.mongodb.org/static/pgp/server-${MONGO_VERSION}.asc" \
            | gpg --dearmor -o /usr/share/keyrings/mongodb-server.gpg
        . /etc/os-release
        echo "deb [signed-by=/usr/share/keyrings/mongodb-server.gpg] https://repo.mongodb.org/apt/ubuntu ${VERSION_CODENAME}/mongodb-org/${MONGO_VERSION} multiverse" \
            > /etc/apt/sources.list.d/mongodb-org.list
        apt-get update -y
        apt-get install -y mongodb-org
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        log "RHEL/CentOS tespit edildi, MongoDB ${MONGO_VERSION} kuruluyor..."
        cat > /etc/yum.repos.d/mongodb-org.repo <<EOF
[mongodb-org]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/\$releasever/mongodb-org/${MONGO_VERSION}/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-${MONGO_VERSION}.asc
EOF
        (command -v dnf >/dev/null 2>&1 && dnf install -y mongodb-org) || yum install -y mongodb-org
    else
        fail "Desteklenmeyen paket yoneticisi. MongoDB'yi manuel kurun: https://www.mongodb.com/docs/manual/installation/"
    fi
fi

# ── 2. Konfigurasyon: replica set + bind IP ─────────────────────────────────
MONGOD_CONF="/etc/mongod.conf"
[ -f "$MONGOD_CONF" ] || fail "$MONGOD_CONF bulunamadi."

cp -n "$MONGOD_CONF" "${MONGOD_CONF}.orig" || true

log "Konfigurasyon guncelleniyor: bindIp=${BIND_IP}, replSetName=${REPL_SET}"
python3 - "$MONGOD_CONF" "$BIND_IP" "$REPL_SET" <<'PYEOF'
import re, sys
path, bind_ip, repl_set = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    conf = f.read()

conf = re.sub(r"bindIp:.*", f"bindIp: {bind_ip}", conf)

if re.search(r"^replication:", conf, re.M):
    if "replSetName" not in conf:
        conf = re.sub(r"^replication:.*$", f"replication:\n  replSetName: {repl_set}", conf, flags=re.M)
elif re.search(r"^#replication:", conf, re.M):
    conf = re.sub(r"^#replication:.*$", f"replication:\n  replSetName: {repl_set}", conf, flags=re.M)
else:
    conf += f"\nreplication:\n  replSetName: {repl_set}\n"

with open(path, "w") as f:
    f.write(conf)
PYEOF

# ── 3. Servisi baslat ────────────────────────────────────────────────────────
systemctl enable mongod
systemctl restart mongod
log "mongod baslatildi, replica set init bekleniyor..."
sleep 5

# ── 4. Replica set'i baslat (idempotent) ─────────────────────────────────────
mongosh --quiet --eval "
try {
  rs.status();
  print('[setup-mongodb] Replica set zaten aktif.');
} catch(e) {
  rs.initiate({_id: '${REPL_SET}', members: [{_id: 0, host: 'localhost:27017'}]});
  print('[setup-mongodb] Replica set baslatildi: ${REPL_SET}');
}
"

sleep 3

# ── 5. Dogrulama ─────────────────────────────────────────────────────────────
STATE=$(mongosh --quiet --eval "rs.status().members[0].stateStr" || echo "ERROR")
if [ "$STATE" = "PRIMARY" ]; then
    log "OK - MongoDB ${REPL_SET} PRIMARY olarak calisiyor."
    log "Baglanti URI'si: mongodb://<host>:27017/${DB_NAME}?replicaSet=${REPL_SET}&directConnection=true"
else
    fail "Replica set PRIMARY duruma gecemedi (durum: ${STATE}). 'mongosh --eval \"rs.status()\"' ile kontrol edin."
fi

log "NOT: Guvenlik icin production'da MongoDB auth acmaniz onerilir"
log "     (security.authorization: enabled + keyFile). Bkz. DEPLOYMENT_CUSTOMER.md - Guvenlik bolumu."
