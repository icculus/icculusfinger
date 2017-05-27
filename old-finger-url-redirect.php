<?php
$vhost = isset($_SERVER['SERVER_NAME']) ? $_SERVER['SERVER_NAME'] : 'icculus.org';
$user = isset($_REQUEST['user']) ? $_REQUEST['user'] : '';

$args = '';
if (isset($_REQUEST) && (count($_REQUEST) > 0)) {
    $ch = '?';
    foreach ($_REQUEST as $key => $val) {
        if ($key == 'user') {
            continue;
        }
        $args .= "$ch$key=$val";
        $ch = '&';
    }
}

$url = "https://$vhost/finger/$user$args";
header("Location: $url", true, 301);
print("<html><head><title>Moved Permanently</title></head><body><center>\nThis URL has moved to <a href='$url'>\n\n$url\n\n</a></center></body></html>\n");
exit(0);
?>
