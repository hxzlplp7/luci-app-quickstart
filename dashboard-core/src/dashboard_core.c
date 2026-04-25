#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define DEFAULT_LISTEN_HOST "127.0.0.1"
#define DEFAULT_LISTEN_PORT 19090
#define MAX_TEXT 256
#define MAX_DEVICES 96

struct buffer {
    char *data;
    size_t len;
    size_t cap;
};

struct traffic_state {
    char iface[64];
    unsigned long long tx;
    unsigned long long rx;
    time_t ts;
};

struct device {
    char ip[64];
    char mac[64];
    char name[128];
    bool active;
};

static struct traffic_state g_traffic;

static void buf_init(struct buffer *b)
{
    b->cap = 8192;
    b->len = 0;
    b->data = calloc(1, b->cap);
}

static void buf_free(struct buffer *b)
{
    free(b->data);
    b->data = NULL;
    b->len = 0;
    b->cap = 0;
}

static void buf_reserve(struct buffer *b, size_t extra)
{
    size_t need = b->len + extra + 1;
    if (need <= b->cap) {
        return;
    }
    while (b->cap < need) {
        b->cap *= 2;
    }
    b->data = realloc(b->data, b->cap);
}

static void buf_append(struct buffer *b, const char *s)
{
    size_t n = strlen(s);
    buf_reserve(b, n);
    memcpy(b->data + b->len, s, n);
    b->len += n;
    b->data[b->len] = '\0';
}

static void buf_printf(struct buffer *b, const char *fmt, ...)
{
    va_list ap;
    char stack[1024];
    int n;

    va_start(ap, fmt);
    n = vsnprintf(stack, sizeof(stack), fmt, ap);
    va_end(ap);

    if (n < 0) {
        return;
    }
    if ((size_t)n < sizeof(stack)) {
        buf_append(b, stack);
        return;
    }

    char *tmp = malloc((size_t)n + 1);
    if (!tmp) {
        return;
    }
    va_start(ap, fmt);
    vsnprintf(tmp, (size_t)n + 1, fmt, ap);
    va_end(ap);
    buf_append(b, tmp);
    free(tmp);
}

static void trim(char *s)
{
    size_t len;
    char *p = s;

    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') {
        p++;
    }
    if (p != s) {
        memmove(s, p, strlen(p) + 1);
    }

    len = strlen(s);
    while (len > 0 && (s[len - 1] == ' ' || s[len - 1] == '\t' ||
                       s[len - 1] == '\r' || s[len - 1] == '\n')) {
        s[--len] = '\0';
    }
}

static bool read_first_line(const char *path, char *out, size_t out_len)
{
    FILE *f = fopen(path, "r");
    if (!f) {
        if (out_len) {
            out[0] = '\0';
        }
        return false;
    }
    if (!fgets(out, (int)out_len, f)) {
        out[0] = '\0';
        fclose(f);
        return false;
    }
    fclose(f);
    trim(out);
    return true;
}

static unsigned long long read_ull_file(const char *path)
{
    char line[64];
    if (!read_first_line(path, line, sizeof(line))) {
        return 0;
    }
    return strtoull(line, NULL, 10);
}

static void read_cmd(const char *cmd, char *out, size_t out_len)
{
    FILE *p;
    if (out_len) {
        out[0] = '\0';
    }
    p = popen(cmd, "r");
    if (!p) {
        return;
    }
    if (fgets(out, (int)out_len, p)) {
        trim(out);
    }
    pclose(p);
}

static void json_string(struct buffer *b, const char *s)
{
    const unsigned char *p = (const unsigned char *)(s ? s : "");
    buf_append(b, "\"");
    while (*p) {
        switch (*p) {
        case '\\': buf_append(b, "\\\\"); break;
        case '"': buf_append(b, "\\\""); break;
        case '\b': buf_append(b, "\\b"); break;
        case '\f': buf_append(b, "\\f"); break;
        case '\n': buf_append(b, "\\n"); break;
        case '\r': buf_append(b, "\\r"); break;
        case '\t': buf_append(b, "\\t"); break;
        default:
            if (*p < 0x20) {
                buf_printf(b, "\\u%04x", *p);
            } else {
                char c[2] = { (char)*p, '\0' };
                buf_append(b, c);
            }
            break;
        }
        p++;
    }
    buf_append(b, "\"");
}

static void json_key_string(struct buffer *b, const char *key, const char *value)
{
    json_string(b, key);
    buf_append(b, ":");
    json_string(b, value);
}

static void get_default_iface(char *iface, size_t len)
{
    FILE *f = fopen("/proc/net/route", "r");
    char line[512];

    iface[0] = '\0';
    if (!f) {
        return;
    }

    while (fgets(line, sizeof(line), f)) {
        char name[64] = "";
        char dest[32] = "";
        if (sscanf(line, "%63s %31s", name, dest) == 2 && strcmp(dest, "00000000") == 0) {
            snprintf(iface, len, "%s", name);
            break;
        }
    }
    fclose(f);
}

static void get_openwrt_release_value(const char *key, char *out, size_t out_len)
{
    FILE *f = fopen("/etc/openwrt_release", "r");
    char line[512];
    size_t key_len = strlen(key);

    out[0] = '\0';
    if (!f) {
        return;
    }

    while (fgets(line, sizeof(line), f)) {
        trim(line);
        if (strncmp(line, key, key_len) == 0 && line[key_len] == '=') {
            char *v = line + key_len + 1;
            trim(v);
            if ((v[0] == '\'' || v[0] == '"') && strlen(v) >= 2) {
                char quote = v[0];
                v++;
                char *end = strrchr(v, quote);
                if (end) {
                    *end = '\0';
                }
            }
            snprintf(out, out_len, "%s", v);
            break;
        }
    }
    fclose(f);
}

