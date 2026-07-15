# WordPress Core Safe Updater

A safe Bash script for updating WordPress core files without WP-CLI, PHP execution, or automatic database upgrades.

## Features

- Downloads the latest official WordPress release
- Replaces `wp-admin` and `wp-includes`
- Replaces official WordPress root core files
- Preserves `wp-content`
- Preserves `wp-config.php`
- Preserves `.htaccess`
- Preserves `robots.txt`
- Preserves custom files
- Replaces `xmlrpc.php` with the latest official version
- Supports rollback on normal update failures
- Does not change the owner of the WordPress root directory
- Changes ownership only for newly installed core files
- Does not modify the WordPress database

## Usage

Check the script syntax:

```bash
bash -n wp-updater.sh
```

Run the updater as root:
```
bash wp-updater.sh /path/to/wordpress
```

Example:
```
bash wp-updater.sh /home/example/public_html/
```
## Preserved Items

The script does not modify:

wp-content/
wp-config.php
.htaccess
robots.txt
Custom files outside the official WordPress package
## Important

The database is not upgraded automatically. Always maintain a separate backup policy for production websites
