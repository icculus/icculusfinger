<?php
$arg = preg_replace('/\A\/finger\//', '', $_SERVER['REQUEST_URI']);
$arg = 'user=' . preg_replace('/\?/', '&', $arg);

putenv("SERVER_NAME=${_SERVER['SERVER_NAME']}");
putenv("QUERY_STRING=$arg");
putenv("GATEWAY_INTERFACE=1");
putenv("HTTP_USER_AGENT=${_SERVER['HTTP_USER_AGENT']}");
putenv("ICCULUSFINGER_ALTURL=1");

$io = popen('/webspace/icculus.org/finger/finger.pl', 'r');
if ($io === FALSE) {
    header('HTTP/1.0 500 Internal Server Error');
    header('Content-Type: text/plain; charset=UTF-8');
    print("Internal server error, try again later, please!\n");
    exit(0);
}

while (($line = fgets($io)) !== FALSE) {
    $line = preg_replace('/[\r\n]*\Z/', '', $line);
    if ($line == '')
        break;
    header($line);
}

fpassthru($io);

pclose($io);
exit(0);

?>