static void append_system_status(struct buffer *b)
{
    char model[MAX_TEXT] = "";
    char firmware[MAX_TEXT] = "";
    char kernel[MAX_TEXT] = "";
    char hostname[MAX_TEXT] = "";
    char uptime_line[128] = "";
    char temp_line[64] = "";
    unsigned long uptime = 0;
    int temp = 0;
    int mem_usage = 0;

    read_first_line("/tmp/sysinfo/model", model, sizeof(model));
    if (model[0] == '\0') {
        read_first_line("/proc/device-tree/model", model, sizeof(model));
    }
    if (model[0] == '\0') {
        snprintf(model, sizeof(model), "OpenWrt Device");
    }

    get_openwrt_release_value("DISTRIB_DESCRIPTION", firmware, sizeof(firmware));
    if (firmware[0] == '\0') {
        snprintf(firmware, sizeof(firmware), "OpenWrt");
    }
    read_first_line("/proc/sys/kernel/osrelease", kernel, sizeof(kernel));
    read_first_line("/proc/sys/kernel/hostname", hostname, sizeof(hostname));

    if (read_first_line("/proc/uptime", uptime_line, sizeof(uptime_line))) {
        uptime = (unsigned long)strtod(uptime_line, NULL);
    }

    for (int i = 0; i < 10; i++) {
        char path[128];
        snprintf(path, sizeof(path), "/sys/class/thermal/thermal_zone%d/temp", i);
        if (read_first_line(path, temp_line, sizeof(temp_line))) {
            temp = atoi(temp_line);
            if (temp > 1000) {
                temp /= 1000;
            }
            if (temp > 0) {
                break;
            }
        }
    }

    FILE *mf = fopen("/proc/meminfo", "r");
    if (mf) {
        char line[256];
        unsigned long total = 0, avail = 0, free_mem = 0;
        while (fgets(line, sizeof(line), mf)) {
            sscanf(line, "MemTotal: %lu kB", &total);
            sscanf(line, "MemAvailable: %lu kB", &avail);
            sscanf(line, "MemFree: %lu kB", &free_mem);
        }
        fclose(mf);
        if (total > 0) {
            if (avail == 0) {
                avail = free_mem;
            }
            mem_usage = (int)(((total - avail) * 100) / total);
            if (mem_usage < 0) mem_usage = 0;
            if (mem_usage > 100) mem_usage = 100;
        }
    }

    buf_append(b, "\"system_status\":{");
    json_key_string(b, "hostname", hostname);
    buf_append(b, ",");
    json_key_string(b, "model", model);
    buf_append(b, ",");
    json_key_string(b, "firmware", firmware);
    buf_append(b, ",");
    json_key_string(b, "kernel", kernel);
    buf_printf(b, ",\"temp\":%d,\"systime_raw\":%ld,\"uptime_raw\":%lu,\"cpuUsage\":0,\"memUsage\":%d}",
               temp, (long)time(NULL), uptime, mem_usage);
}

static void append_network_status(struct buffer *b, const char *iface)
{
    char wan_ip[128] = "";
    char wan_ipv6[128] = "";
    char lan_ip[128] = "";
    char gateway[128] = "";
    char dns[128] = "";
    char cmd[384];
    bool online = iface && iface[0];

    if (iface && iface[0]) {
        snprintf(cmd, sizeof(cmd), "ip -4 addr show dev '%s' 2>/dev/null | awk '/inet / {print $2; exit}' | cut -d/ -f1", iface);
        read_cmd(cmd, wan_ip, sizeof(wan_ip));
        snprintf(cmd, sizeof(cmd), "ip -6 addr show dev '%s' scope global 2>/dev/null | awk '/inet6 / {print $2; exit}' | cut -d/ -f1", iface);
        read_cmd(cmd, wan_ipv6, sizeof(wan_ipv6));
    }

    read_cmd("ip -4 addr show dev br-lan 2>/dev/null | awk '/inet / {print $2; exit}' | cut -d/ -f1", lan_ip, sizeof(lan_ip));
    read_cmd("ip route 2>/dev/null | awk '/^default/ {print $3; exit}'", gateway, sizeof(gateway));
    read_cmd("awk '/^nameserver/ {print $2; exit}' /tmp/resolv.conf.d/resolv.conf.auto /etc/resolv.conf 2>/dev/null", dns, sizeof(dns));

    buf_append(b, "\"status\":{");
    buf_printf(b, "\"online\":%s,\"internet\":", online ? "true" : "false");
    json_string(b, online ? "up" : "down");
    buf_append(b, ",\"online_reason\":");
    json_string(b, online ? "default-route" : "no-default-route");
    buf_printf(b, ",\"link_up\":%s,\"route_ready\":%s,\"probe_ok\":false,\"conn_count\":%llu},",
               online ? "true" : "false", online ? "true" : "false",
               read_ull_file("/proc/sys/net/netfilter/nf_conntrack_count"));

    buf_append(b, "\"network_status\":{");
    buf_printf(b, "\"internet\":%d,\"online_reason\":", online ? 0 : 1);
    json_string(b, online ? "default-route" : "no-default-route");
    buf_append(b, ",\"interface\":");
    json_string(b, iface ? iface : "");
    buf_append(b, ",\"lan\":{\"ip\":");
    json_string(b, lan_ip);
    buf_append(b, ",\"dns\":[");
    if (dns[0]) json_string(b, dns);
    buf_append(b, "]},\"wan\":{\"ip\":");
    json_string(b, wan_ip);
    buf_append(b, ",\"ipv6\":");
    json_string(b, wan_ipv6);
    buf_append(b, ",\"gateway\":");
    json_string(b, gateway);
    buf_append(b, ",\"dns\":[");
    if (dns[0]) json_string(b, dns);
    buf_append(b, "]}}");
}

