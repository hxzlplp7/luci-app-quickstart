#include <arpa/inet.h>
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
    buf_append(&b, ",\"online_apps\":{\"total\":0,\"list\":[]}");
    buf_append(&b, ",\"app_recognition\":{\"available\":false,\"source\":\"dashboard-core\",\"engine\":\"dashboard-core-stage1\",\"feature_version\":\"\",\"class_stats\":[]}");
    buf_append(&b, ",\"domains\":{\"source\":\"dashboard-core\",\"realtime_source\":\"dashboard-core\",\"top\":[],\"recent\":[],\"realtime\":[]}");
    buf_append(&b, ",\"realtime_urls\":{\"source\":\"dashboard-core\",\"total\":0,\"list\":[]},");
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
