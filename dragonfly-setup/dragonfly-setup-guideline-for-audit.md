# Dragonfly Standalone Kurulumu ve Audit Yapılandırması

Bu doküman, TrueGuardVision fraud platformunun kullandığı Dragonfly veri
deposunun cluster dışı bir sunucuya kurulumunu ve erişim denetimi (access
control) ile oturum kayıt (session audit) yapılandırmasını anlatır.

Amaç, FM Engine dışında bir kullanıcının Dragonfly'a bağlanarak yaptığı tüm
işlemlerin kayıt altına alınmasıdır. FM Engine'in kendi trafiği kapsam
dışındadır ve audit kaydı üretmez.

---

## İçindekiler

1. [Mimari](#1-mimari)
2. [Sunucu Gereksinimleri](#2-sunucu-gereksinimleri)
3. [Dragonfly Kurulumu](#3-dragonfly-kurulumu)
4. [ACL Yapılandırması](#4-acl-yapılandırması)
5. [Audit Log Dizini](#5-audit-log-dizini)
6. [Audit Wrapper](#6-audit-wrapper)
7. [sudo Yetkilendirmesi](#7-sudo-yetkilendirmesi)
8. [Engine için Sistem Kullanıcısı](#8-engine-için-sistem-kullanıcısı)
9. [Firewall Yapılandırması](#9-firewall-yapılandırması)
10. [Doğrulama Testleri](#10-doğrulama-testleri)
11. [Audit Kayıtlarının İncelenmesi](#11-audit-kayıtlarının-i̇ncelenmesi)
12. [Log Formatı ve SIEM Entegrasyonu](#12-log-formatı-ve-siem-entegrasyonu)
13. [Periyodik Kontroller](#13-periyodik-kontroller)

---

## 1. Mimari

Dragonfly, Kubernetes/OpenShift cluster'ının dışında adanmış bir sunucuda
standalone olarak çalışır. Erişim iki ayrı yoldan sağlanır:

**FM Engine erişimi** — uygulama, `engine` ACL kullanıcısıyla doğrudan
bağlanır:

```
FM Engine (cluster) ──► engine ACL user ──► Dragonfly
```

**Kullanıcı erişimi** — yöneticiler sunucuya SSH ile bağlanır ve audit
wrapper üzerinden Dragonfly'a erişir. Oturumun tamamı kayıt altına alınır:

```
Kullanıcı ──► SSH ──► sudo dragonfly-audit-cli ──► script ──► redis-cli ──► Dragonfly
                                    │
                                    ▼
                      /var/log/dragonfly-audit/<oturum>.log
```

Sunucu üzerinden doğrudan `redis-cli` çalıştırma girişimleri firewall
tarafından engellenir; yalnızca `root` ve engine servis hesabı için izin
verilir.

---

## 2. Sunucu Gereksinimleri

Doğrulanmış referans yapılandırma:

| Özellik | Değer |
|---|---|
| Instance tipi | c6i.2xlarge (veya muadili) |
| vCPU | 8 |
| RAM | 16 GB |
| Disk | 100 GB |
| İşletim sistemi | Ubuntu 24.04 LTS |
| Port | 6379/TCP |

Dragonfly bellek yoğun çalışır. `maxmemory` değeri toplam RAM'in yaklaşık
%70'i olacak şekilde belirlenmelidir (16 GB RAM için 10 GB).

### Hostname yapılandırması

```bash
sudo hostnamectl set-hostname dragonfly-st
echo "<PRIVATE_IP> dragonfly-st" | sudo tee -a /etc/hosts
sudo sed -i 's/^preserve_hostname:.*/preserve_hostname: true/' /etc/cloud/cloud.cfg
```

---

## 3. Dragonfly Kurulumu

### Paket kurulumu

```bash
sudo apt update
sudo apt install -y redis-tools

curl -sL https://github.com/dragonflydb/dragonfly/releases/download/v1.40.1/dragonfly_amd64.deb \
  -o /tmp/dragonfly.deb
sudo apt install -y /tmp/dragonfly.deb
```

Sürüm pinlidir. Chart'ta kullanılan sürümle aynı olmalıdır.

Doğrulama:

```bash
dragonfly --version
```

```
dragonfly v1.40.1-434478e00c366c711985d0b3269023fc39db8ad1
build time: 2026-08-06 05:08:56
```

Paket, `dfly` sistem kullanıcısını, `/usr/bin/dragonfly` binary'sini,
`dragonfly.service` systemd unit'ini ve `/etc/dragonfly/dragonfly.conf`
yapılandırma dosyasını kurar.

### Yapılandırma

Sistem kaynaklarını doğrulayın:

```bash
free -g
nproc
```

`/etc/dragonfly/dragonfly.conf` dosyasını aşağıdaki içerikle oluşturun:

```
--pidfile=/var/run/dragonfly/dragonfly.pid
--log_dir=/var/log/dragonfly
--dir=/var/lib/dragonfly
--bind=0.0.0.0
--max_log_size=20
--version_check=true
--alsologtostderr
--proactor_threads=7
--maxmemory=10gb
--dbfilename=dump
--hz=50
--aclfile=/var/lib/dragonfly/dragonfly.acl
```

| Parametre | Açıklama |
|---|---|
| `--proactor_threads` | Çalışan thread sayısı. 8 vCPU'lu sunucuda 7 — bir çekirdek işletim sistemi ve audit süreçlerine bırakılır. Engine, shard sayısını bağlantı sırasında `INFO thread_count` ile otomatik öğrenir |
| `--maxmemory` | Bellek üst sınırı |
| `--aclfile` | ACL tanımlarının kalıcı olarak saklandığı dosya |
| `--dir` / `--dbfilename` | Snapshot dizini ve dosya adı |
| `--hz` | Arka plan görev frekansı |

ACL dosyasını, servis kullanıcısının yazabileceği izinlerle oluşturun:

```bash
sudo install -o dfly -g dfly -m 600 /dev/null /var/lib/dragonfly/dragonfly.acl
```

### Servisi başlatma

```bash
sudo systemctl enable --now dragonfly
systemctl status dragonfly --no-pager
```

Doğrulama:

```bash
redis-cli -h 127.0.0.1 -p 6379 INFO server | head -20
```

```
# Server
redis_version:7.4.0
dragonfly_version:df-v1.40.1
redis_mode:standalone
thread_count:7
multiplexing_api:iouring
tcp_port:6379
hz:50
executable:/usr/bin/dragonfly
config_file:/etc/dragonfly/dragonfly.conf
```

`thread_count` ve `hz` değerleri yapılandırmayla örtüşmelidir.

---

## 4. ACL Yapılandırması

Dragonfly'ın ACL mekanizması, her kullanıcı için ayrı kimlik bilgisi ve komut
yetkisi tanımlanmasını sağlar.

### Şifre üretimi

Her kullanıcı için ayrı şifre üretin:

```bash
openssl rand -base64 24
```

Şifreleri kurumsal parola yönetim sisteminde saklayın.

### Kullanıcıların tanımlanması

Kurulum sonrası tek kullanıcı bulunur: şifresiz ve tam yetkili `default`.
Aşağıdaki komutlar kullanıcıları oluşturur ve `default` hesabını kapatır:

```bash
redis-cli -h 127.0.0.1 -p 6379 ACL SETUSER engine ON '><ENGINE_SIFRE>' '~*' '&*' '+@all'
redis-cli -h 127.0.0.1 -p 6379 ACL SETUSER admin_user ON '><ADMIN_SIFRE>' '~*' '&*' '+@all'
redis-cli -h 127.0.0.1 -p 6379 ACL SETUSER test_user ON '><TEST_SIFRE>' '~*' '&*' '+@read' '+@write' '+@connection' '-@admin' '-@dangerous'
redis-cli -h 127.0.0.1 -p 6379 ACL SETUSER default OFF
```

> Şifre içeren komutları, satır başına bir boşluk koyarak çalıştırın; bu
> durumda komut shell geçmişine yazılmaz.

| Kullanıcı | Kullanım amacı | Yetki |
|---|---|---|
| `engine` | FM Engine uygulaması | Tam yetki |
| `admin_user` | Yönetici erişimi | Tam yetki |
| `test_user` | Sınırlı operasyonel erişim | Okuma ve yazma; administrative ve dangerous komutlar hariç |
| `default` | — | Kapalı; kimlik doğrulamasız erişim mümkün değildir |

ACL sözdizimi:

| İfade | Anlamı |
|---|---|
| `ON` / `OFF` | Kullanıcının aktiflik durumu |
| `>sifre` | Şifre tanımı |
| `~*` | Tüm key'lere erişim |
| `&*` | Tüm pub/sub kanallarına erişim |
| `+@all` | Tüm komutlar |
| `-@admin` | Administrative komutların çıkarılması (`CONFIG`, `REPLICAOF`, `SHUTDOWN`, `ACL`) |
| `-@dangerous` | Yıkıcı komutların çıkarılması (`FLUSHALL`, `FLUSHDB`, `KEYS`, `DEBUG`) |

### Tanımların kalıcı hale getirilmesi

```bash
 redis-cli -h 127.0.0.1 -p 6379 --user admin_user --pass '<ADMIN_SIFRE>' \
   --no-auth-warning ACL SAVE
```

Doğrulama:

```bash
sudo cat /var/lib/dragonfly/dragonfly.acl
```

```
USER admin_user ON #2981e5a33e6ae520ad5135aba92d5bd78ba26a614c1b73e4a2f24afce64d1ce5 ~* &* +@all $all
USER default OFF nopass ~* &* +@all $all
USER engine ON #b3ee01b21e0bcce11c5de2620a4d72fb57963338d7bbe8a11c5e0b01a922852d ~* &* +@all $all
USER test_user ON #f0c0cb2f9a59e89fbb3bf6604200879013133f7aca6548930ca1dc994b03e988 ~* &* -@all +@read +@write +@connection -@admin -@dangerous $all
```

Şifreler SHA-256 özet değeri olarak saklanır; açık şifre dosyada yer almaz.

Kimlik doğrulamasız erişimin kapandığını doğrulayın:

```bash
redis-cli -h 127.0.0.1 -p 6379 PING
```

```
(error) NOAUTH Authentication required.
```

---

## 5. Audit Log Dizini

Oturum kayıtlarının tutulacağı dizin yalnızca `root` erişimine açıktır:

```bash
sudo mkdir -p /var/log/dragonfly-audit
sudo chown root:root /var/log/dragonfly-audit
sudo chmod 700 /var/log/dragonfly-audit
```

```
drwx------  2 root root  4096 Sep  2 16:20 /var/log/dragonfly-audit
```

Bu izin seviyesi, erişimi kayıt altına alınan kullanıcıların kendi
kayıtlarını okumasını veya değiştirmesini engeller.

---

## 6. Audit Wrapper

`dragonfly-audit-cli` script'i, kullanıcı ile `redis-cli` arasına girerek
oturumun tamamını kayıt altına alır. Kayıt işlemi terminal düzeyinde
yapıldığından Dragonfly üzerinde herhangi bir performans maliyeti oluşturmaz.

Script'i sunucuya kopyalayın:

```bash
sudo install -o root -g root -m 750 dragonfly-audit-cli.sh \
  /usr/local/sbin/dragonfly-audit-cli
```

### Script'in işleyişi

| Aşama | İşlem |
|---|---|
| Kimlik tespiti | `SUDO_USER` üzerinden komutu çalıştıran gerçek Linux kullanıcısı belirlenir; doğrudan `root` ile çalıştırma reddedilir |
| Kaynak adres | `SSH_CONNECTION` değişkeninden bağlantının geldiği IP adresi alınır |
| Kimlik bilgisi | Dragonfly kullanıcı adı ve şifresi kullanıcıdan istenir; şifre ekranda gösterilmez ve kayıt başlamadan önce okunur |
| Engine hesabı koruması | `engine`, `fraudengine`, `fraudbuster_engine` hesaplarıyla manuel giriş reddedilir |
| Şifre aktarımı | Şifre `REDISCLI_AUTH` environment variable ile aktarılır; komut satırında yer almadığı için süreç listesinde görünmez |
| Oturum kaydı | `/usr/bin/script` ile girilen komutlar ve dönen cevaplar dosyaya yazılır |
| Kapanış | Bitiş zamanı ve çıkış kodu eklenir, dosya `root` sahipliğine alınır ve append-only olarak işaretlenir |

### Üretilen dosyalar

Her oturum için iki dosya oluşturulur:

```
/var/log/dragonfly-audit/20260902T165340Z_anil_4688.log
/var/log/dragonfly-audit/20260902T165340Z_anil_4688.timing
```

Dosya adı UTC zaman damgası, Linux kullanıcı adı ve process ID'sinden oluşur.
`.timing` dosyası, oturumun orijinal hızıyla yeniden oynatılmasını sağlar.

---

## 7. sudo Yetkilendirmesi

Yetkili kullanıcılar wrapper'ı `sudo` ile çalıştırır. Yetki yalnızca bu
komutla sınırlandırılır:

```bash
sudo visudo -f /etc/sudoers.d/dragonfly-audit
```

İçerik:

```
Cmnd_Alias DRAGONFLY_AUDIT = /usr/local/sbin/dragonfly-audit-cli

Defaults!DRAGONFLY_AUDIT env_keep += "SSH_CONNECTION SSH_CLIENT"

<kullanici1> ALL=(root) DRAGONFLY_AUDIT
<kullanici2> ALL=(root) DRAGONFLY_AUDIT
```

`env_keep` tanımı, yalnızca bu komut için bağlantı adresi bilgisinin
korunmasını sağlar; genel `sudo` davranışını değiştirmez.

Dosya izinleri ve doğrulama:

```bash
sudo chown root:root /etc/sudoers.d/dragonfly-audit
sudo chmod 440 /etc/sudoers.d/dragonfly-audit
sudo visudo -cf /etc/sudoers.d/dragonfly-audit
```

```
/etc/sudoers.d/dragonfly-audit: parsed OK
```

> `visudo`, sudoers dosyalarını sözdizimi doğrulamasıyla düzenler ve hatalı
> içeriğin kaydedilmesini önler.

---

## 8. Engine için Sistem Kullanıcısı

FM Engine trafiğinin firewall kurallarında ayırt edilebilmesi için adanmış
bir sistem hesabı oluşturulur:

```bash
sudo adduser --system --group fraudengine
```

Engine süreci bu hesapla çalıştırılmalıdır. Cluster üzerinden bağlanan
Engine için bu adım, sunucu üzerinde yerel doğrulama testleri yapılabilmesini
sağlar.

---

## 9. Firewall Yapılandırması

Sunucu üzerinde çalışan kullanıcıların wrapper'ı atlayarak doğrudan
`redis-cli` ile bağlanması, iptables `owner` eşleşmesiyle engellenir.

Mevcut kuralları yedekleyin:

```bash
sudo iptables-save | sudo tee /root/iptables-backup-$(date +%Y%m%d-%H%M%S).rules > /dev/null
```

Script'i kopyalayıp çalıştırın:

```bash
sudo install -o root -g root -m 700 setup-dragonfly-firewall \
  /usr/local/sbin/setup-dragonfly-firewall
sudo /usr/local/sbin/setup-dragonfly-firewall
```

Uygulanan kurallar:

| Sıra | Kaynak | Sonuç |
|---|---|---|
| 1 | `root` | İzin verilir |
| 2 | `fraudengine` | İzin verilir |
| 3 | Diğer tüm yerel kullanıcılar | Reddedilir (`tcp-reset`) |

Kuralları kalıcı hale getirin:

```bash
sudo apt install -y iptables-persistent
sudo netfilter-persistent save
```

Doğrulama:

```bash
sudo grep -n 6379 /etc/iptables/rules.v4
```

```
6:-A OUTPUT -d 127.0.0.1/32 -o lo -p tcp -m tcp --dport 6379 -m owner --uid-owner 0 -j ACCEPT
7:-A OUTPUT -d 127.0.0.1/32 -o lo -p tcp -m tcp --dport 6379 -m owner --uid-owner 113 -j ACCEPT
8:-A OUTPUT -d 127.0.0.1/32 -o lo -p tcp -m tcp --dport 6379 -j REJECT --reject-with tcp-reset
```

### Ağ düzeyinde erişim kısıtı

6379/TCP portu yalnızca FM Engine'in çalıştığı cluster node'larına
açılmalıdır. Bulut ortamında bu kısıt security group ile uygulanır; kaynak
olarak IP adresi yerine cluster node'larının security group referansı
kullanılması, node değişikliklerinde kuralın geçerliliğini korur.

Bağlantıların kayıt altına alınması için `INPUT` zincirine aşağıdaki kural
eklenebilir:

```bash
sudo iptables -I INPUT -p tcp --dport 6379 -m conntrack --ctstate NEW \
  -j LOG --log-prefix "DFLY-CONN "
```

Kural yalnızca yeni bağlantı kurulumunu kaydeder; veri paketleri
değerlendirilmez. Uygulama tarafında connection pool kullanıldığından üretilen
kayıt sayısı düşüktür.

---

## 10. Doğrulama Testleri

### Engine erişimi

```bash
sudo -u fraudengine -H env REDISCLI_AUTH='<ENGINE_SIFRE>' \
  redis-cli -h 127.0.0.1 -p 6379 --user engine --no-auth-warning PING
```

```
PONG
```

### Doğrudan erişimin engellenmesi

```bash
sudo -u <kullanici> -H redis-cli -h 127.0.0.1 -p 6379 \
  --user admin_user --no-auth-warning PING
```

```
Could not connect to Redis at 127.0.0.1:6379: Connection refused
```

Doğru şifre girilse dahi bağlantı firewall tarafından reddedilir.

### Wrapper üzerinden erişim

```bash
sudo /usr/local/sbin/dragonfly-audit-cli
```

```
Dragonfly username: admin_user
Dragonfly password:
127.0.0.1:6379> ACL WHOAMI
"User is admin_user"
127.0.0.1:6379> SET audit:test 123
OK
127.0.0.1:6379> GET audit:test
"123"
127.0.0.1:6379> DEL audit:test
(integer) 1
127.0.0.1:6379> EXIT
```

### Engine işlemlerinin audit kapsamı dışında olması

```bash
sudo bash -c 'find /var/log/dragonfly-audit -maxdepth 1 -name "*.log" | wc -l'
# 3

sudo -u fraudengine -H env REDISCLI_AUTH='<ENGINE_SIFRE>' \
  redis-cli -h 127.0.0.1 -p 6379 --user engine --no-auth-warning SET engine:test 123
# OK

sudo bash -c 'find /var/log/dragonfly-audit -maxdepth 1 -name "*.log" | wc -l'
# 3
```

Kayıt sayısı değişmez; uygulama trafiği audit kaydı üretmez.

### sudo yetkilerinin doğrulanması

```bash
sudo -l -U <kullanici>
```

```
User <kullanici> may run the following commands on dragonfly-st:
    (root) /usr/local/sbin/dragonfly-audit-cli
```

---

## 11. Audit Kayıtlarının İncelenmesi

### Kayıtların listelenmesi

```bash
sudo ls -lah /var/log/dragonfly-audit
```

### Son oturumun görüntülenmesi

```bash
sudo bash -c 'cat "$(ls -1t /var/log/dragonfly-audit/*.log | head -n 1)"'
```

```
===== DRAGONFLY AUDIT SESSION =====
session_id=20260902T165340Z_anil_4688
os_user=anil
dragonfly_user=admin_user
source_ip=10.20.30.40
tty=/dev/pts/2
started_at=2026-09-02T16:53:40+00:00
===================================
127.0.0.1:6379> ACL WHOAMI
"User is admin_user"
127.0.0.1:6379> SET audit:test 123
OK
127.0.0.1:6379> GET audit:test
"123"
127.0.0.1:6379> DEL audit:test
(integer) 1
127.0.0.1:6379> EXIT

ended_at=2026-09-02T16:54:06+00:00
exit_code=0
===== SESSION FINISHED =====
```

### Oturumun yeniden oynatılması

```bash
sudo bash -c 'L="$(ls -1t /var/log/dragonfly-audit/*.log | head -n 1)"; \
  scriptreplay --timing="${L%.log}.timing" "$L"'
```

`scriptreplay` kaydı orijinal hızıyla ekrana yansıtır; herhangi bir komut
çalıştırmaz.

### Append-only durumunun doğrulanması

```bash
sudo lsattr /var/log/dragonfly-audit/
```

```
-----a--------e------- /var/log/dragonfly-audit/20260902T165340Z_anil_4688.log
-----a--------e------- /var/log/dragonfly-audit/20260902T165340Z_anil_4688.timing
```

`a` bayrağı, dosyaya yalnızca ekleme yapılabileceğini; mevcut içeriğin
değiştirilemeyeceğini gösterir.

---

## 12. Log Formatı ve SIEM Entegrasyonu

### Kayıt yapısı

Her oturum dosyası, yapılandırılmış bir başlık bloğu ve ardından terminal
oturumunun tamamını içerir.

| Alan | Açıklama |
|---|---|
| `session_id` | Oturum kimliği (zaman damgası + kullanıcı + PID) |
| `os_user` | İşlemi yapan Linux kullanıcısı |
| `dragonfly_user` | Kullanılan Dragonfly ACL hesabı |
| `source_ip` | Bağlantının geldiği IP adresi |
| `tty` | Terminal oturumu |
| `started_at` / `ended_at` | Oturum başlangıç ve bitiş zamanı (ISO 8601) |
| `exit_code` | Oturumun çıkış kodu |

Başlıktan sonraki bölümde, kullanıcının girdiği tüm komutlar ve Dragonfly'ın
döndürdüğü cevaplar yer alır.

### Merkezi log sistemine aktarım

Kayıtların kurumsal SIEM veya merkezi log sunucusuna aktarılması için
`rsyslog` kullanılabilir. `/etc/rsyslog.d/50-dragonfly-audit.conf`:

```
module(load="imfile" mode="inotify")

input(type="imfile"
      File="/var/log/dragonfly-audit/*.log"
      Tag="dragonfly-audit"
      Severity="info"
      Facility="local5"
      PersistStateInterval="1")

local5.* @@<SIEM_ADRESI>:514
local5.* stop
```

```bash
sudo systemctl restart rsyslog
```

| Ayar | Açıklama |
|---|---|
| `mode="inotify"` | Yeni oluşturulan oturum dosyalarını anında algılar |
| `PersistStateInterval` | Servis yeniden başlatıldığında kaldığı yerden devam eder |
| `@@` | TCP ile iletim (güvenilir teslim) |

Kurumun tercih ettiği log toplama ajanı (Filebeat, Fluent Bit, Splunk
Universal Forwarder vb.) da aynı dizini kaynak olarak kullanabilir.

### Dosya bütünlüğünün izlenmesi

`auditd` ile audit dosyalarına ve yapılandırmaya yapılan erişimler
izlenebilir. `/etc/audit/rules.d/dragonfly-audit.rules`:

```
-w /var/log/dragonfly-audit/ -p wa -k dfly_audit
-w /usr/local/sbin/dragonfly-audit-cli -p wa -k dfly_wrapper
-w /etc/sudoers.d/dragonfly-audit -p wa -k dfly_sudoers
-w /var/lib/dragonfly/dragonfly.acl -p wa -k dfly_acl
-w /etc/dragonfly/dragonfly.conf -p wa -k dfly_conf
```

```bash
sudo augenrules --load
sudo ausearch -k dfly_audit -i
```

---

## 13. Periyodik Kontroller

| Kontrol | Komut | Beklenen |
|---|---|---|
| Servis durumu | `sudo ss -lntp \| grep 6379` | Dragonfly 6379 portunu dinliyor |
| ACL tanımları | `sudo redis-cli --user admin_user --pass '<SIFRE>' --no-auth-warning ACL LIST` | Tanımlı kullanıcılar mevcut, `default` kapalı |
| Firewall kuralları | `sudo iptables -L OUTPUT -n -v --line-numbers \| grep 6379` | Üç kural aktif |
| Disk kullanımı | `sudo du -sh /var/log/dragonfly-audit` | Beklenen aralıkta |

Firewall kural listesindeki paket sayaçları, engellenen erişim
girişimlerinin sayısını gösterir:

```
1      935 49067 ACCEPT  ... owner UID match 0
2       18  1229 ACCEPT  ... owner UID match 113
3       66  2832 REJECT  ... reject-with tcp-reset
```

---

## Ek: Dosyalar

| Dosya | Açıklama |
|---|---|
| `dragonfly-audit-cli.sh` | Audit wrapper script'i — `/usr/local/sbin/dragonfly-audit-cli` olarak kurulur |
| `setup-dragonfly-firewall` | Firewall kurallarını uygulayan script — `/usr/local/sbin/setup-dragonfly-firewall` olarak kurulur |