static void append_traffic(struct buffer *b, const char *iface)
{
    char path[256];
    unsigned long long tx = 0, rx = 0;
    unsigned long long tx_rate = 0, rx_rate = 0;
    time_t now = time(NULL);

    if (iface && iface[0]) {
        snprintf(path, sizeof(path), "/sys/class/net/%s/statistics/tx_bytes", iface);
        tx = read_ull_file(path);
        snprintf(path, sizeof(path), "/sys/class/net/%s/statistics/rx_bytes", iface);
        rx = read_ull_file(path);
    }

    if (g_traffic.ts > 0 && strcmp(g_traffic.iface, iface ? iface : "") == 0 && now > g_traffic.ts) {
        unsigned long dt = (unsigned long)(now - g_traffic.ts);
        if (tx >= g_traffic.tx) {
            tx_rate = (tx - g_traffic.tx) / dt;
        }
        if (rx >= g_traffic.rx) {
            rx_rate = (rx - g_traffic.rx) / dt;
        }
    }

    snprintf(g_traffic.iface, sizeof(g_traffic.iface), "%s", iface ? iface : "");
    g_traffic.tx = tx;
    g_traffic.rx = rx;
    g_traffic.ts = now;

    buf_append(b, "\"interface_traffic\":{");
    buf_append(b, "\"interface\":");
    json_string(b, iface ? iface : "");
    buf_printf(b, ",\"tx_bytes\":%llu,\"rx_bytes\":%llu,\"tx_rate\":%llu,\"rx_rate\":%llu,\"sampled_at\":%ld,\"source\":\"dashboard-core\"}",
               tx, rx, tx_rate, rx_rate, (long)now);
}

static int load_devices(struct device *devices, int max_devices)
{
    FILE *leases = fopen("/tmp/dhcp.leases", "r");
    int count = 0;

    if (leases) {
        char line[512];
        while (count < max_devices && fgets(line, sizeof(line), leases)) {
            char ts[64] = "", mac[64] = "", ip[64] = "", name[128] = "";
            if (sscanf(line, "%63s %63s %63s %127s", ts, mac, ip, name) >= 3) {
                snprintf(devices[count].ip, sizeof(devices[count].ip), "%s", ip);
                snprintf(devices[count].mac, sizeof(devices[count].mac), "%s", mac);
                snprintf(devices[count].name, sizeof(devices[count].name), "%s", strcmp(name, "*") == 0 ? "" : name);
                devices[count].active = false;
                count++;
            }
        }
        fclose(leases);
    }

    FILE *arp = fopen("/proc/net/arp", "r");
    if (arp) {
        char line[512];
        while (fgets(line, sizeof(line), arp)) {
            char ip[64], hw[64], flags[64], mac[64];
            if (sscanf(line, "%63s %63s %63s %63s", ip, hw, flags, mac) == 4 && strcmp(ip, "IP") != 0) {
                bool found = false;
                for (int i = 0; i < count; i++) {
                    if (strcmp(devices[i].ip, ip) == 0) {
                        devices[i].active = strcmp(flags, "0x2") == 0;
                        found = true;
                        break;
                    }
                }
                if (!found && count < max_devices && strcmp(flags, "0x2") == 0) {
                    snprintf(devices[count].ip, sizeof(devices[count].ip), "%s", ip);
                    snprintf(devices[count].mac, sizeof(devices[count].mac), "%s", mac);
                    devices[count].name[0] = '\0';
                    devices[count].active = true;
                    count++;
                }
            }
        }
        fclose(arp);
    }

    return count;
}

static void append_devices(struct buffer *b)
{
    struct device devices[MAX_DEVICES];
    int count = load_devices(devices, MAX_DEVICES);
    int active = 0;

    for (int i = 0; i < count; i++) {
        if (devices[i].active) {
            active++;
        }
    }

    buf_printf(b, "\"devices\":{\"total\":%d,\"active\":%d,\"list\":[", count, active);
    for (int i = 0; i < count; i++) {
        if (i) buf_append(b, ",");
        buf_append(b, "{");
        json_key_string(b, "mac", devices[i].mac);
        buf_append(b, ",");
        json_key_string(b, "ip", devices[i].ip);
        buf_append(b, ",");
        json_key_string(b, "name", devices[i].name[0] ? devices[i].name : devices[i].ip);
        buf_append(b, ",\"type\":\"laptop\",\"active\":");
        buf_append(b, devices[i].active ? "true" : "false");
        buf_append(b, "}");
    }
    buf_append(b, "]}");
}


#define HASH_SIZE 4096

struct domain_node {
    char domain[128];
    int count;
    int last_seen;
    struct domain_node *next;
};

struct ip_domain_node {
    char domain[128];
    int weight;
    struct ip_domain_node *next;
};

struct ip_node {
    char ip[64];
    struct ip_domain_node *domains;
    struct ip_node *next;
};

struct client_node {
    char ip[64];
    struct client_node *next;
};

struct realtime_node {
    char domain[128];
    int count;
    int last_seen;
    int devices;
    struct client_node *clients;
    struct realtime_node *next;
};

struct app_node {
    char name[64];
    char class_name[64];
    int hits;
    int latest_seq;
    struct app_node *next;
};

struct app_rule {
    const char *app;
    const char *class_name;
    const char *pattern;
};

