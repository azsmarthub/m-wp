; mwp PHP-FPM pool — phpMyAdmin (mwp-pma)
; Generated: {{GENERATED_AT}}
;
; Dedicated pool isolated from any site:
;   - runs as `mwp-pma` (separate from www-data and any site user)
;   - open_basedir restricts file access to pma's own dirs (cannot read /home or /etc/mwp/sites)
;   - link files at /etc/mwp/pma-links are read by the router under this pool's user

[mwp-pma]
user = mwp-pma
group = mwp-pma
listen = /run/php/mwp-pma.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = ondemand
pm.max_children = 4
pm.process_idle_timeout = 60s
request_terminate_timeout = 300

php_admin_value[open_basedir] = /usr/share/phpmyadmin:/var/lib/phpmyadmin:/etc/phpmyadmin:/etc/mwp/pma-links:/usr/share/php:/tmp
php_admin_value[upload_max_filesize] = 256M
php_admin_value[post_max_size] = 256M
php_admin_value[max_execution_time] = 300
php_admin_value[memory_limit] = 256M
php_admin_value[session.save_path] = /var/lib/phpmyadmin/tmp
