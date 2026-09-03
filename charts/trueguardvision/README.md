# TrueGuardVision — OpenShift Helm Chart

TrueGuardVision fraud yönetim platformunun OpenShift üzerinde Helm ile
kurulumu için hazırlanmıştır. Bu doküman kurulum, kullanım, yapılandırma ve
işletmeye dair başvuru kaynağıdır.

## İçindekiler

1. [Sistem Genel Bakış](#1-sistem-genel-bakış)
2. [Ortam ve Boyutlandırma](#2-ortam-ve-boyutlandırma)
3. [Kurulum ve Yaşam Döngüsü](#3-kurulum-ve-yaşam-döngüsü)
4. [Veritabanı Kurulumları](#4-veritabanı-kurulumları-mongodb--clickhouse)
5. [Kullanım](#5-kullanım)
6. [Kapsam (OpenShift içi ve dışı)](#6-kapsam-openshift-içi-ve-dışı)
7. [Values Referansı](#7-values-referansı)
8. [Güvenlik ve Ağ](#8-güvenlik-ve-ağ)
9. [Audit](#9-audit)

---

## 1. Sistem Genel Bakış

### Bileşenler

| Bileşen | Görev | Çalıştığı Yer |
|---|---|---|
| **FM Engine** (`fraudbuster-be`) | Event skorlama, kural değerlendirme, incident üretimi (Rust) | OpenShift |
| **FM Portal** (`fraudbuster-ui`) | Analist arayüzü: kural/aksiyon/liste yönetimi, incident takibi, raporlama | OpenShift |
| **Dragonfly** | Redis uyumlu bellek-içi veri deposu; aktör profilleri, kayan pencere sayaçları (bucket), listeler — skorlamanın sıcak yolu | **OpenShift dışı** (banka ağında VM) |
| **Event Simulator** (`eventsimulator-engine` / `-ui`) | Yük üreteci ve test arayüzü; yalnızca test/POC amaçlıdır, ürünün parçası değildir | OpenShift |
| **MongoDB** | Kural/aksiyon/liste tanımları, kullanıcı ve roller, incident kayıtları; change stream ile Engine'e canlı yapılandırma akışı | **OpenShift dışı** (banka ağında VM) |
| **ClickHouse** | İşlenen tüm event'lerin kalıcı arşivi ve analitik sorgular (sütunsal OLAP veritabanı) | **OpenShift dışı** (banka ağında VM) |

### Akış (özet)

```
  Event Kaynağı                 ┌──────────────────── OpenShift ────────────────────┐
  (POC'de: Event Simulator,    │                                                    │
   üretimde: banka sistemleri) │   FM ENGINE ──────────► DRAGONFLY VM (6379/TCP)    │
        │  POST /events (JWT)  │      │                    (sayaçlar, RAM)          │
        └──────────────────────┼─────►│  1. sayaçları oku/güncelle                  │
                               │      │  2. kuralları çalıştır                      │
  Fraud Analisti               │      │  3. tetiklenirse → MongoDB'ye incident      │
        │ HTTPS (Route)        │      │  4. event'i → ClickHouse'a arşivle (async)  │
        └──────────────────────┼─► FM PORTAL                                        │
                               │      │  kural/liste tanımı → MongoDB               │
                               └──────┼─────────────────────────────────────────────┘
                                      ▼
        Dragonfly (sayaçlar)   MongoDB (yapılandırma + incident)   ClickHouse (arşiv)
        — cluster dışı VM,     — change stream ile kural           — Portal raporları
          audit yapılandırmalı   değişikliği Engine'e anında         buradan sorgular
                                 yansır
```

---

## 2. Ortam ve Boyutlandırma

Chart, üretim boyutlandırmasını içeren profil dosyasıyla kurulur:
`values-customer.yaml` (kaynak: ürün paketindeki `env.template`). Taban
`values.yaml` compose fallback değerlerini taşır ve her kurulumda otomatik
yüklenir; profil kurulumda `-f` ile verilir.

### Önerilen POC kapasitesi (ürün dokümanındaki hedef mimari)

| Bileşen | CPU / RAM / Disk | Yerleşim |
|---|---|---|
| FM Engine | 32 CPU / 64 GB / 200 GB | OpenShift — dedicated hot-path worker |
| **Dragonfly VM** | 32 CPU / 64 GB / 300 GB | **Cluster dışı, banka ağı** — audit yapılandırmalı |
| FM Portal | 8 CPU / 8 GB / 50 GB | OpenShift — genel worker |
| Event Simulator Engine | 16 CPU / 16 GB / 100 GB | OpenShift — Engine'den FARKLI worker (ölçüm saflığı) |
| Event Simulator UI | 2 CPU / 4 GB | OpenShift — genel worker |
| MongoDB VM | 16 CPU / 32 GB / 300 GB | Cluster dışı, banka ağı, rs0 |
| ClickHouse VM | 16 CPU / 32 GB / 1 TB | Cluster dışı, banka ağı |

Not: `FRAUDBUSTER_DRAGONFLY_SHARD_COUNT` env'i bilinçli olarak
kullanılmamaktadır — Engine, shard sayısını bağlantı sırasında Dragonfly'dan
(`INFO thread_count`) otomatik öğrenir; tek ayar noktası Dragonfly VM'indeki
`--proactor_threads` parametresidir (bkz.
[`dragonfly-setup/`](../../dragonfly-setup/dragonfly-setup-guideline-for-audit.md)).

---

## 3. Kurulum ve Yaşam Döngüsü

### Ön koşullar

- OpenShift 4.x cluster'ı ve proje oluşturma yetkisi (`oc` girişi yapılmış olmalı)
- MongoDB (replica set `rs0`) ve ClickHouse'un banka ağında kurulu ve
  cluster'dan erişilebilir olması (kurulum için bkz. Bölüm 4)
- Dragonfly'ın banka ağındaki VM'de kurulu, ACL'i tanımlanmış ve cluster'dan
  erişilebilir olması (kurulum için bkz.
  [`dragonfly-setup/`](../../dragonfly-setup/dragonfly-setup-guideline-for-audit.md))
- `ghcr.io/fraudmanagement` imajları için erişim token'ı (ya da imajların
  banka registry'sine mirror edilmiş olması)

### Kurulum

**Pod yerleşimi:** `simulator.engine.fraudEnginePlacement` alanı, Event
Simulator engine'inin FM Engine'e göre yerleşimini yönetir ve üç değer alır:

| Değer | Davranış | Ne zaman |
|---|---|---|
| `colocate` | İlgili pod'lar AYNI node'a yerleşir (podAffinity, zorunlu) | Node kapasitesi iki iş yükünün limit toplamına bol geliyorsa — node içi trafik, ağ gecikmesini sıfırlar |
| `separate` | İlgili pod'lar FARKLI node'lara yerleşir (podAntiAffinity, zorunlu) | Dar node'larda CPU çekişmesini önlemek için; yük üreteci için her durumda önerilir (ölçüm sağlığı) |
| `none` | Kural yok; scheduler serbest | Yerleşim önemli değilse |

Varsayılan (`values-customer.yaml`): `fraudEnginePlacement: separate`.
Zorunlu kurallar kullanılıyorsa cluster'da en az 2 worker node olmalıdır.

Dragonfly cluster dışında çalıştığından FM Engine ile arasında pod yerleşim
kuralı bulunmaz; bağlantı `engine.dragonflyHost` üzerinden ağ katmanında
kurulur. Engine node'ları ile Dragonfly VM'i arasındaki ağ gecikmesinin düşük
tutulması (aynı subnet / availability zone) önerilir.

Aşağıdaki tüm komutlar repo kökünden (bu README'nin bulunduğu dizinden, chart
yolu `./charts/trueguardvision` olacak şekilde) çalıştırılır.

Chart iki values katmanıyla çalışır: `values.yaml` her kurulumda otomatik
yüklenen tabandır; üzerine `-f` ile `values-customer.yaml` verilir.

**Müşteri kurulumu** (üretim boyutlandırması):

Kurulumdan önce `values-customer.yaml` içinde doldurun: `MONGO_VM_IP`,
`CLICKHOUSE_VM_IP`, `engine.dragonflyHost` (Dragonfly VM'inin IP'si) ve
`ChangeMe*` parolaları. Kurulum komutu:

```bash
helm install trueguardvision ./charts/trueguardvision -n fraud-poc --create-namespace \
  -f charts/trueguardvision/values-customer.yaml \
  --set clusterDomain=apps.rosa.altay.6j68.p3.openshiftapps.com \
  --set imagePullSecret.token=ghp_**** \
  --set engine.dragonflyPassword='<engine ACL sifresi>'
```

`engine.dragonflyPassword`, Dragonfly VM'inde tanımlanan `engine` ACL
kullanıcısının şifresidir; Secret içinde saklanır ve bağlantı URI'sine
otomatik olarak eklenir.

(Domain örnektir, kendi domain'inizle değiştirin.)

Alternatif: bu iki `--set` yerine değerleri `values-customer.yaml` içine de
yazabilirsiniz — `clusterDomain` dosyanın başındaki alana,
token `imagePullSecret:` bloğundaki `token:` alanına:

```yaml
clusterDomain: "apps.<sizin-cluster-domain>"

imagePullSecret:
  token: "ghp_****"     # önerilmez — güvenlik notuna bakın
```

Güvenlik notu: token'ı dosyaya açık yazmayın (version control'e sızar) —
token için önerilen yol `--set`'tir. `clusterDomain` doldurulmadan kurulum
Route host doğrulamasında hata verir; bu beklenen davranıştır.

### Güncelleme (values değiştiğinde)

Adım adım:

1. Değişikliği yapın — ya values dosyasında ilgili alanı düzenleyin ya da
   `--set` ile verin.
2. `helm upgrade` çalıştırın. Kural: **kurulumda kullandığınız `-f` ve
   `--set` parametrelerinin AYNISINI verin** (helm her seferinde tam değer
   setiyle çalışır; eksik verilen parametre varsayılana geri döner):

```bash
helm upgrade trueguardvision ./charts/trueguardvision -n fraud-poc \
  -f charts/trueguardvision/values-customer.yaml \
  --set clusterDomain=apps.<domain> \
  --set imagePullSecret.token=ghp_**** \
  --set engine.dragonflyPassword='<engine ACL sifresi>'
```

3. Ne olacağını bilin: yalnızca spec'i değişen pod'lar yeniden oluşturulur.
   **FM Engine `Recreate` stratejisiyle güncellenir: önce eski pod
   durdurulur, sonra yenisi kurulur** — arada ~30-60 saniyelik kesinti
   olur. Bu bilinçli bir tercihtir: Engine'in yüksek CPU request'i nedeniyle
   klasik rolling update dar cluster'larda yeni pod'a yer bulamayıp sonsuza
   kadar Pending kalır.
4. Doğrulayın: `oc get pods -n fraud-poc` — tüm pod'lar `1/1 Running`
   olmalı. Sorun varsa geri dönün:

```bash
helm history trueguardvision -n fraud-poc          # revizyon listesi
helm rollback trueguardvision <REVIZYON> -n fraud-poc
```

Aynı imaj tag'iyle yeni yayınlanan imajı çekmek için (values değişikliği
gerektirmez): `oc rollout restart deploy/<ad> -n fraud-poc`

### Kaldırma (silme prosedürü)

Adım adım tam kaldırma:

1. Helm release'ini kaldırın — tüm Deployment/Service/Route'lar silinir:

```bash
helm uninstall trueguardvision -n fraud-poc
```

2. (İsteğe bağlı) Namespace'i tamamen kaldırın:

```bash
oc delete ns fraud-poc
```

Yeniden kurulum, Kurulum bölümündeki `helm install` komutuyla yapılır
(namespace silindiyse `--create-namespace` onu yeniden oluşturur).

Not: Dragonfly cluster dışında çalıştığı için `helm uninstall` işleminden
etkilenmez; veri ve ACL tanımları VM üzerinde korunur. Dragonfly verisi
yeniden üretilebilir niteliktedir (sayaçlar canlı trafikle yeniden dolar);
kalıcı gerçek veri MongoDB ve ClickHouse'tadır.

### Üretilecek manifest'leri önizleme

```bash
helm template trueguardvision ./charts/trueguardvision
```

---

## 4. Veritabanı Kurulumları (MongoDB + ClickHouse)

MongoDB ve ClickHouse, OpenShift dışındaki VM'lere `scripts/` klasöründeki
kurulum script'leriyle kurulur (Ubuntu/Debian ve RHEL ailesi desteklenir).

### Kurulum dosyalarının sunucuya yüklenmesi

`scp`, dosyaları SSH üzerinden uzak sunucuya kopyalar. Repo kökünden
(`<VM_IP>` yerine sunucunun adresini yazın):

```bash
scp scripts/setup-mongodb.sh scripts/setup-clickhouse.sh \
    scripts/clickhouse-01-init.sql scripts/clickhouse-02-views.sql \
    ubuntu@<VM_IP>:
```

### Kurulum

Sunucuya bağlanıp script'leri sırasıyla çalıştırın:

```bash
ssh ubuntu@<VM_IP>
sudo bash setup-mongodb.sh
sudo bash setup-clickhouse.sh '<CLICKHOUSE_SIFRESI>'
```

- `setup-mongodb.sh` — MongoDB 7'yi tek node'lu `rs0` replica set olarak
  kurar (change stream'ler için zorunlu) ve `PRIMARY` durumunu doğrular.
- `setup-clickhouse.sh` — ClickHouse'u kurar, `default` kullanıcısına
  argüman olarak verilen şifreyi atar, şemayı ve analitik view'ları yükler.
  Bu şifre, kurulumda kullanılan `externalDatabases.clickhouse.password`
  değeriyle aynı olmalıdır.

### Açılması gereken portlar

| Bileşen | Port | Protokol | Amaç |
|---|---|---|---|
| MongoDB | 27017 | TCP | Engine + Portal bağlantısı, change stream'ler |
| ClickHouse | 8123 | TCP | HTTP arayüzü — Engine event yazımı, Portal raporlama |
| ClickHouse | 9000 | TCP | Native protokol — `clickhouse client` |
| ClickHouse | 9009 | TCP | Interserver (yalnızca replikalı kurulumda gerekir) |

Portlar yalnızca OpenShift cluster subnet'lerine (ve yönetim erişimi için
gerekli adreslere) açılmalı, kullanıcı ağlarına kapatılmalıdır.

### Client ile doğrulama

```bash
mongosh "mongodb://<VM_IP>:27017/fraudmanagement?replicaSet=rs0&directConnection=true"
clickhouse client --host <VM_IP> --user default --password '<CLICKHOUSE_SIFRESI>'
```

Gerçek değerlerle yazılmış örnek komutlar için ayrıca
[`scripts/kurulum.txt`](scripts/kurulum.txt) dosyasına bakabilirsiniz.

---

## 5. Kullanım

### Erişim adresleri

Kurulum sonrası (varsayılan host şablonu `<ad>.<clusterDomain>`):

| Arayüz | Adres | Not |
|---|---|---|
| FM Portal | `https://fm.<clusterDomain>` | İlk giriş: `auth.adminEmail` / `auth.adminPassword` |
| Event Simulator | `https://sim.<clusterDomain>` | Test arayüzü |
| Simulator Engine API | `https://sim-engine.<clusterDomain>/api/health` | Sağlık kontrolü |

### İlk açılış sırası

1. **FM Portal'a girin** — ilk açılışta `values`'taki admin hesabı otomatik
   oluşturulur; şifreyi arayüzden değiştirin.
2. **Kural tanımlayın** — Portal → Rules (gerekirse Actions, Lists, Buckets).
   Kayıt anında MongoDB change stream'i üzerinden Engine'e yansır; yeniden
   başlatma gerekmez.
3. **Event gönderin** — üretimde banka sistemleri, POC'de Event Simulator.

### Event gönderimi ve kimlik doğrulama

Engine'in `/events` endpoint'i **JWT (Bearer) zorunludur**. Token, Portal
login servisinden alınır:

```bash
curl -sk -X POST https://fm.<clusterDomain>/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"<eposta>","password":"<sifre>"}'
# yanıttaki "token" alanı kullanılır
```

Event Simulator ile test:

1. Simulator arayüzünde yeni test oluşturun.
2. **Target URL**: `http://fraudbuster-be.<namespace>.svc:5432/events`
   (cluster içi servis adresi; trafik cluster dışına çıkmaz).
3. **Bearer token** alanına yukarıdaki JWT'yi tek satır olarak yapıştırın.
4. TPS ve süreyi belirleyip çalıştırın.

### Log takibi

Tüm uygulama pod'larının loglarını tek komutla izlemek için:

```bash
oc logs -f -n fraud-poc --all-containers --prefix \
  -l 'app in (fraudbuster-be,fraudbuster-ui,eventsimulator-engine,eventsimulator-ui)' \
  --max-log-requests=10
```

Tek bir bileşeni izlemek için: `oc logs -f deploy/fraudbuster-be -n fraud-poc`

### Verinin aktığı yerler

| Veri | Nereye yazılır | Nereden izlenir |
|---|---|---|
| Event (ham + skorlama metrikleri) | ClickHouse (`events` tablosu, async batch) | Portal → Events / Analytics / Dashboard |
| Incident (kural tetiklenmesi) | MongoDB | Portal → Incidents |
| Sayaçlar / aktör profilleri | Dragonfly (TTL'li) | Portal → Buckets (inceleme) |
| Kural/aksiyon/liste/kullanıcı tanımları | MongoDB | Portal ilgili menüler |

---

## 6. Kapsam (OpenShift içi ve dışı)

**OpenShift içinde (bu chart kurar):** FM Engine, FM Portal, Event Simulator
(engine + UI), servis/Route tanımları, uygulama secret'ları.

**OpenShift dışında (bu chart kurmaz, yalnızca adres olarak referans verir):**

| Bileşen | Referans verilen yer | Gereksinim |
|---|---|---|
| Dragonfly | `engine.dragonfly*` alanları | ACL tanımlı olmalı, `engine` kullanıcısının şifresi `--set` ile verilmeli; 6379/TCP cluster node'larına açık (kurulum: [`dragonfly-setup/`](../../dragonfly-setup/dragonfly-setup-guideline-for-audit.md)) |
| MongoDB | `externalDatabases.mongodb.uri` | Replica set `rs0` zorunlu (change stream'ler için), URI'de `replicaSet=rs0&directConnection=true` korunmalı; 27017/TCP cluster node'larına açık |
| ClickHouse | `externalDatabases.clickhouse.*` | `events` şeması kurulmuş olmalı (kurulum script'leri ürün paketiyle verilir); 8123/TCP cluster node'larına açık |
| İmaj registry'si | `imagePullSecret.*` ve `*.image` alanları | ghcr.io'ya çıkış ya da imajların banka registry'sine mirror'ı |

---

## 7. Values Referansı

| Anahtar | Varsayılan | Açıklama |
|---|---|---|
| `clusterDomain` | örnek değer | Cluster'ın uygulama (Route) domain'i; host'lar `fm.`, `sim.`, `sim-engine.` önekleriyle türetilir |
| `routes.enabled` | `true` | Route'ların oluşturulması |
| `routes.fmHost` / `simHost` / `simEngineHost` | boş | Dolu verilirse türetme yerine bu host'lar kullanılır |
| `imagePullSecret.create` | `true` | Pull secret'ı chart oluştursun mu (false ise aynı adla önceden oluşturulmalı) |
| `imagePullSecret.name` | `ghcr-pull` | Secret adı |
| `imagePullSecret.registry/username/token` | — | Registry kimlik bilgileri; **token values dosyasına yazılmamalı**, `--set` ile verilmelidir |
| `auth.jwtSecret` | örnek değer | Engine ve Portal'ın paylaştığı JWT imza anahtarı — üretimde `openssl rand -base64 48` ile üretin |
| `auth.adminEmail` / `adminPassword` | örnek değer | İlk açılışta oluşturulan admin hesabı |
| `externalDatabases.mongodb.uri` | örnek değer | MongoDB bağlantı URI'si (rs0 + directConnection parametreleriyle) |
| `externalDatabases.mongodb.database` | `fraudmanagement` | Veritabanı adı |
| `externalDatabases.clickhouse.url` | örnek değer | ClickHouse HTTP adresi (`http://<ip>:8123`) |
| `externalDatabases.clickhouse.database/user/password` | `fraudbuster` / `default` / örnek | ClickHouse erişim bilgileri |
| `engine.dragonflyHost` | `dragonfly` | Dragonfly VM'inin IP adresi ya da hostname'i |
| `engine.dragonflyPort` | `6379` | Dragonfly portu |
| `engine.dragonflyUser` | boş | Bağlanılacak ACL kullanıcısı (`engine`). Boş bırakılırsa URI'ye kimlik bilgisi eklenmez |
| `engine.dragonflyPassword` | boş | ACL şifresi — **values dosyasına yazılmamalı**, `--set` ile verilmelidir. Secret içinde saklanır, URI'ye encode edilerek eklenir |
| `engine.dragonflyParams` | `pool_size=300&min_idle=50&...` | Bağlantı havuzu ve timeout parametreleri |
| `engine.image` | `fraudengine:main` | Engine imajı — üretimde sürüm/sha tag'ine pinleyin |
| `engine.logLevel` / `rustLog` | `info` | Log seviyesi (yük testinde `warn` önerilir) |
| `engine.bucketTtlSeconds` | `86400` | Sayaç TTL'i |
| `engine.resources` / `ui.resources` / `simulator.*.resources` | POC değerleri | CPU/RAM istek ve limitleri — hedef TPS'e göre ölçeklendirin |
| `ui.enablePocReset` | `true` | Portal'daki veri sıfırlama araçları — **üretimde `false` yapılmalıdır** |
| `simulator.engine.fraudEnginePlacement` | `separate` | Yük üretecinin FM Engine'e göre yerleşimi: `colocate` / `separate` / `none`; ölçüm sağlığı için `separate` önerilir |
| `engine.tuning.*` | compose fallback'leri | **Tuning map**: her satır Engine container'ına environment variable olarak basılır; compose'daki tüm `FRAUDBUSTER_*` performans/bayrak env'leri burada (thread pool, pipeline/kuyruk limitleri, `DISABLE_*` bayrakları, batch boyutları...). Yeni env eklemek chart değişikliği gerektirmez. Bağlantı/kimlik env'leri burada tanımlanamaz — template reddeder |
| `ui.tuning.*` | compose fallback'leri | UI tuning map'i: `INCIDENTS_FILTER_*` guardrail'leri ve `CLICKHOUSE_MAX_CONNECTIONS` |

Tuning env'lerinin tam listesi ve ortam başına değerleri için `values.yaml`
(taban) ve `values-customer.yaml` dosyalarına bakınız;
anlam açıklamaları ürün paketindeki `env.template` içinde yorum satırı olarak
mevcuttur.

---

## 8. Güvenlik ve Ağ

### TLS

- Tüm dış erişim OpenShift Route'ları üzerinden **edge TLS** ile şifrelidir;
  HTTP istekleri HTTPS'e yönlendirilir (`insecureEdgeTerminationPolicy: Redirect`).
- Varsayılan durumda router'ın wildcard sertifikası kullanılır. Bankaya özel
  host adı kullanılacaksa Route'lara kurum sertifikası tanımlanmalıdır
  (`spec.tls.certificate/key`); istenirse chart bu alanlarla genişletilebilir.
- Cluster içi trafik (Portal→Engine) pod ağında kalır ve cluster dışına
  çıkmaz. Engine→Dragonfly trafiği banka iç ağında kalır; erişim ACL kimlik
  doğrulaması ve ağ kısıtlarıyla denetlenir (bkz. Bölüm 9).
- Not: Compose kurulumundaki nginx `client_max_body_size 10m` sınırının Route
  karşılığı yoktur (OpenShift router gövde boyutu sınırı uygulamaz); istek
  boyutu sınırlaması gerekiyorsa Route annotation'ları ile eklenebilir.

### Secret Yönetimi

- JWT anahtarı, ClickHouse şifresi, Dragonfly bağlantı URI'si (ACL şifresi
  dahil) ve admin bilgileri Kubernetes Secret'ında tutulur; ortam değişkeni
  olarak pod'lara verilir.
- Doldurulmuş `values-customer.yaml` secret içerdiğinden dosya erişimi
  kısıtlanmalı; tercihen secret'lar `--set` ile ya da harici bir secret yönetimi (Vault,
  Sealed Secrets vb.) ile sağlanmalıdır.
- Registry token'ı yalnızca image çekme (`read:packages`) yetkisine sahip
  olmalıdır.

### Ağ gereksinimleri

| Kaynak | Hedef | Port | Amaç |
|---|---|---|---|
| Analist / operatör | OpenShift Router | 443/TCP | Portal ve Simulator arayüzleri |
| Cluster worker node'ları | **Dragonfly VM** | **6379/TCP** | **Sayaç okuma/yazma (skorlamanın sıcak yolu)** |
| Cluster worker node'ları | MongoDB VM | 27017/TCP | Yapılandırma + incident + change stream |
| Cluster worker node'ları | ClickHouse VM | 8123/TCP | Event arşivi ve raporlama |
| Cluster (egress) | İmaj registry'si | 443/TCP | İmaj çekme (mirror kullanılıyorsa banka registry'si) |

- Dragonfly/MongoDB/ClickHouse portları yalnızca cluster node subnet'lerine
  açılmalı, kullanıcı ağlarına kapatılmalıdır.
- Pod ve Service CIDR'larının (cluster kurulumunda belirlenir) banka ağıyla
  çakışmaması kurulum sahibinin sorumluluğundadır.
- Namespace içi/dışı trafiği sınırlamak için NetworkPolicy eklenebilir
  (bkz. Bölüm 7).

### SCC uyumu

Tüm iş yükleri OpenShift'in varsayılan `restricted-v2` SCC'si ile çalışır;
özel yetki (privileged container, ek capability, seccomp istisnası)
**gerektirmez**.

---

## 9. Audit

Platformun kullandığı veri katmanlarında, uygulama dışından yapılan
erişimlerin kayıt altına alınması için audit yapılandırmaları uygulanır.

### 9.1 Dragonfly Audit

Dragonfly, cluster dışında adanmış bir VM'de standalone olarak çalışır ve
üzerinde erişim denetimi ile oturum kayıt mekanizması yapılandırılmıştır.
Amaç, FM Engine dışında bir kullanıcının Dragonfly'a bağlanarak yaptığı tüm
işlemlerin kayıt altına alınmasıdır.

**Kimlik ayrımı (ACL).** Dragonfly üzerinde her erişim türü için ayrı bir ACL
kullanıcısı tanımlanmıştır: uygulama için `engine`, yönetici erişimi için
adlandırılmış hesaplar ve sınırlı operasyonel erişim için yetkileri
daraltılmış bir hesap. Kimlik doğrulamasız erişimi sağlayan varsayılan hesap
kapatılmıştır; şifresiz bağlantı kabul edilmez. Tanımlar sunucuda kalıcı
olarak saklanır ve servis yeniden başlatıldığında korunur.

**Oturum kaydı.** Yönetici erişimi, `dragonfly-audit-cli` wrapper'ı üzerinden
yapılır. Wrapper her oturum için ayrı bir kayıt dosyası üretir ve şu bilgileri
tutar:

| Alan | İçerik |
|---|---|
| `os_user` | İşlemi yapan Linux kullanıcısı |
| `dragonfly_user` | Kullanılan Dragonfly ACL hesabı |
| `source_ip` | Bağlantının geldiği IP adresi |
| `tty` | Terminal oturumu |
| `started_at` / `ended_at` | Oturum başlangıç ve bitiş zamanı (ISO 8601) |
| Oturum içeriği | Girilen tüm komutlar ve Dragonfly'ın döndürdüğü cevaplar |

Kayıtlar `/var/log/dragonfly-audit/` dizininde tutulur. Dizin ve dosyalar
yalnızca `root` erişimine açıktır ve oluşturuldukları anda append-only olarak
işaretlenir. Her oturum, zamanlama verisiyle birlikte saklandığı için
`scriptreplay` ile orijinal hızında yeniden izlenebilir.

**Erişim yolunun tekilleştirilmesi.** Sunucu üzerinde çalışan kullanıcıların
wrapper'ı atlayarak doğrudan `redis-cli` ile bağlanması, iptables `owner`
eşleşmesiyle engellenir; yalnızca `root` ve engine servis hesabı için izin
verilir. Kullanıcıların `sudo` yetkisi tek bir komutla — audit wrapper'ıyla —
sınırlandırılmıştır. 6379/TCP portu ağ düzeyinde yalnızca cluster
node'larına açılır.

**Uygulama trafiği.** FM Engine, `engine` ACL kullanıcısıyla doğrudan bağlanır
ve audit kaydı üretmez. Kayıt mekanizması terminal düzeyinde çalıştığı için
Dragonfly üzerinde performans maliyeti oluşturmaz.

**Merkezi log entegrasyonu.** Audit kayıtları, `rsyslog` veya kurumun tercih
ettiği log toplama ajanı ile merkezi log sistemine (SIEM) aktarılabilir.
Yapılandırma örnekleri kurulum dokümanında yer alır.

**Kurulum ve işletim dokümanı:**
[`dragonfly-setup/dragonfly-setup-guideline-for-audit.md`](../../dragonfly-setup/dragonfly-setup-guideline-for-audit.md)

| Dosya | Açıklama |
|---|---|
| [`dragonfly-setup/dragonfly-setup-guideline-for-audit.md`](../../dragonfly-setup/dragonfly-setup-guideline-for-audit.md) | Dragonfly kurulumu, ACL yapılandırması, audit kurulumu, doğrulama testleri ve periyodik kontroller |
| [`dragonfly-setup/dragonfly-audit-cli.sh`](../../dragonfly-setup/dragonfly-audit-cli.sh) | Audit wrapper script'i |
| [`dragonfly-setup/setup-dragonfly-firewall`](../../dragonfly-setup/setup-dragonfly-firewall) | Firewall kurallarını uygulayan script |

---