static const struct app_rule APP_RULES[] = {
    {"YouTube", "video", "youtube.com"}, {"YouTube", "video", "googlevideo.com"}, {"YouTube", "video", "ytimg.com"},
    {"Netflix", "video", "netflix.com"}, {"Netflix", "video", "nflxvideo.net"},
    {"Bilibili", "video", "bilibili.com"}, {"Bilibili", "video", "bilivideo.com"},
    {"TikTok", "social", "tiktok.com"}, {"TikTok", "social", "byteoversea.com"}, {"TikTok", "social", "musical.ly"},
    {"Douyin", "social", "douyin.com"}, {"Douyin", "social", "douyincdn.com"},
    {"WeChat", "social", "wechat.com"}, {"WeChat", "social", "weixin.qq.com"}, {"WeChat", "social", "qpic.cn"},
    {"QQ", "social", "qq.com"}, {"QQ", "social", "qzone.qq.com"}, {"QQ", "social", "tencent.com"},
    {"Telegram", "social", "telegram.org"}, {"Telegram", "social", "t.me"},
    {"Discord", "social", "discord.com"}, {"Discord", "social", "discord.gg"},
    {"GitHub", "developer", "github.com"}, {"GitHub", "developer", "githubusercontent.com"},
    {"Steam", "game", "steampowered.com"}, {"Steam", "game", "steamstatic.com"},
    {"PlayStation", "game", "playstation.com"}, {"PlayStation", "game", "psn"},
    {"Xbox", "game", "xboxlive.com"}, {"Xbox", "game", "xbox.com"},
    {"Apple", "cloud", "apple.com"}, {"Apple", "cloud", "icloud.com"}, {"Apple", "cloud", "mzstatic.com"},
    {"Google", "search", "google.com"}, {"Google", "search", "gstatic.com"}, {"Google", "search", "googleapis.com"},
    {"Microsoft", "cloud", "microsoft.com"}, {"Microsoft", "cloud", "live.com"}, {"Microsoft", "cloud", "office.com"},
    {NULL, NULL, NULL}
};

static struct domain_node *domain_hash_table[HASH_SIZE];
static struct ip_node *ip_hash_table[HASH_SIZE];
static struct realtime_node *realtime_hash_table[HASH_SIZE];
static struct app_node *app_hash_table[HASH_SIZE];
static int g_seq = 0;

static unsigned int hash_str(const char *str) {
    unsigned int hash = 5381;
    int c;
    while ((c = *str++))
        hash = ((hash << 5) + hash) + c;
    return hash % HASH_SIZE;
}

static void clear_hashes() {
    for (int i = 0; i < HASH_SIZE; i++) {
        struct domain_node *d = domain_hash_table[i];
        while (d) {
            struct domain_node *tmp = d;
            d = d->next;
            free(tmp);
        }
        domain_hash_table[i] = NULL;

        struct ip_node *ipn = ip_hash_table[i];
        while (ipn) {
            struct ip_node *tmp = ipn;
            struct ip_domain_node *dn = ipn->domains;
            while (dn) {
                struct ip_domain_node *dtmp = dn;
                dn = dn->next;
                free(dtmp);
            }
            ipn = ipn->next;
            free(tmp);
        }
        ip_hash_table[i] = NULL;

        struct realtime_node *rn = realtime_hash_table[i];
        while (rn) {
            struct realtime_node *tmp = rn;
            struct client_node *cn = rn->clients;
            while (cn) {
                struct client_node *ctmp = cn;
                cn = cn->next;
                free(ctmp);
            }
            rn = rn->next;
            free(tmp);
        }
        realtime_hash_table[i] = NULL;

        struct app_node *an = app_hash_table[i];
        while (an) {
            struct app_node *tmp = an;
            an = an->next;
            free(tmp);
        }
        app_hash_table[i] = NULL;
    }
}

static void record_app(const char *name, const char *class_name) {
    unsigned int h = hash_str(name);
    struct app_node *node = app_hash_table[h];
    while (node) {
        if (strcmp(node->name, name) == 0) {
            node->hits++;
            node->latest_seq = g_seq;
            return;
        }
        node = node->next;
    }
    node = malloc(sizeof(struct app_node));
    if (!node) return;
    strncpy(node->name, name, sizeof(node->name)-1);
    node->name[sizeof(node->name)-1] = '\0';
    strncpy(node->class_name, class_name, sizeof(node->class_name)-1);
    node->class_name[sizeof(node->class_name)-1] = '\0';
    node->hits = 1;
    node->latest_seq = g_seq;
    node->next = app_hash_table[h];
    app_hash_table[h] = node;
}

static bool is_ipv4_literal(const char *value)
{
    int d1, d2, d3, d4;
    char tail;
    return value && sscanf(value, "%d.%d.%d.%d%c", &d1, &d2, &d3, &d4, &tail) == 4 &&
           d1 >= 0 && d1 <= 255 && d2 >= 0 && d2 <= 255 &&
           d3 >= 0 && d3 <= 255 && d4 >= 0 && d4 <= 255;
}

static void match_app(const char *domain) {
    for (int i = 0; APP_RULES[i].app != NULL; i++) {
        if (strstr(domain, APP_RULES[i].pattern)) {
            record_app(APP_RULES[i].app, APP_RULES[i].class_name);
            break;
        }
    }
}

static void record_ip_domain(const char *ip, const char *domain) {
    if (!ip || !domain || !*ip || !*domain) return;
    unsigned int h = hash_str(ip);
    struct ip_node *node = ip_hash_table[h];
    while (node) {
        if (strcmp(node->ip, ip) == 0) {
            struct ip_domain_node *dn = node->domains;
            while (dn) {
                if (strcmp(dn->domain, domain) == 0) {
                    dn->weight++;
                    return;
                }
                dn = dn->next;
            }
            dn = calloc(1, sizeof(*dn));
            if (!dn) return;
            snprintf(dn->domain, sizeof(dn->domain), "%s", domain);
            dn->weight = 1;
            dn->next = node->domains;
            node->domains = dn;
            return;
        }
        node = node->next;
    }
    node = calloc(1, sizeof(*node));
    if (!node) return;
    snprintf(node->ip, sizeof(node->ip), "%s", ip);
    node->next = ip_hash_table[h];
    ip_hash_table[h] = node;
    record_ip_domain(ip, domain);
}

