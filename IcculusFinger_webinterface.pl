#!/usr/bin/perl -w

use strict;
use warnings;
use IO::Socket;

# Define which host(s) the finger request goes to. If $host == false,
#  then users may finger any system on the Internet by specifying a hostname:
#  user=dimwit@doofus.com, for example. Not setting $host at all like that
#  could leave a mild exploit available.
#my $host = undef;    # Makes this script work as a web interface to finger.
#my $host = "icculus.org";  # limit queries to users @icculus.org
my $host = $ENV{SERVER_NAME};  # This is good for VirtualHost setups.


#-----------------------------------------------------------------------------#
#     The rest is probably okay without you laying yer dirty mits on it.      #
#-----------------------------------------------------------------------------#


# Mainline.

$host =~ tr/A-Z/a-z/ if defined $host;

my $user = '';
my $finger_query = 'web=1';
my $web_query = $ENV{QUERY_STRING};
$web_query = '' if (not defined $web_query);
chomp($web_query);

if ($web_query =~ s/user=(.*?)(\Z|&)//) {
    $user = $1;
    $user =~ tr/A-Z/a-z/;
}

if ((not defined $ENV{GATEWAY_INTERFACE}) or ($ENV{GATEWAY_INTERFACE} eq '')) {
    print("\n\nThis is a cgi-bin script. Please treat it accordingly.\n\n");
    exit 0;
}

print("Content-type: text/html\n\n\n");

if ((defined $ENV{HTTP_USER_AGENT}) and ($ENV{HTTP_USER_AGENT} ne "")) {
    if (not $web_query =~ /(\A|\?|&)browser=/) {
        my $browser = $ENV{HTTP_USER_AGENT};
        1 while ($browser =~ s/&//);
        $finger_query .= "&browser=$browser";
    }
}

if (not $web_query =~ /(\A|\?|&)html=/) {
    $finger_query .= "&html=1";
}

my $requested_host = undef;
if ($user =~ s/\@(.*)//) {
    $requested_host = $1;
}

$web_query .= '&' if ($web_query ne '');
$finger_query = "$user?$web_query$finger_query";

my $errormsg = undef;
if ($user eq '') {
    $errormsg = "No user specified.";
} elsif ((not defined $host) and (not defined $requested_host)) {
    $errormsg = "No host specified.";
} elsif ((defined $host) and (defined $requested_host)) {
    if ($host ne $requested_host) {
        $errormsg = "You aren't permitted to specify a hostname, just a user.";
    }
} else {
    $host = $requested_host if not defined $host;
    my $remote = IO::Socket::INET->new(
                                       Proto    => "tcp",
                                       PeerAddr => $host,
                                       PeerPort => "finger"
                                      );

    if (not $remote) {
        $errormsg = "cannot connect to finger daemon on $host";
    } else {
        $remote->autoflush(1);
        print $remote "$finger_query\015\012";
        while (<$remote>) {
            print $_;
        }
        close($remote);
    }
}

if (defined $errormsg) {
    print("<html><head><title>Problem</title></head><body>\n");
    print("<center><h1>$errormsg</h1></center>\n");
    print("</body></html>\n");
    print("\n");
    exit 0;
}

exit 0;

# end of IcculusFinger_webinterface.pl ...

