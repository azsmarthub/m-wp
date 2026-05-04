# mwp PostgreSQL tuning — auto-calculated from RAM={{RAM_MB}}MB, CPU={{CPU_CORES}}
# Generated: {{GENERATED_AT}}
# Drop-in conf — overrides /etc/postgresql/{{PG_VERSION}}/main/postgresql.conf
# Re-generate via: mwp pg tune

# ── Memory ─────────────────────────────────────────────────────────────────
shared_buffers = {{SHARED_BUFFERS_MB}}MB              # ~25% of RAM
effective_cache_size = {{EFFECTIVE_CACHE_MB}}MB       # ~75% of RAM (OS+pg cache estimate)
work_mem = {{WORK_MEM_MB}}MB                          # per-operation, per-conn
maintenance_work_mem = {{MAINT_WORK_MEM_MB}}MB        # VACUUM / CREATE INDEX
wal_buffers = -1                                       # auto = 1/32 of shared_buffers

# ── Connections ────────────────────────────────────────────────────────────
max_connections = {{MAX_CONNECTIONS}}
listen_addresses = '*'                                 # UFW + pg_hba gate access
                                                       # (see /etc/postgresql/{{PG_VERSION}}/main/pg_hba.conf)

# ── Storage / I/O (SSD assumptions) ────────────────────────────────────────
random_page_cost = 1.1                                 # vs 4 for spinning
effective_io_concurrency = 200                         # NVMe / SSD
checkpoint_completion_target = 0.9
default_statistics_target = 100

# ── Parallelism ────────────────────────────────────────────────────────────
max_worker_processes = {{CPU_CORES}}
max_parallel_workers = {{CPU_CORES}}
max_parallel_workers_per_gather = {{PARALLEL_GATHER}}

# ── WAL / durability ───────────────────────────────────────────────────────
wal_compression = on
synchronous_commit = on                                # safe default; flip to off for higher write throughput w/ data-loss risk

# ── Logging (lean — avoid flooding /var/log) ───────────────────────────────
log_min_duration_statement = 1000                      # log queries > 1s
log_checkpoints = on
log_lock_waits = on
log_temp_files = 10MB