static const char* lookup_ip(const char *ip) {
    if (!ip || !*ip) return NULL;
    unsigned int h = hash_str(ip);
    struct ip_node *node = ip_hash_table[h];
    while (node) {
        if (strcmp(node->ip, ip) == 0) {
            struct ip_domain_node *best = NULL;
            for (struct ip_domain_node *dn = node->domains; dn; dn = dn->next) {
                if (!best || dn->weight > best->weight) {
                    best = dn;
                }
            }
            return best ? best->domain : NULL;
        }
        node = node->next;
    }
    return NULL;
}

static void record_realtime_domain(const char *domain, const char *client_ip)
{
    if (!domain || !*domain) return;

    unsigned int h = hash_str(domain);
    struct realtime_node *node = realtime_hash_table[h];
    while (node) {
        if (strcmp(node->domain, domain) == 0) {
            node->count++;
            node->last_seen = g_seq;
            break;
        }
        node = node->next;
    }
    if (!node) {
        node = calloc(1, sizeof(*node));
        if (!node) return;
        snprintf(node->domain, sizeof(node->domain), "%s", domain);
        node->count = 1;
        node->last_seen = g_seq;
        node->next = realtime_hash_table[h];
        realtime_hash_table[h] = node;
    }

    if (client_ip && *client_ip) {
        for (struct client_node *cn = node->clients; cn; cn = cn->next) {
            if (strcmp(cn->ip, client_ip) == 0) {
                return;
            }
        }
        struct client_node *cn = calloc(1, sizeof(*cn));
        if (!cn) return;
        snprintf(cn->ip, sizeof(cn->ip), "%s", client_ip);
        cn->next = node->clients;
        node->clients = cn;
        node->devices++;
    }
}

static void record_domain(const char *domain, int weight) {
    if (!domain || !*domain) return;
    match_app(domain);
    unsigned int h = hash_str(domain);
    struct domain_node *node = domain_hash_table[h];
    while (node) {
        if (strcmp(node->domain, domain) == 0) {
            node->count += weight;
            node->last_seen = ++g_seq;
            return;
        }
        node = node->next;
    }
    node = calloc(1, sizeof(*node));
    if (!node) return;
    snprintf(node->domain, sizeof(node->domain), "%s", domain);
    node->count = weight;
    node->last_seen = ++g_seq;
    node->next = domain_hash_table[h];
    domain_hash_table[h] = node;
}

static void normalize_domain(const char *raw, char *out, size_t out_len) {
    out[0] = '\0';
    if (!raw || !*raw) return;
    const char *p = raw;
    while (*p && isspace((unsigned char)*p)) p++;
    if (strncmp(p, "https://", 8) == 0) p += 8;
    else if (strncmp(p, "http://", 7) == 0) p += 7;

    if (strncmp(p, "*.", 2) == 0) p += 2;

    size_t i = 0;
    bool has_alpha = false;
    while (*p && !isspace((unsigned char)*p) && *p != '/' && *p != ':' &&
           *p != '&' && *p != '"' && *p != '\'' && *p != ',' &&
           *p != ')' && *p != ']' && i < out_len - 1) {
        if (isalpha((unsigned char)*p)) has_alpha = true;
        out[i++] = tolower((unsigned char)*p);
        p++;
    }
    out[i] = '\0';

    while (i > 0 && out[i-1] == '.') {
        out[--i] = '\0';
    }

    if (!strchr(out, '.') || !has_alpha) {
        out[0] = '\0';
        return;
    }

    if (is_ipv4_literal(out)) {
        out[0] = '\0';
        return;
    }
    if (strstr(out, "in-addr.arpa") || strcmp(out, "localhost") == 0) {
        out[0] = '\0';
    }
}

static bool remember_line_domain(char seen[][128], int *seen_count, const char *domain)
{
    for (int i = 0; i < *seen_count; i++) {
        if (strcmp(seen[i], domain) == 0) {
            return false;
        }
    }
    if (*seen_count < 32) {
        snprintf(seen[*seen_count], sizeof(seen[*seen_count]), "%s", domain);
        (*seen_count)++;
    }
    return true;
}

static void record_candidate(const char *raw, int weight, char seen[][128], int *seen_count)
{
    char dom[256];
    normalize_domain(raw, dom, sizeof(dom));
    if (dom[0] && remember_line_domain(seen, seen_count, dom)) {
        record_domain(dom, weight);
    }
}

static void scan_generic_domains(const char *line, int weight, char seen[][128], int *seen_count)
{
    const char *p = line;
    while (*p) {
        while (*p && !(isalnum((unsigned char)*p))) p++;
        const char *start = p;
        bool dot = false;
        while (*p && (isalnum((unsigned char)*p) || *p == '-' || *p == '.')) {
            if (*p == '.') dot = true;
            p++;
        }
        if (dot && p > start && (size_t)(p - start) < 256) {
            char token[256];
            memcpy(token, start, (size_t)(p - start));
            token[p - start] = '\0';
            record_candidate(token, weight, seen, seen_count);
        }
    }
}

