#include "quik_probe.h"
#include <libproc.h>
#include <string.h>
#include <stdlib.h>
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>

int quik_proc_usage_read(pid_t pid, quik_proc_usage *out) {
    memset(out, 0, sizeof(*out));
    struct rusage_info_v4 ri;
    int r = proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri);
    if (r != 0) { out->err = r; return r; }
    out->ok = 1;
    out->cpu_ns = ri.ri_user_time + ri.ri_system_time;
    out->disk_read_bytes = ri.ri_diskio_bytesread;
    out->disk_write_bytes = ri.ri_diskio_byteswritten;
    out->footprint_bytes = ri.ri_phys_footprint;
    return 0;
}

static uint64_t dict_u64(CFDictionaryRef d, CFStringRef key) {
    CFNumberRef n = (CFNumberRef)CFDictionaryGetValue(d, key);
    if (!n) return 0;
    long long v = 0;
    CFNumberGetValue(n, kCFNumberSInt64Type, &v);
    return v < 0 ? 0 : (uint64_t)v;
}

int quik_disk_totals_read(quik_disk_totals *out) {
    memset(out, 0, sizeof(*out));
    io_iterator_t iter = 0;
    CFMutableDictionaryRef match = IOServiceMatching("IOBlockStorageDriver");
    if (!match) return -1;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) != KERN_SUCCESS) return -1;
    io_registry_entry_t entry;
    while ((entry = IOIteratorNext(iter))) {
        CFTypeRef stats = IORegistryEntryCreateCFProperty(entry, CFSTR("Statistics"), kCFAllocatorDefault, 0);
        if (stats && CFGetTypeID(stats) == CFDictionaryGetTypeID()) {
            CFDictionaryRef d = (CFDictionaryRef)stats;
            uint64_t r = dict_u64(d, CFSTR("Bytes (Read)"));
            uint64_t w = dict_u64(d, CFSTR("Bytes (Write)"));
            uint64_t busy = dict_u64(d, CFSTR("Total Time (Read)"));
            busy += dict_u64(d, CFSTR("Total Time (Write)"));
            if (r || w || busy) out->device_count++;
            out->read_bytes += r;
            out->write_bytes += w;
            out->busy_ns += busy;
        }
        if (stats) CFRelease(stats);
        IOObjectRelease(entry);
    }
    IOObjectRelease(iter);
    out->ok = 1;
    return 0;
}

int quik_list_pids(pid_t *out, int capacity) {
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (bytes <= 0) return -1;
    pid_t *buf = malloc((size_t)bytes);
    if (!buf) return -1;
    int n = proc_listpids(PROC_ALL_PIDS, 0, buf, bytes);
    if (n <= 0) { free(buf); return -1; }
    int count = n / (int)sizeof(pid_t);
    int written = 0;
    for (int i = 0; i < count && written < capacity; i++) {
        if (buf[i] > 0) out[written++] = buf[i];
    }
    free(buf);
    return written;
}
