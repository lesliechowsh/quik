#ifndef QUIK_PROBE_H
#define QUIK_PROBE_H

#include <stdint.h>
#include <sys/types.h>

typedef struct {
    int ok;
    int err;
    uint64_t cpu_ns;
    uint64_t disk_read_bytes;
    uint64_t disk_write_bytes;
    uint64_t footprint_bytes;
} quik_proc_usage;

typedef struct {
    int ok;
    uint64_t read_bytes;
    uint64_t write_bytes;
    uint64_t busy_ns;
    uint32_t device_count;
} quik_disk_totals;

int quik_proc_usage_read(pid_t pid, quik_proc_usage *out);
int quik_disk_totals_read(quik_disk_totals *out);
int quik_list_pids(pid_t *out, int capacity);

#endif