static void extract_and_record(const char *line, int weight) {
    char buf[256];
    const char *p;
    char seen[32][128];
    int seen_count = 0;

    if ((p = strstr(line, "--> "))) {
        if (sscanf(p + 4, "%255[^:]", buf) == 1) {
            record_candidate(buf, weight, seen, &seen_count);
        }
    }
    if ((p = strstr(line, "[DNS] "))) {
        if (sscanf(p + 6, "%255s", buf) == 1) {
            record_candidate(buf, weight, seen, &seen_count);
        }
    }
    if ((p = strstr(line, "host="))) {
        if (sscanf(p + 5, "%255[^ \t\r\n&\"']", buf) == 1) {
            record_candidate(buf, weight, seen, &seen_count);
        }
    }
    if ((p = strstr(line, "sni="))) {
        if (sscanf(p + 4, "%255[^ \t\r\n&\"']", buf) == 1) {
            record_candidate(buf, weight, seen, &seen_count);
        }
    }
    if ((p = strstr(line, "query"))) {
        const char *q = strstr(p, " from");
        const char *name = p + 5;
        while (*name && (isalnum((unsigned char)*name) || *name == '[' || *name == ']')) name++;
        while (*name && isspace((unsigned char)*name)) name++;
        if (q && q > name && (size_t)(q - name) < sizeof(buf)) {
            memcpy(buf, name, (size_t)(q - name));
            buf[q - name] = '\0';
            record_candidate(buf, weight, seen, &seen_count);
        }
    }
    if ((p = strstr(line, "reply "))) {
        char reply_dom[256], is_word[16], reply_ip[64];
        if (sscanf(p + 6, "%255s %15s %63s", reply_dom, is_word, reply_ip) == 3 && strcmp(is_word, "is") == 0) {
            char dom[256];
            normalize_domain(reply_dom, dom, sizeof(dom));
            if (dom[0]) {
                if (remember_line_domain(seen, &seen_count, dom)) record_domain(dom, weight);
                record_ip_domain(reply_ip, dom);
            }
        }
    }
    if ((p = strstr(line, "cached "))) {
        char reply_dom[256], is_word[16], reply_ip[64];
        if (sscanf(p + 7, "%255s %15s %63s", reply_dom, is_word, reply_ip) == 3 && strcmp(is_word, "is") == 0) {
            char dom[256];
            normalize_domain(reply_dom, dom, sizeof(dom));
            if (dom[0]) {
                if (remember_line_domain(seen, &seen_count, dom)) record_domain(dom, weight);
                record_ip_domain(reply_ip, dom);
            }
        }
    }

    if ((p = strstr(line, "\"domain\"")) || (p = strstr(line, "\"host\"")) || (p = strstr(line, "\"url\"")) || (p = strstr(line, "\"sni\""))) {
        const char *colon = strchr(p, ':');
        if (colon) {
            const char *quote = strchr(colon, '"');
            if (quote) {
                if (sscanf(quote + 1, "%255[^\"]", buf) == 1) {
                    record_candidate(buf, weight, seen, &seen_count);
                }
            }
        }
    }
    scan_generic_domains(line, weight, seen, &seen_count);
}

static void parse_conntrack() {
    FILE *p = popen("conntrack -L 2>/dev/null", "r");
    if (!p) return;
    char line[512];
    while (fgets(line, sizeof(line), p)) {
        char *dst = strstr(line, "dst=");
        char *src = strstr(line, "src=");
        if (dst) {
            char ip[64];
            if (sscanf(dst + 4, "%63[^ \t\r\n]", ip) == 1) {
                const char *dom = lookup_ip(ip);
                if (dom) {
                    char src_ip[64] = "";
                    if (src) {
                        sscanf(src + 4, "%63[^ \t\r\n]", src_ip);
                    }
                    record_domain(dom, 1);
                    record_realtime_domain(dom, src_ip);
                }
            }
        }
    }
    pclose(p);
}

static void parse_command_lines(const char *cmd) {
    FILE *p = popen(cmd, "r");
    if (!p) return;
    char line[1024];
    while (fgets(line, sizeof(line), p)) {
        extract_and_record(line, 1);
    }
    pclose(p);
}

static int cmp_domain_count(const void *a, const void *b) {
    const struct domain_node *na = *(const struct domain_node **)a;
    const struct domain_node *nb = *(const struct domain_node **)b;
    if (na->count != nb->count) return nb->count - na->count;
    return nb->last_seen - na->last_seen;
}

static int cmp_domain_recent(const void *a, const void *b) {
    const struct domain_node *na = *(const struct domain_node **)a;
    const struct domain_node *nb = *(const struct domain_node **)b;
    return nb->last_seen - na->last_seen;
}

static int cmp_realtime_count(const void *a, const void *b) {
    const struct realtime_node *na = *(const struct realtime_node **)a;
    const struct realtime_node *nb = *(const struct realtime_node **)b;
    if (na->count != nb->count) return nb->count - na->count;
    return nb->last_seen - na->last_seen;
}

static int cmp_app_count(const void *a, const void *b) {
    const struct app_node *na = *(const struct app_node **)a;
    const struct app_node *nb = *(const struct app_node **)b;
    if (na->hits != nb->hits) return nb->hits - na->hits;
    return nb->latest_seq - na->latest_seq;
}

static int count_domain_hits(void)
{
    int total = 0;
    for (int i = 0; i < HASH_SIZE; i++) {
        for (struct domain_node *node = domain_hash_table[i]; node; node = node->next) {
            total += node->count;
        }
    }
    return total;
}

static int count_realtime_rows(void)
{
    int total = 0;
    for (int i = 0; i < HASH_SIZE; i++) {
        for (struct realtime_node *node = realtime_hash_table[i]; node; node = node->next) {
            total++;
        }
    }
    return total;
}

static void append_source_label(char *dst, size_t dst_len, const char *label)
{
    size_t used;
    if (!label || !*label || dst_len == 0) return;
    used = strlen(dst);
    if (used >= dst_len - 1) return;
    if (dst[0] != '\0') {
        strncat(dst, "+", dst_len - used - 1);
        used = strlen(dst);
        if (used >= dst_len - 1) return;
    }
    strncat(dst, label, dst_len - used - 1);
}

static void parse_named_source(const char *label, const char *cmd, char *source, size_t source_len)
{
    int before = count_domain_hits();
    parse_command_lines(cmd);
    if (count_domain_hits() > before) {
        append_source_label(source, source_len, label);
    }
}

