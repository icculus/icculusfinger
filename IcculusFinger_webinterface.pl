#!/usr/bin/perl -w
#-----------------------------------------------------------------------------
#
#  Copyright (C) 2000 Ryan C. Gordon (icculus@icculus.org)
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307 USA
#
#-----------------------------------------------------------------------------

use strict;
use warnings;
use IO::Socket;

#-----------------------------------------------------------------------------#
#             CONFIGURATION VARIABLES: Change to suit your needs...           #
#-----------------------------------------------------------------------------#

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
my $rss = 0;
my $finger_query = 'web=1';
my $web_query = $ENV{QUERY_STRING};
$web_query = '' if (not defined $web_query);
chomp($web_query);

if ($web_query =~ s/(\?|&|\A)user=(.*?)(\Z|&)//) {
    $user = $2;
    $user =~ tr/A-Z/a-z/;
}

if ((not defined $ENV{GATEWAY_INTERFACE}) or ($ENV{GATEWAY_INTERFACE} eq '')) {
    print("\n\nThis is a cgi-bin script. Please treat it accordingly.\n\n");
    exit 0;
}

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

if ($web_query =~ /(\A|\?|&)rss=/) {
    $rss = 1;
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

        if ($rss) {
            print("Content-type: application/rss+xml; charset=UTF-8\n\n");
        } else {
            print("Content-type: text/html; charset=UTF-8\n\n");
        }

        while (<$remote>) {
            print $_;
        }
        close($remote);
    }
}

if (defined $errormsg) {
    print("Content-type: text/html; charset=UTF-8\n\n");
    print("<html><head><title>Problem</title></head><body>\n");
    print("<center><h1>$errormsg</h1></center>\n");
    print("</body></html>\n");
    print("\n");
    exit 0;
}

exit 0;

# end of IcculusFinger_webinterface.pl ...

