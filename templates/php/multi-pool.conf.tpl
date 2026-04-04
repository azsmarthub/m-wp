; mwp — PHP-FPM pool for {{DOMAIN}}
; Generated: {{GENERATED_AT}}
; User: {{SITE_USER}}

[{{SITE_USER}}]
user  = {{SITE_USER}}
group = {{SITE_USER}}

listen = /run/php/php{{PHP_VERSION}}-fpm-{{SITE_USER}}.sock
listen.owner = {{SITE_USER}}
listen.group = www-data
listen.mode  = 0660

; Process management — ondemand saves RAM on idle sites
pm                   = ondemand
pm.max_children      = {{PM_MAX_CHILDREN}}
pm.process_idle_timeout = 30s
pm.max_requests      = 500

; Isolation — each site is sandboxed
php_admin_value[open_basedir]    = /home/{{SITE_USER}}:/tmp:/usr/share/php:/usr/share/wordpress
php_admin_value[upload_tmp_dir]  = /home/{{SITE_USER}}/tmp
php_admin_value[session.save_path] = /home/{{SITE_USER}}/tmp
php_admin_flag[disable_functions] = passthru,shell_exec,system,proc_open,popen,curl_multi_exec,parse_ini_file,show_source

; Logging
php_admin_value[error_log]       = /home/{{SITE_USER}}/logs/php-error.log
php_admin_flag[log_errors]       = on

; Limits
php_admin_value[memory_limit]     = {{PHP_MEMORY_LIMIT}}M
php_admin_value[upload_max_filesize] = 64M
php_admin_value[post_max_size]    = 64M
php_admin_value[max_execution_time] = 120
php_admin_value[max_input_time]   = 60