static void append_domains_and_apps(struct buffer *b) {
    char source[256] = "";
    char realtime_source[64] = "none";

    g_seq = 0;
    clear_hashes();

    parse_named_source("appfilter", "ubus call appfilter visit_list 2>/dev/null", source, sizeof(source));
    parse_named_source("dnsmasq-logread", "logread | grep -iE 'dnsmasq' | tail -n 12000", source, sizeof(source));

    int before_conntrack = count_domain_hits();
    parse_conntrack();
    if (count_domain_hits() > before_conntrack) {
        append_source_label(source, sizeof(source), "conntrack+dnsmasq");
        snprintf(realtime_source, sizeof(realtime_source), "conntrack+dnsmasq");
    }

    parse_named_source("smartdns", "tail -n 6000 /tmp/smartdns.log 2>/dev/null", source, sizeof(source));
    parse_named_source("adguardhome", "tail -n 6000 /tmp/AdGuardHome.log 2>/dev/null", source, sizeof(source));
    parse_named_source("mosdns", "tail -n 6000 /tmp/mosdns.log 2>/dev/null", source, sizeof(source));
    parse_named_source("openclash", "tail -n 6000 /tmp/openclash.log 2>/dev/null", source, sizeof(source));
    parse_named_source("passwall", "tail -n 6000 /tmp/log/passwall.log 2>/dev/null", source, sizeof(source));
    parse_named_source("passwall2", "tail -n 6000 /tmp/log/passwall2.log 2>/dev/null", source, sizeof(source));
    parse_named_source("homeproxy", "tail -n 6000 /tmp/homeproxy.log 2>/dev/null", source, sizeof(source));
    parse_named_source("mihomo", "tail -n 6000 /tmp/mihomo.log 2>/dev/null", source, sizeof(source));
    parse_named_source("sing-box", "tail -n 6000 /tmp/sing-box.log 2>/dev/null", source, sizeof(source));
    parse_named_source("logread-dns", "logread | grep -iE 'smartdns|adguardhome|mosdns|unbound|pdnsd|chinadns|openclash|passwall|mihomo|sing-box|homeproxy|appfilter' | tail -n 8000", source, sizeof(source));
    if (source[0] == '\0') {
        snprintf(source, sizeof(source), "none");
    }

    int g_all_domains_count = 0;
    for (int i = 0; i < HASH_SIZE; i++) {
        struct domain_node *node = domain_hash_table[i];
        while (node) {
            g_all_domains_count++;
            node = node->next;
        }
    }

    struct domain_node **g_all_domains = malloc(sizeof(struct domain_node *) * (g_all_domains_count + 1));
    if (!g_all_domains) {
        g_all_domains_count = 0;
    }
    int idx = 0;
    if (g_all_domains) {
        for (int i = 0; i < HASH_SIZE; i++) {
            struct domain_node *node = domain_hash_table[i];
            while (node) {
                g_all_domains[idx++] = node;
                node = node->next;
            }
        }
    }

    int g_all_realtime_count = count_realtime_rows();
    struct realtime_node **g_all_realtime = NULL;
    if (g_all_realtime_count > 0) {
        g_all_realtime = malloc(sizeof(struct realtime_node *) * (size_t)g_all_realtime_count);
        if (g_all_realtime) {
            int ridx = 0;
            for (int i = 0; i < HASH_SIZE; i++) {
                struct realtime_node *node = realtime_hash_table[i];
                while (node) {
                    g_all_realtime[ridx++] = node;
                    node = node->next;
                }
            }
            qsort(g_all_realtime, g_all_realtime_count, sizeof(struct realtime_node *), cmp_realtime_count);
        } else {
            g_all_realtime_count = 0;
        }
    }

    buf_append(b, "\"domains\":{\"source\":");
    json_string(b, source);
    buf_append(b, ",\"realtime_source\":");
    json_string(b, realtime_source);
    buf_append(b, ",\"top\":[");
    qsort(g_all_domains, g_all_domains_count, sizeof(struct domain_node *), cmp_domain_count);
    int top_count = g_all_domains_count > 25 ? 25 : g_all_domains_count;
    for (int i = 0; i < top_count; i++) {
        if (i > 0) buf_append(b, ",");
        buf_append(b, "{");
        json_key_string(b, "domain", g_all_domains[i]->domain);
        buf_printf(b, ",\"count\":%d}", g_all_domains[i]->count);
    }
    buf_append(b, "],\"recent\":[");
    qsort(g_all_domains, g_all_domains_count, sizeof(struct domain_node *), cmp_domain_recent);
    int recent_count = g_all_domains_count > 25 ? 25 : g_all_domains_count;
    for (int i = 0; i < recent_count; i++) {
        if (i > 0) buf_append(b, ",");
        buf_append(b, "{");
        json_key_string(b, "domain", g_all_domains[i]->domain);
        buf_printf(b, ",\"count\":%d}", g_all_domains[i]->count);
    }
    buf_append(b, "],\"realtime\":[");
    int realtime_count = g_all_realtime_count > 25 ? 25 : g_all_realtime_count;
    for (int i = 0; i < realtime_count; i++) {
        if (i > 0) buf_append(b, ",");
        buf_append(b, "{");
        json_key_string(b, "domain", g_all_realtime[i]->domain);
        buf_printf(b, ",\"count\":%d,\"devices\":%d}", g_all_realtime[i]->count, g_all_realtime[i]->devices);
    }
    buf_append(b, "]},\"realtime_urls\":{\"source\":");
    json_string(b, realtime_source);
    buf_printf(b, ",\"total\":%d,\"list\":[", realtime_count);
    for (int i = 0; i < realtime_count; i++) {
        if (i > 0) buf_append(b, ",");
        buf_append(b, "{");
        json_key_string(b, "domain", g_all_realtime[i]->domain);
        buf_printf(b, ",\"count\":%d,\"hits\":%d,\"devices\":%d}", g_all_realtime[i]->count, g_all_realtime[i]->count, g_all_realtime[i]->devices);
    }
    buf_append(b, "]},");

    free(g_all_domains);
    free(g_all_realtime);

    // Apps
    int g_all_apps_count = 0;
    for (int i = 0; i < HASH_SIZE; i++) {
        struct app_node *node = app_hash_table[i];
        while (node) {
            g_all_apps_count++;
            node = node->next;
        }
    }

    struct app_node **g_all_apps = malloc(sizeof(struct app_node *) * (g_all_apps_count + 1));
    if (!g_all_apps) {
        g_all_apps_count = 0;
    }
    idx = 0;
    if (g_all_apps) {
        for (int i = 0; i < HASH_SIZE; i++) {
            struct app_node *node = app_hash_table[i];
            while (node) {
                g_all_apps[idx++] = node;
                node = node->next;
            }
        }
    }

    qsort(g_all_apps, g_all_apps_count, sizeof(struct app_node *), cmp_app_count);
    int top_apps = g_all_apps_count > 12 ? 12 : g_all_apps_count;

    buf_printf(b, "\"online_apps\":{\"total\":%d,\"list\":[", top_apps);
    for (int i = 0; i < top_apps; i++) {
        if (i > 0) buf_append(b, ",");
        buf_append(b, "{");
        json_key_string(b, "name", g_all_apps[i]->name);
        buf_append(b, ",");
        json_key_string(b, "class", g_all_apps[i]->class_name);
        buf_append(b, ",");
        json_key_string(b, "class_label", g_all_apps[i]->class_name);
        buf_append(b, ",");
        json_key_string(b, "source", "domain-heuristic");
        buf_printf(b, ",\"hits\":%d,\"time\":%d,\"id\":%d}", g_all_apps[i]->hits, g_all_apps[i]->hits, i);
    }
    buf_append(b, "],\"source\":\"domain-heuristic\"},");

    // app_recognition
    buf_append(b, "\"app_recognition\":{\"available\":");
    buf_append(b, top_apps > 0 ? "true" : "false");
    buf_append(b, ",\"source\":\"domain-heuristic\",\"engine\":\"dashboard-core\",\"feature_version\":\"\",\"class_stats\":[]}");

    free(g_all_apps);
}


