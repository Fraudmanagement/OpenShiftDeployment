#!/usr/bin/env bash
# =============================================================================
# FraudBuster - Host ClickHouse Kurulumu + Sema Olusturma
# =============================================================================
# Event gecmisi ve analitik sorgular icin ClickHouse server kurar,
# default kullanicisina sifre atar ve clickhouse-init.sql'i calistirir.
#
# Kullanim: sudo bash setup-clickhouse.sh <SIFRE>
#   ornek : sudo bash setup-clickhouse.sh 'Guclu@Sifre123'
#
# Not: <SIFRE> degerini .env icindeki CLICKHOUSE_PASSWORD ile ayni yapin.
# =============================================================================
set -euo pipefail

CH_PASSWORD="${1:-}"
[ -n "$CH_PASSWORD" ] || { echo "Kullanim: sudo bash setup-clickhouse.sh <SIFRE>"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Repo icinden calistirilirsa init.sql iki ust dizindedir (FM_BE/).
INIT_SQL="${INIT_SQL:-$SCRIPT_DIR/clickhouse-01-init.sql}"
# Materialized view'lar (analitik dashboard hizlandirmasi icin) - opsiyonel ama
# varsayilan olarak bu script tarafindan otomatik olusturulur. BE motoru bunlari
# KENDISI OLUSTURMAZ (sadece events/model_features tablolarini olusturur) ve
# UI bu view'lar yoksa raw tabloya fallback yapar; yine de buyuk veri
# hacminde (7g/30g pencereler) dashboard performansi icin gereklidir.
VIEWS_SQL="${VIEWS_SQL:-$SCRIPT_DIR/clickhouse-02-views.sql}"
LISTEN_HOST="0.0.0.0"   # docker bridge erisimi icin; firewall ile 8123/9000 disari kapatilmali

log()  { echo "[setup-clickhouse] $*"; }
fail() { echo "[setup-clickhouse] HATA: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Bu script root ile calistirilmali (sudo)."
[ -f "$INIT_SQL" ] || fail "clickhouse-init.sql bulunamadi: $INIT_SQL (INIT_SQL env ile yol verebilirsiniz)"

# ── 1. Kurulum ───────────────────────────────────────────────────────────────
if command -v clickhouse-server >/dev/null 2>&1; then
    log "clickhouse-server zaten kurulu."
else
    if command -v apt-get >/dev/null 2>&1; then
        log "Ubuntu/Debian tespit edildi, ClickHouse kuruluyor..."
        apt-get install -y apt-transport-https ca-certificates curl gnupg
        curl -fsSL https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key \
            | gpg --dearmor -o /usr/share/keyrings/clickhouse-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg] https://packages.clickhouse.com/deb stable main" \
            > /etc/apt/sources.list.d/clickhouse.list
        apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y clickhouse-server clickhouse-client
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        log "RHEL/CentOS tespit edildi, ClickHouse kuruluyor..."
        curl -fsSL https://packages.clickhouse.com/rpm/clickhouse.repo \
            -o /etc/yum.repos.d/clickhouse.repo
        (command -v dnf >/dev/null 2>&1 && dnf install -y clickhouse-server clickhouse-client) \
            || yum install -y clickhouse-server clickhouse-client
    else
        fail "Desteklenmeyen paket yoneticisi. ClickHouse'u manuel kurun: https://clickhouse.com/docs/install"
    fi
fi

# ── 2. Konfigurasyon: dinleme adresi + default sifre ────────────────────────
mkdir -p /etc/clickhouse-server/config.d /etc/clickhouse-server/users.d

cat > /etc/clickhouse-server/config.d/fraudbuster-listen.xml <<EOF
<clickhouse>
    <listen_host>${LISTEN_HOST}</listen_host>
</clickhouse>
EOF

# Sifre SHA256 olarak saklanir.
PASS_SHA=$(echo -n "$CH_PASSWORD" | sha256sum | awk '{print $1}')
cat > /etc/clickhouse-server/users.d/fraudbuster-default-password.xml <<EOF
<clickhouse>
    <users>
        <default>
            <password remove="1"/>
            <password_sha256_hex>${PASS_SHA}</password_sha256_hex>
            <access_management>1</access_management>
        </default>
    </users>
</clickhouse>
EOF
chown -R clickhouse:clickhouse /etc/clickhouse-server/config.d /etc/clickhouse-server/users.d

systemctl enable clickhouse-server
systemctl restart clickhouse-server
log "clickhouse-server baslatildi, hazir olmasi bekleniyor..."
for i in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:8123/ping" >/dev/null 2>&1; then break; fi
    sleep 2
    [ "$i" -eq 30 ] && fail "ClickHouse 60 saniyede hazir olmadi. 'journalctl -u clickhouse-server' kontrol edin."
done

# ── 3. Sema olusturma (clickhouse-init.sql) ──────────────────────────────────
log "Sema olusturuluyor: $INIT_SQL"
clickhouse-client --host 127.0.0.1 --user default --password "$CH_PASSWORD" \
    --multiquery < "$INIT_SQL"

# ── 4. Analitik view'lari (opsiyonel, ama varsayilan olarak calistirilir) ────
# clickhouse-init.sql SADECE tablolari olusturur (events, model_features);
# view'lar burada, ayri bir adimda olusturulur. POPULATE ile mevcut event'ler
# uzerinden geriye donuk doldurulur, bu yuzden buyuk bir tablo uzerinde
# calistirilirsa (ilk kurulumda genelde bos oldugu icin sorun olmaz) biraz
# zaman alabilir.
if [ -f "$VIEWS_SQL" ]; then
    log "Analitik view'lari olusturuluyor: $VIEWS_SQL"
    if clickhouse-client --host 127.0.0.1 --user default --password "$CH_PASSWORD" \
        --multiquery < "$VIEWS_SQL"; then
        log "Analitik view'lari hazir."
    else
        log "UYARI: Analitik view'lari olusturulamadi (dashboard raw tabloya fallback yapar, calismaya devam eder). VIEWS_SQL=$VIEWS_SQL"
    fi
else
    log "UYARI: $VIEWS_SQL bulunamadi, view olusturma adimi atlandi (VIEWS_SQL env ile yol verebilirsiniz)."
fi

# ── 5. Dogrulama ─────────────────────────────────────────────────────────────
TABLES=$(clickhouse-client --host 127.0.0.1 --user default --password "$CH_PASSWORD" \
    --query "SHOW TABLES FROM fraudbuster" | tr '\n' ' ')
echo "$TABLES" | grep -q "events" || fail "fraudbuster.events tablosu olusmadi."
log "OK - ClickHouse hazir. Tablolar/view'lar: $TABLES"
log "NOT: Firewall'da 8123 ve 9000 portlarini dis aga KAPATIN (sadece host + docker bridge erismeli)."