static char *build_databus(void)
{
    struct buffer b;
    char iface[64];

    get_default_iface(iface, sizeof(iface));
    buf_init(&b);

    buf_append(&b, "{\"code\":0,\"timestamp\":");
    buf_printf(&b, "%ld,", (long)time(NULL));
    append_network_status(&b, iface);
    buf_append(&b, ",");
    append_system_status(&b);
    buf_append(&b, ",");
    append_traffic(&b, iface);
    buf_append(&b, ",");
    append_domains_and_apps(&b);
    buf_append(&b, ",");
    append_devices(&b);
    buf_append(&b, "}");

    return b.data;
}

static void send_response(int fd, int status, const char *status_text, const char *body)
{
    const char *payload = body ? body : "";
    dprintf(fd,
            "HTTP/1.1 %d %s\r\n"
            "Content-Type: application/json\r\n"
            "Cache-Control: no-store\r\n"
            "Connection: close\r\n"
            "Content-Length: %zu\r\n\r\n%s",
            status, status_text, strlen(payload), payload);
}

static void handle_client(int fd)
{
    char req[1024];
    ssize_t n = read(fd, req, sizeof(req) - 1);
    if (n <= 0) {
        close(fd);
        return;
    }
    req[n] = '\0';

    if (strncmp(req, "GET /databus", 12) == 0 || strncmp(req, "GET /databus?", 13) == 0) {
        char *body = build_databus();
        send_response(fd, 200, "OK", body);
        free(body);
    } else if (strncmp(req, "GET /health", 11) == 0) {
        send_response(fd, 200, "OK", "{\"ok\":true}");
    } else {
        send_response(fd, 404, "Not Found", "{\"code\":404,\"error\":\"not found\"}");
    }
    close(fd);
}

static void parse_listen(const char *value, char *host, size_t host_len, int *port)
{
    const char *colon = strrchr(value, ':');
    snprintf(host, host_len, "%s", DEFAULT_LISTEN_HOST);
    *port = DEFAULT_LISTEN_PORT;

    if (!value || !*value) {
        return;
    }
    if (colon) {
        size_t n = (size_t)(colon - value);
        if (n >= host_len) n = host_len - 1;
        memcpy(host, value, n);
        host[n] = '\0';
        *port = atoi(colon + 1);
    } else {
        *port = atoi(value);
    }
    if (*port <= 0 || *port > 65535) {
        *port = DEFAULT_LISTEN_PORT;
    }
}

int main(int argc, char **argv)
{
    char host[64] = DEFAULT_LISTEN_HOST;
    int port = DEFAULT_LISTEN_PORT;
    int server_fd;
    struct sockaddr_in addr;
    int one = 1;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--listen") == 0 && i + 1 < argc) {
            parse_listen(argv[++i], host, sizeof(host), &port);
        }
    }

    signal(SIGPIPE, SIG_IGN);

    server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        perror("socket");
        return 1;
    }

    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
        fprintf(stderr, "Invalid listen host: %s\n", host);
        close(server_fd);
        return 1;
    }

    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(server_fd);
        return 1;
    }
    if (listen(server_fd, 16) < 0) {
        perror("listen");
        close(server_fd);
        return 1;
    }

    fprintf(stderr, "dashboard-core listening on %s:%d\n", host, port);
    for (;;) {
        int client_fd = accept(server_fd, NULL, NULL);
        if (client_fd < 0) {
            if (errno == EINTR) {
                continue;
            }
            perror("accept");
            break;
        }
        handle_client(client_fd);
    }

    close(server_fd);
    return 0;
}
