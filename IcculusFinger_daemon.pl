#!/usr/bin/perl -w -T
#-----------------------------------------------------------------------------
#
#  Copyright (C) 2002 Ryan C. Gordon (icculus@icculus.org)
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

#-----------------------------------------------------------------------------
# Revision history:
#  (1.0 series comments removed. Check the download archives if you need them.)
#  2.0.0 : Rewrite into an actual finger daemon. MILLIONS of changes.
#  2.0.1 : Fixed &gt; and &lt; conversion.
#          MUCH better Lynx support (thanks, Chunky_Ks)
#          Added an "embed" arg.
#          changed \r and \n in protocol chatter to \015 and \012.
#          Made syslogging optional.
#          Added "root" as a fakeuser.
#  2.0.2 : Added "time" and "ipaddr" fakeusers.
#  2.0.3 : Added "linkdigest" arg, and made it the default for text output.
#  2.0.4 : Added "noarchive" tagblocks and optional "plan written on"
#          date/time output.
#  2.0.5 : Can now run as a full daemon, without inetd. Bunch of secutity
#          cleanups, and enables taint mode (-T). Input can now timeout, so
#          connections can't be hogged indefinitely anymore.
#  2.0.6 : Some syslogging added, minor fix in input reading.
#          Zombie processes are cleaned up reliably, even under heavy load.
#  2.1.0 : Added .planfile digest generation. Not hooked up to daemon yet,
#          just works from the command line. (Thanks to Gary "Chunky Kibbles"
#          Briggs for the suggestion and patches!)
#  2.1.1 : Disabled the email URLizer for now. Added an "uptime" fakeuser.
#  2.1.2 : Centering, based on 80 columns, in text output, digest is now
#          sorted correctly. (Thanks, Gary!) Daemon now select()s on the
#          listen socket so it can timeout and do the .planfile digest. Other
#          cleanups and fixes in the daemon code.
#  2.1.3 : Make sure .plan digest doesn't skips users with identical update
#          times.
#  2.1.4 : Moved plan digest hashing to separate function (hashplans()),
#          added RSS digest (thanks, zakk!), and unified them in do_digests().
#          Digests can have a maximum user output now.
#  2.1.5 : Fixes from Gary Briggs: Fixed a regexp, made line before ending
#          text format better, fixed centering on Lynx.
#  2.1.6 : Fix from Gary Briggs: undef'd variable reference.
#  2.1.7 : Fix from Gary Briggs: do some text output for [i], [b], and [u]
#          markup tags when not in HTML mode.
#  2.1.8 : Fix from Gary Briggs: IcculusFinger_planmove.pl now handles
#          moves across filesystems.
#  2.1.9 : Security fixes in request parsing and syslog output by Chunky and
#          Primer.
#  2.1.10: Changes by Gary Briggs: Added local file parsing for specific
#          situations, made image text more useful. Added support for
#          stylesheets, and [entry][/entry] tags
#-----------------------------------------------------------------------------

# !!! TODO: Let [img] tags nest inside [link] tags.


use strict;          # don't touch this line, nootch.
use warnings;        # don't touch this line, either.
use DBI;             # or this. I guess. Maybe.
use File::Basename;  # blow.
use IO::Select;      # bleh.

# Version of IcculusFinger. Change this if you are forking the code.
my $version = "v2.1.10";


#-----------------------------------------------------------------------------#
#             CONFIGURATION VARIABLES: Change to suit your needs...           #
#-----------------------------------------------------------------------------#

# This is a the hostname you want to claim to be...
#  This reports "Finger info for $user\@$host ..." in the web interface,
#  and is used for listing finger requests to finger clients:
#   "Finger $user?section=sectionname\@$host", etc.
my $host = 'icculus.org';

# This is the URL for fingering accounts, for when we need to generate
#  URLs. "$url?user=$user&section=sectionname".
my $base_url = 'http://icculus.org/cgi-bin/finger/finger.pl';

# The processes path is replaced with this string, for security reasons, and
#  to satisfy the requirements of Taint mode. Make this as simple as possible.
#  Currently, the only thing that uses the PATH environment var is the
#  "fortune" fakeuser, which can be safely removed.
my $safe_path = '/usr/bin:/usr/local/bin';

# Turn the process into a daemon. This will handle creating/answering socket
#  connections, and forking off children to handle them. This flag can be
#  toggled via command line options (--daemonize, --no-daemonize, -d), but
#  this sets the default. Daemonizing tends to speed up processing (since the
#  script stays loaded/compiled), but may cause problems on systems that
#  don't have a functional fork() or IO::Socket::INET package. If you don't
#  daemonize, this program reads requests from stdin and writes results to
#  stdout, which makes it suitable for command line use or execution from
#  inetd and equivalents.
my $daemonize = 0;

# This is only used when daemonized. Specify the port on which to listen for
#  incoming connections. The RFC standard finger port is 79.
my $server_port = 79;

# Set this to immediately drop priveledges by setting uid and gid to these
#  values. Set to undef to not attempt to drop privs. You will probably need
#  to leave these as undef and run as root (risky!) if you plan to enable
#  $the use_homedir variable, below.
#my $wanted_uid = undef;
#my $wanted_gid = undef;
my $wanted_uid = 1056;  # (This is the uid of "finger" ON _MY_ SYSTEM.)
my $wanted_gid = 971;   # (This is the gid of "iccfinger" ON _MY_ SYSTEM.)

# This is only used when daemonized. Specify the maximum number of finger
#  requests to service at once. A separate child process is fork()ed off for
#  each request, and if there are more requests then this value, the extra
#  clients will be made to wait until some of the current requests are
#  serviced. 5 to 10 is usually a good number. Set it higher if you get a
#  massive amount of finger requests simultaneously.
my $max_connects = 10;

# This is how long, in seconds, before an idle connection will be summarily
#  dropped. This prevents abuse from people hogging a connection without
#  actually sending a request, without this, enough connections like this
#  will block legitimate ones. At worst, they can only block for this long
#  before being booted and thus freeing their connection slot for the next
#  guy in line. Setting this to undef lets people sit forever, but removes
#  reliance on the IO::Select package. Note that this timeout is how long
#  the user has to complete the read_request() function, so don't set it so
#  low that legitimate lag can kill them. The default is usually safe.
my $read_timeout = 15;

# Set this to non-zero to log all finger requests via the standard Unix
#  syslog facility (requires Sys::Syslog qw(:DEFAULT setlogsock) ...)
my $use_syslog = 1;

# Set $use_homedir to something nonzero if want to read planfiles from the
#  standard Unix location ("/home/$user/.plan"). Note that this is a security
#  hole, as it means that either IcculusFinger must run as root to insure
#  access to a user's homedir, or user's have to surrender a little more
#  privacy to give a non-root user access to their homedirs. You should
#  consider setting this to zero and reading the comments for $fingerspace,
#  below. Note that IcculusFinger comes with a perl script for automating the
#  moving of a system's planfiles from the the insecure method to the more
#  secure $fingerspace method, including creating the symlinks so your users
#  won't really notice a difference.
my $use_homedir = 0;

# Set $files_allowed to allow someone to use a filename instead of a
#  username. If you then ask for something of the form "./filename"
#  it'll open the file instead of the user's .plan.
# Without good reason the correct setting for this option is 0, and
#  anything other than a specific file in the current dir will fail to
#  work properly
my $files_allowed = 0;

# If you set $use_homedir to 0, this is the directory that contains the
#  planfiles in the format "$fingerdir$username" Note that THIS MUST HAVE
#  THE TRAILING DIR SEPARATOR! This is ignored if $use_homedir is NOT zero.
my $fingerspace = '/fingerspace/';

# This is the maximum amount of data that IcculusFinger will read from a
#  planfile. If this cuts off in the middle of an opened formatting tag,
#  tough luck. IcculusFinger reads the entire planfile (up to the max you
#  specify here) into memory before processing tags. Theoretically, this could
#  be changed to handle tags on the fly, in which case users that would
#  otherwise be over the limit might not be after processing sections, etc,
#  but this is not the case here and now.
#  Note that images specified inside [img] tags, etc are not counted towards
#  this limit (since the web browser would be requesting those images
#  separately), and only applies to the max bytes to be read directly from the
#  planfile. This is merely here to prevent someone from symlinking their
#  planfile to /dev/zero or something that could fill all available memory.
#  This value is specified in bytes.
my $max_plan_size = (100 * 1024);

# This is the maximum size, in bytes, that a finger request can be. This is
#  to prevent malicious finger clients from trying to fill all of system
#  memory.
my $max_request_size = 512;

# This is what is reported to the finger client if the desired user's planfile
#  is missing or empty, or the user is unknown (we make NO distinction, for
#  the sake of security and privacy). This string can use IcculusFinger
#  markup tags (we'll convert as appropriate), but must NOT use HTML directly,
#  since it will confuse the regular finger client users. You should not
#  leave this blank or undef it, since that's confusing for everyone.
my $no_report_string = "[center][i]Nothing to report.[/i][/center]";

# List at the bottom of the finger output (above wittyremark) when the .plan
#  was last updated?
my $show_revision_date = 1;

# This is the default title for the webpage. The user can override it with
#  the [title] tag in their .plan file. Do not use HTML. You can specify an
#  empty string (""), but not undef; however, you should REALLY have a
#  default here...
my $title = "IcculusFinger $version";

# Alternately, you can populate this array with strings, and IcculusFinger
#  will randomly pick one at runtime. Note that the user's [title] tags also
#  land in here, so you are interfering with their ability to override the
#  title if you add to this array. The $title variable above is used only if
#  this array is empty, and thus gives you a comfortable default in case the
#  user doesn't supply her own title. Do as you will.
my @title_array;

# If you are a content-Nazi, you can prevent the user's [title] tags from
#  being included in the parsing.
my $permit_user_titles = 1;

# If this array is empty, then no stylesheet is used unless a user
#  specifies one and you're not a content Nazi. You can populate this
#  if you wish.
my @style_array;
# Don't populate this.
my $style = "";

# If you are a content-Nazi, you can prevent the user's [style] tags from
#  being included in the parsing.
my $permit_user_styles = 1;

# This is printed after the credits at the bottom. Change it to whatever you
#  like. Do not use HTML. You can specify an empty string (""), but undef
#  doesn't fly here. The user can change this with [wittyremark] tags.
my $wittyremark = "Stick it in the camel and go.";

# Alternately, you can populate this array with strings, and IcculusFinger
#  will randomly pick one at runtime. Note that the user's [wittyremark] tags
#  also land in here, so you are interfering with their ability to override
#  if you add to this array. The $wittyremark variable above is used only if
#  this array is empty, and thus gives you a comfortable default in case the
#  user doesn't supply her own content. Do as you will.
my @wittyremark_array;

# If you are a content-Nazi, you can prevent the user's [wittyremark] tags
#  from being included in the parsing.
my $permit_user_wittyremarks = 1;

# You can screw up your output with this, if you like.
# You can append "?debug=1" to your finger request to enable this without
# changing the source.
my $debug = 0;

# This is the URL to where the script can be obtained. Feel free to change
#  it if you you are forking the code, but unless you've got a good reason,
#  I'd appreciate it if you'd leave my (ahem) official IcculusFinger webpage
#  in this variable. Set it to undef to not supply a link at all in the
#  final HTML output.
#my $scripturl = undef;
#my $scripturl = "/misc/finger.pl";
my $scripturl = "http://icculus.org/IcculusFinger/";

# This is only used in the HTML-formatted output.
# I'd prefer you leave this be, but change it if you must.
my $html_credits = (defined $scripturl) ?
              "Powered by <a href=\"$scripturl\">IcculusFinger $version</a>" :
              "Powered by IcculusFinger $version" ;

# This is only used in the plaintext-formatted output.
# I'd prefer you leave this be, but change it if you must.
my $text_credits = "Powered by IcculusFinger $version" .
                    ((defined $scripturl) ? " ($scripturl)" : "");


# Set this to zero to disable planfile archive lookups.
my $use_database = 1;

# This is the host to connect to for database access.
my $dbhost = 'localhost';

# This is the username for the database connection.
my $dbuser = 'fingermgr';

# The database password can be entered in three ways: Either hardcode it into
#  $dbpass, (which is a security risk, but is faster if you have a completely
#  closed system), or leave $dbpass set to undef, in which case this script
#  will try to read the password from the file specified in $dbpassfile (which
#  means that this script and the database can be touched by anyone with read
#  access to that file), or leave both undef to have DBI get the password from
#  the DBI_PASS environment variable, which is the most secure, but least
#  convenient.
my $dbpass = undef;
my $dbpassfile = '/etc/IcculusFinger_dbpass.txt';

# The name of the database to use once connected to the database server.
my $dbname = 'IcculusFinger';

# The name of the table inside the database we're using.
my $dbtable_archive = 'finger_archive';

# This is the time, in minutes, to generate a digest webpage of all available
#  finger accounts. The digest includes last updated time and a link to the
#  web version of the .plan files. Set this to undef to disable this feature.
#  Also, this only runs if we're daemonized (--daemonize commandline option).
#  If you aren't daemonized, you can force a digest update by running
#  this program from the command line with the --digest option...probably from
#  a cronjob.
my $digest_frequency = 10;

# Digests (html and rss) will show at most $digest_max_users plans, newest
#  listed first. Five to ten is probably a good idea. undef to list all
#  non-empty .planfiles.
#my $digest_max_users = undef;
my $digest_max_users = 10;

# Filename to write finger digest to. "undef" will universally disable digest
#  generation, from the daemon or command line. Note that this file is opened
#  for writing _AFTER_ the program drops privileges, whether you run this from
#  the command line or as a daemon.
my $digest_filename = '/webspace/icculus.org/fingerdigest.html';

# Filename to write finger digest RSS to, "undef" will universally
# disable RSS digest generation, from the daemon or the command line. See
# other notes above.
my $digest_rss_filename = '/webspace/icculus.org/fingerdigest.rss';

# Set this to a string you want to prepend to the finger digest. If you
#  aren't planning to include the digest in another webpage via PHP or
#  whatnot, you should put <html> and <title> tags, etc here. "undef" is
#  safe, too.
#my $digest_prepend = undef;
my $digest_prepend = "<html><head><title>.plan digest</title></head><body>\n";

# Set this to a url you want to set the about to
# for the finger digest RSS about field. Et cetera.
my $digest_rss_about = "http://icculus.org/fingerdigest.rdf";

# Set this to a title you want for the RSS
my $digest_rss_title = "icculus.org finger digest";

# Set this to the link you want for the finger digest (note that this
# relates to the RSS file linking to the actual piece of html, not
# itself)
my $digest_rss_url = "http://icculus.org/fingerdigest.html";

# Set this to the description for the RSS
my $digest_rss_desc = "finger updates from icculus.org users";

# Set this to the url for the RSS image
my $digest_rss_image = "http://icculus.org/icculus-org-now.png";

# Set this to a string you want to append to the finger digest. If you
#  aren't planning to include the digest in another webpage via PHP or
#  whatnot, you should put <html> and <title> tags, etc here. "undef" is
#  safe, too.
#my $digest_append = undef;
my $digest_append = "</body></html>\n";

# These are special finger accounts; when a user queries for this fake
#  user, we hand back the string returned from the attached function as if
#  it was the contents of a planfile. Be careful with this, as it opens up
#  potential security holes.
# These subs do NOT have a maximum size limit imposed by the
#  $max_plan_size setting, above.
# This hash is checked before actual planfiles, so you can override an
#  existing user through this mechanism.
my %fakeusers;  # the hash has to exist; don't comment this line.

# The elements of the hash, however, can be added and removed at your whim.

$fakeusers{'fortune'} = sub {
    return(`/usr/games/fortune`);
};

$fakeusers{'uptime'} = sub {
    my $uptime = `/usr/bin/uptime`;
    $uptime =~ s/\A.*?(up \d+ days, \d+:\d+),.*\Z/$1/;
    return('[center]' . $uptime . '[/center]');
};

$fakeusers{'root'} = sub {
    return("ph34r me, for i am root. I'm l33t as kittens.");
};

$fakeusers{'time'} = sub {
    return("At the sound of the beep, it will be: " . scalar localtime() .
           "\012\012\012\012    ...[u][b][i]BEEP.[/i][/b][/u]");
};

#$fakeusers{'admin-forcedigest'} = sub {
#    do_digests();
#    return('Digest dumped, nootch.');
#};


# This works if run from qmail's tcp-env, and not tcpd.
#  also note that this is pretty useless for hits through the web
#  interface, since the webserver's IP will be reported, not the
#  browser's IP.
$fakeusers{'ipaddr'} = sub {
    if (defined $ENV{'TCPREMOTEIP'}) {
        return("Your IP address appears to be $ENV{'TCPREMOTEIP'}");
    } else {
        return(undef);
    }
};

#-----------------------------------------------------------------------------#
#     The rest is probably okay without you laying yer dirty mits on it.      #
#-----------------------------------------------------------------------------#

my $is_web_interface = 0;
my $do_html_formatting = 0;
my $browser = "";
my $wanted_section = undef;
my $output_text = "";
my $archive_date = undef;
my $archive_time = undef;
my $list_sections = 0;
my $list_archives = 0;
my $embed = 0;
my $do_link_digest = undef;
my $next_plan_digest = 0;


sub get_sqldate {
    my $mtime = shift;
    my @t = localtime($mtime);
    $t[5] = "0000" . ($t[5] + 1900);
    $t[5] =~ s/.*?(\d\d\d\d)\Z/$1/;
    $t[4] = "00" . ($t[4] + 1);
    $t[4] =~ s/.*?(\d\d)\Z/$1/;
    $t[3] = "00" . $t[3];
    $t[3] =~ s/.*?(\d\d)\Z/$1/;
    $t[2] = "00" . $t[2];
    $t[2] =~ s/.*?(\d\d)\Z/$1/;
    $t[1] = "00" . $t[1];
    $t[1] =~ s/.*?(\d\d)\Z/$1/;
    $t[0] = "00" . $t[0];
    $t[0] =~ s/.*?(\d\d)\Z/$1/;

    return('' . ($t[5]) . '-' . ($t[4]) . '-' . ($t[3]) . ' ' .
                ($t[2]) . ':' . ($t[1]) . ':' . ($t[0]));
}


sub get_minimal_sqldate {
    my $mtime = shift;
    my @t = localtime($mtime);
    $t[4] = "00" . ($t[4] + 1);
    $t[4] =~ s/.*?(\d\d)\Z/$1/;
    $t[3] = "00" . $t[3];
    $t[3] =~ s/.*?(\d\d)\Z/$1/;

    return('' . ($t[4]) . '/' . ($t[3]) );
}


sub enumerate_planfiles {
    my $dirname = (($use_homedir) ? '/home' : $fingerspace);
    opendir(DIRH, $dirname) or return(undef);
    my @dirents = readdir(DIRH);
    closedir(DIRH);

    my @retval;

    if ($use_homedir) {
        foreach (@dirents) {
            next if (($_ eq '.') or ($_ eq '..'));
            push @retval, "/home/$_/.plan";
        }
    } else {
        foreach (@dirents) {
            next if (($_ eq '.') or ($_ eq '..'));
            push @retval, "$fingerspace/$_";
        }
    }

    return(@retval);
}


sub hashplans {
    my %retval;

    my @plans = enumerate_planfiles();
    if (not @plans) {
        syslog("info", "Failed to enumerate planfiles: $!\n") if ($use_syslog);
        return(undef);
    }

    foreach (@plans) {
        my $user = $_;
        if ($use_homedir) {
            $user =~ s#\A/home/(.*?)/\.plan\Z#$1#;
        } else {
            $user = basename($_);
        }

        my @statbuf = stat($_);
        my $filesize = $statbuf[7];
        next if ($filesize <= 0);  # Skip empty .plans

        # construct the hash backward for easy
        #    sorting-by-time in the next loop
        my $t = $statbuf[9];
        $t++ while defined $retval{$t};
        $retval{$t} = $user;
    }

    return(%retval);
}


sub do_digest {
    return if not defined $digest_filename;

    my %plansdates = hashplans();
    return if (not %plansdates);

    if (not open DIGESTH, '>', $digest_filename) {
        if ($use_syslog) {
            syslog("info", "digest: failed to open $digest_filename: $!\n");
        }
        return;
    }

    print DIGESTH $digest_prepend if defined $digest_prepend;
    print DIGESTH "\n<p>\n ";

    print DIGESTH "<table border=0>\n";

    my $x = 0;
    foreach (reverse sort keys %plansdates) {
        my $user = $plansdates{$_};
        my $modtime = get_minimal_sqldate($_);
        my $href = "href=\"$base_url?user=$user\"";
        print DIGESTH " <tr>\n";
        print DIGESTH "  <td align=\"right\"><a $href>$user</a></td>\n";
        print DIGESTH "  <td>$modtime</td>\n";
        print DIGESTH " </tr>\n";

        last if ((defined $digest_max_users) and (++$x >= $digest_max_users));
    }

    print DIGESTH "  </table>\n</p>\n";
    print DIGESTH $digest_append if defined $digest_append;
    close(DIGESTH);
}


sub do_rss_digest {
    return if not defined $digest_rss_filename;

    my %plansdates = hashplans();
    return if (not %plansdates);

    if (not open RSS_DIGESTH, '>', $digest_rss_filename) {
        if ($use_syslog) {
            syslog("info", "digest: failed to open $digest_rss_filename: $!\n");
        }
        return;
    }

    print RSS_DIGESTH <<__EOF__;

<?xml version="1.0" encoding="utf-8"?>
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
         xmlns="http://purl.org/rss/1.0/">

  <channel rdf:about="$digest_rss_about">
    <title>$digest_rss_title</title>
    <link>$digest_rss_url</link>
    <description>$digest_rss_desc</description>
  </channel>

  <image>
    <title>$digest_rss_title</title>
    <url>$digest_rss_image</url>
    <link>$digest_rss_url</link>
  </image>

__EOF__

    my $x = 0;
    foreach (reverse sort keys %plansdates) {
        my $user = $plansdates{$_};
        my $modtime = get_minimal_sqldate($_);
        my $href = "$base_url?user=$user";
        print RSS_DIGESTH "  <item rdf:about=\"$href\">\n";
        print RSS_DIGESTH "    <title>$user - $modtime</title>\n";
        print RSS_DIGESTH "    <link>$href</link>\n";
        print RSS_DIGESTH "  </item>\n\n";

        last if ((defined $digest_max_users) and (++$x >= $digest_max_users));
    }

    print RSS_DIGESTH "</rdf:RDF>\n\n";
    close(RSS_DIGESTH);
}


my $did_output_start = 0;
sub output_start {
    my ($user, $host) = @_;
    return if ((not $is_web_interface) and (not $do_html_formatting));
    return if $did_output_start;

    $did_output_start = 1;

    print <<__EOF__ if not $embed;

<html>
  <head>
    <title> $title </title>
__EOF__

	print "<link rel=\"stylesheet\" href=\"$style\"
		type=\"text/css\">" if(defined $style && length($style) > 0);

    print <<__EOF__ if not $embed;
  </head>

  <body>
   <div class="top">
     <center><h1>Finger info for $user\@$host...</h1></center>
   </div>
   <hr>
 
   <div class="content">

__EOF__
    print "\n<pre>\n" if ($browser !~ /Lynx/);
}


sub output_ending {

    if (($is_web_interface) or ($do_html_formatting) and ($browser !~ /Lynx/)) {
        print("    </pre>\n");
    }

	print("</div>\n");

    return if $embed;

    my $revision = undef;
    if (($show_revision_date) and (defined $archive_date)) {
        $revision = "When this .plan was written: $archive_date";
    }

    if ($do_html_formatting) {
        $revision = ((defined $revision) ? "$revision<br>\n" : '');

        print <<__EOF__;
    <div class="bottom">
    <hr>
    <center>
      <font size="-3">
        $revision
        $html_credits<br>
        <i>$wittyremark</i>
      </font>
    </center>
	</div>
__EOF__

    } else {
	$revision = ((defined $revision) ? "$revision\n" : '');
	# Perl has no builtin max
	my $maxlength = length($revision);
	$maxlength = length($text_credits) if(length($text_credits)>$maxlength);
	$maxlength = length($wittyremark) if(length($wittyremark)>$maxlength);
        print "-" x $maxlength . "\n";
        print "$revision\n" if (defined $revision);
        print "$text_credits\n";
        print "$wittyremark\n\n";
    }

    if (($is_web_interface) or ($do_html_formatting)) {
        print("  </body>\n");
        print("</html>\n");
        print("\n");
    }
}

sub parse_args {
    my $args = shift;
    if ((defined $args) and ($args ne '')) {
        $args =~ s/\A\?//;

        if ($args =~ s/(\A|&)web=(.*?)(&|\Z)/$1/) {
            $is_web_interface = $2;
        }

        if ($args =~ s/(\A|&)html=(.*?)(&|\Z)/$1/) {
            $do_html_formatting = $2;
        }

        if ($args =~ s/(\A|&)browser=(.*?)(&|\Z)/$1/) {
            $browser = $2;
        }

        if ($args =~ s/(\A|&)debug=(.*?)(&|\Z)/$1/) {
            $debug = $2;
        }

        if ($args =~ s/(\A|&)section=(.*?)(&|\Z)/$1/) {
            $wanted_section = $2;
            $wanted_section =~ tr/A-Z/a-z/;
        }

        if ($args =~ s/(\A|&)date=(.*?)(&|\Z)/$1/) {
            $archive_date = $2;
        }

        if ($args =~ s/(\A|&)time=(.*?)(&|\Z)/$1/) {
            $archive_time = $2;
        }

        if ($args =~ s/(\A|&)listsections=(.*?)(&|\Z)/$1/) {
            $list_sections = $2;
        }

        if ($args =~ s/(\A|&)listarchives=(.*?)(&|\Z)/$1/) {
            $list_archives = $2;
        }

        if ($args =~ s/(\A|&)embed=(.*?)(&|\Z)/$1/) {
            $embed = $2;
        }

        if ($args =~ s/(\A|&)linkdigest=(.*?)(&|\Z)/$1/) {
            $do_link_digest = $2;
        }
    }

    # default behaviours that depend on output target...
    $do_link_digest = !$do_html_formatting if (not defined $do_link_digest);

    return($args);
}


sub get_database_link {
    if (not defined $dbpass) {
        if (defined $dbpassfile) {
            open(FH, $dbpassfile) or return("failed to open $dbpassfile: $!\n");
            $dbpass = <FH>;
            chomp($dbpass);
            $dbpass =~ s/\A\s*//;
            $dbpass =~ s/\s*\Z//;
            close(FH);
        }
    }

    my $dsn = "DBI:mysql:database=$dbname;host=$dbhost";
    $_[0] = DBI->connect($dsn, $dbuser, $dbpass) or
                  return(DBI::errstr);
    return(undef);
}


sub load_archive_list {
    my $user = shift;
    my $link;
    my $err = get_database_link($link);
    return($err) if defined $err;

    my $u = $link->quote($user);
    my $sql = "select postdate from $dbtable_archive where username=$u" .
              " order by postdate desc";
    my $sth = $link->prepare($sql);
    if (not $sth->execute()) {
        $link->disconnect();
        return "can't execute the query: $sth->errstr";
    }

    my @archivelist;
    while (my @row = $sth->fetchrow_array()) {
        push @archivelist, $row[0];
    }

    if ($#archivelist < 0) {
        $output_text = '';  # will use $no_report_string.
    } else {
        $output_text = "Available archives:\n";
        foreach (@archivelist) {
            my ($d, $t) = /(\d\d\d\d-\d\d-\d\d) (\d\d:\d\d:\d\d)/;
            $t =~ s/(..):(..):(..)/$1-$2-$3/;
            if ($do_html_formatting) {
                my $url = "$base_url?user=$user&date=$d&time=$t";
                $output_text .= "  \[link=\"$url\"\]$_\[/link\]\n";
            } else {
                $output_text .= "  finger $user\@$host?&date=$d&time=$t\n";
            }
        }
    }

    $sth->finish();
    $link->disconnect();
    return(undef);
}


sub load_archive {
    my $user = shift;

    my $sqldate;
    if (defined $archive_date) {
        if ($archive_date =~ /\A\d\d\d\d-\d\d-\d\d\Z/) {
            $sqldate = $archive_date;
        } else {
            return("Archive date must be in yyyy-mm-dd format.");
        }
    } else {
        my @t = localtime(time());
        $t[5] = "0000" . ($t[5] + 1900);
        $t[5] =~ s/.*?(\d\d\d\d)\Z/$1/;
        $t[4] = "00" . ($t[4] + 1);
        $t[4] =~ s/.*?(\d\d)\Z/$1/;
        $t[3] = "00" . $t[3];
        $t[3] =~ s/.*?(\d\d)\Z/$1/;

        $sqldate = '' . ($t[5]) . '-' . ($t[4]) . '-' . ($t[3]);
    }

    if (defined $archive_time) {
        if ($archive_time =~ /\A(\d\d)-(\d\d)-(\d\d)\Z/) {
            $sqldate .= " $1:$2:$3";
        } else {
            return("Archive date must be in hh-mm-ss format.");
        }
    } else {
        $sqldate .= " 23:59:59";  # end of day.
    }

    my $link;
    my $err = get_database_link($link);
    return($err) if defined $err;

    my $u = $link->quote($user);
    my $sql = "select postdate, text from $dbtable_archive where username=$u" .
              " and postdate<='$sqldate' order by postdate desc limit 1";
    my $sth = $link->prepare($sql);
    if (not $sth->execute()) {
        $link->disconnect();
        return "can't execute the query: $sth->errstr";
    }

    my @row = $sth->fetchrow_array();
    if (not @row) {
        $output_text = '';  # will use $no_report_string.
    } else {
        $row[1] =~ s/(\A.{0, $max_plan_size}).*\Z/$1/s;
        $archive_date = $row[0];
        $output_text = $row[1];
    }
    $sth->finish();

    $link->disconnect();
    return(undef);
}


sub load_file {
    my $user = shift;
    my $fname;
    my $errormsg = undef;

    if($files_allowed==1 && $user =~ /^\.\/[^\/]*$/) {
        $fname = $user;
    } else {
        $fname = ($use_homedir) ? "/home/$user/.plan" : "$fingerspace/$user";
    }

    if (not -f "$fname") {  # this is NOT an error.
        $output_text = "";
    } else {
        my $modtime = (stat($fname))[9];
        if (not open(FINGER, '<', "$fname")) {
            $errormsg = "Couldn't open planfile: $!";
        } else {
            if (not defined read(FINGER, $output_text, $max_plan_size)) {
                $errormsg = "Couldn't read planfile: $!";
            }
            close(FINGER);
        }

        $archive_date = get_sqldate($modtime);
    }

    return($errormsg);
}


sub verify_and_load_request {
    my ($args, $user) = @_;
    my $errormsg = undef;

    if ((defined $args) and ($args ne '')) {
        $errormsg = "Unrecognized query arguments: \"$args\"";
    } elsif (not defined $user) {
        $errormsg = "No user specified.";
    } elsif ($user =~ /\@/) {
        $errormsg = "Finger request forwarding is forbidden.";
    } elsif ( (length($user) > 20) ||
              ($user =~ /[^A-Za-z0-9_]/) ||
              ($user !~ /\.\/[^\/]+/ && $files_allowed==1) ) {
        # The 20 char limit is just for safety against potential buffer overflows
        #  in finger servers, but it's more or less arbitrary.
        # Anything other than A-Za-z0-9_ is probably not a username.
        $errormsg = "Bogus user specified.\n";
    } else {
        if (defined $fakeusers{$user}) {
            $output_text = $fakeusers{$user}->();
        }
        elsif ($list_archives) {
            $errormsg = load_archive_list($user);
        }
        elsif ((defined $archive_date) or (defined $archive_time)) {
            $errormsg = load_archive($user);
        } else {
            $errormsg = load_file($user);
        }
    }

    if (defined $errormsg) {
        output_start($user, $host);
        print "    <center><h1>" if $do_html_formatting;
        print "$errormsg";
        print "</h1></center>" if $do_html_formatting;
        print "\n";
        output_ending();
        return(0);
    }

    return(1);
}


sub do_fingering {
    my ($query_string, $user) = @_;
    my @link_digest;

    if ($debug) {
        $title = "debugging...";
        output_start($user, $host);
        print("WARNING: Debug output is enabled in this finger request!\n");
        print("Original query string: \"$query_string\"\n");
        print("fingering $user ...\n");
        print("HTML formatting: $do_html_formatting ...\n");
        print("Is web interface: $is_web_interface ...\n");
        print("Browser: $browser ...\n");
        print("Embedding: $embed ...\n");
        print("Doing link digest: $do_link_digest ...\n");
    }

    if ((not defined $output_text) or ($output_text eq "")) {
        $output_text = $no_report_string;
    }

    # Change [style][/style] tags.
    while ($output_text =~ s/\[style\](.*?)\[\/style\](\r\n|\n|\b)//is) {
        push @style_array, $1 if $permit_user_styles;
    }

    # Change [title][/title] tags.
    while ($output_text =~ s/\[title\](.*?)\[\/title\](\r\n|\n|\b)//is) {
        push @title_array, $1 if $permit_user_titles;
    }

    # Change [wittyremark][/wittyremark] tags.
    while ($output_text =~ s/\[wittyremark\](.*?)\[\/wittyremark\](\r\n|\n|\b)//is) {
        push @wittyremark_array, $1 if $permit_user_wittyremarks;
    }

    # !!! FIXME: Make this a separate subroutine?
    if ($list_sections) {
        my @sectionlist;
        while ($output_text =~ s/\[section=\"(.*?)\"\](\r\n|\n|\b)(.*?)\[\/section\](\r\n|\n|\b)/$3/is) {
            push @sectionlist, $1;
        }

        $output_text = "Available sections:\n";
        if ($do_html_formatting) {
            foreach (@sectionlist) {
                my $url = "$base_url?user=$user&section=$_";
                $output_text .= "  \[link=\"$url\"\]$_\[/link\]\n";
            }
        } else {
            foreach (@sectionlist) {
                $output_text .= "  finger $user\@$host?section=$_\n";
            }
        }
    }

    # Select a section.
    while ($output_text =~ s/\[defaultsection=\"(\w*)\"\](\r\n|\n|\b)//) {
        $wanted_section = $1 if (not defined $wanted_section);
    }

    if (defined $wanted_section) {
        print("Using specific section: $wanted_section ...\n") if $debug;

	if (! ($output_text =~ s/.*\[section=\"$wanted_section\"\]\s*(.*?)\[\/section\].*/$1/is) ) {
            $output_text = "section \"$wanted_section\" not found.\n";
        }
    } else {
        1 while ($output_text =~ s/\[section=\".*?\"\](.*?)\[\/section\](\r\n|\n|\b)/$1/is);
    }

    if (($do_html_formatting) or ($is_web_interface)) {
        # HTMLify some characters...
        1 while ($output_text =~ s/</&lt;/s);
        1 while ($output_text =~ s/>/&gt;/s);
    }

    # Change [entry][/entry] tags.
    if ($do_html_formatting) {
        1 while ($output_text =~ s/\[entry](.*?)\[\/entry\]/<div class="entry">$1<\/div>/is);
    } else {
        1 while ($output_text =~ s/\[entry](.*?)\[\/entry\]/$1/is);
    }

    # Change [b][/b] tags.
    if ($do_html_formatting) {
        1 while ($output_text =~ s/\[b](.*?)\[\/b\]/<b>$1<\/b>/is);
    } else {
        1 while ($output_text =~ s/\[b](.*?)\[\/b\]/\*$1\*/is);
    }

    # Change [i][/i] tags.
    if ($do_html_formatting) {
        1 while ($output_text =~ s/\[i](.*?)\[\/i\]/<i>$1<\/i>/is);
    } else {
        1 while ($output_text =~ s/\[i](.*?)\[\/i\]/\/$1\//is);
    }

    # Change [u][/u] tags.
    if ($do_html_formatting) {
        1 while ($output_text =~ s/\[u](.*?)\[\/u\]/<u>$1<\/u>/is);
    } else {
        1 while ($output_text =~ s/\[u](.*?)\[\/u\]/_$1_/is);
    }

    # Change [font][/font] tags.
    if ($do_html_formatting) {
        1 while ($output_text =~ s/\[font (.*?)](.*?)\[\/font\]/<font $1>$2<\/font>/is);
    } else {
        1 while ($output_text =~ s/\[font (.*?)](.*?)\[\/font\]/$2/is);
    }

    # Change [link][/link] tags.
    if ($do_html_formatting) {
        1 while ($output_text =~ s/\[link=\"(.*?)\"\](.*?)\[\/link\]/<a href=\"$1\">$2<\/a>/is);
    } elsif ($do_link_digest) {
        my $x = $#link_digest + 2;  # start at one.
        while ($output_text =~ s/\[link=\"(.*?)\"\](.*?)\[\/link\]/$2 \[$x\]/is) {
            push @link_digest, $1;
            $x++;
        }
    } else {  # ugly-ass text output.
        1 while ($output_text =~ s/\[link=\"(.*?)\"\](.*?)\[\/link\]/$2 \[$1\]/is);
    }

    # Change [img][/img] tags.
    if ($do_html_formatting) {
        1 while ($output_text =~ s/\[img=\"(.*?)\"\](.*?)\[\/img\]/<img src=\"$1\" alt=\"$2\" border=\"0\">/is);
    } else {
        1 while ($output_text =~ s/\[img=\"(.*?)\"\](.*?)\[\/img\]/$2\n\[$1\]/is);
    }

    # Ditch [noarchive][/noarchive] tags ... those are metadata.
    1 while ($output_text =~ s/\[noarchive](.*?)\[\/noarchive\]/$1/is);

    if ($do_html_formatting) {
        # try to make URLs into hyperlinks in the HTML output.
        1 while ($output_text =~ s/(?<!href=")(?<!src=")(?<!">)\b([a-zA-Z]+?:\/\/[-~=\w&\.\/?]+)/<a href="$1">$1<\/a>/);

        # try to make email addresses into hyperlinks in the HTML output.
        # !!! FIXME: broken.
        #1 while ($output_text =~ s/\b(?<!href="mailto:)(?<!">)\b(.+?\@.+?)(\b|\.)/<a href=\"mailto:$1\">$1<\/a>/);

        # HTMLify newlines.
        #1 while ($output_text =~ s/\r//s);
        #1 while ($output_text =~ s/(?<!<br>)\n/<br>\n/s);
    }

    # this has to be done after any possible URL detection...
    #   convert ampersands for the browser.
    if (($do_html_formatting) or ($is_web_interface)) {
        1 while ($output_text =~ s/(?<!">)\&(?!lt)(?!gt)(?!amp)/&amp;/s);
    }

    if ($do_html_formatting and ($browser =~ /Lynx/)) {
        #1 while ($output_text =~ s/^( +)/"&nbsp;" x length($1)/mse);

        # The other choice being to split this puppy into two around
        #  the spaces, and gaffer them back together with
        #  $output_string = $1.length($2)x"&nbsp;".$3
        #  But that's not the perl way.

        1 while ($output_text =~ s/^ /\&nbsp;/ms);
        1 while ($output_text =~ s/^(\&nbsp;)+ /$1\&nbsp;/ms);

        # Don't forget some people still use macs.
        1 while ($output_text =~ s/\r\n/<br>/s);
        1 while ($output_text =~ s/\r/<br>/s);
        1 while ($output_text =~ s/\n/<br>/s);
    }

    # Change [center][/center] tags.
    if ($do_html_formatting) {
        if ($browser =~ /Opera/) {
            while ($output_text =~ /\[center](.*?)\[\/center\]/is) {
                my $buf = $1;
                1 while ($buf =~ s/\n/<br>/s);
                $output_text =~ s/\[center](.*?)\[\/center\]/<\/pre><center><code>$buf<\/code><\/center><pre>/is;
            }
        } else {
            1 while ($output_text =~ s/\[center](.*?)\[\/center\]/<center>$1<\/center>/is);
        }
    } else {
        while ($output_text =~ s/\[center](.*?)\[\/center\](.*)//si) {
            foreach (split("\n", $1)) {
                s/^\s*//g;
                s/\s*$//g;
                my $l = length($_);
                my $centering = (($l < 80) ? ((80 - $l) / 2) : 0);
                $output_text .= "\n" . (" " x $centering) . $_;
            }
            $output_text .= "\n" . $2;
        }
    }

    if ($#title_array >= 0) {
        $title = $title_array[int(rand($#title_array + 1))];
    }

	# Pick last item in array. That way if someone puts one on their
	#  page, it'll override a site-wide one.
    if ($#style_array >= 0) {
        $style = $style_array[$#style_array - 1];
    }

    if ($#wittyremark_array >= 0) {
        $wittyremark = $wittyremark_array[int(rand($#wittyremark_array + 1))];
    }

    # Pick a random title...
    if ($debug) {
        my $x;
        $x = $#title_array + 1;
        print("Number of titles: $x ...\n");
        print(" titles:\n");
        foreach (@title_array) {
            print("  -  [$_]\n");
        }

        print("Chosen: [$title].\n");

        $x = $#style_array + 1;
        print("Number of styles: $x ...\n");
        print(" styles:\n");
        foreach (@style_array) {
            print("  -  [$_]\n");
        }

        print("Chosen: [$style].\n");

        $x = $#wittyremark_array + 1;
        print("Number of witty remarks: $x ...\n");
        print(" witty remarks:\n");
        foreach (@wittyremark_array) {
            print("  -  [$_]\n");
        }
        print("Chosen: [$wittyremark].\n");

        $x = $#link_digest + 1;
        print("Items in link digest: $x ... \n");

        print("\n");
        print("Actual finger output begins below line...\n");
        print("---------------------------------------------------\n");
    }

    if ((not $do_html_formatting) and (not $is_web_interface)) {
        $output_text = "$title\n\n" . $output_text;
    }

    if (($do_link_digest) and ($#link_digest >= 0)) {
        $output_text .= "\n\n";

        my $idx = 0;
        foreach (@link_digest) {
            $idx++;  # start at one.
            $output_text .= "     [$idx] $_\n";
        }
    }

    1 while ($output_text =~ s/\A(\r\n)+//s);  # Remove starting newlines.
    1 while ($output_text =~ s/(\r\n)+\Z//s);  # Remove trailing newlines.
    1 while ($output_text =~ s/\A\n+//s);  # Remove starting newlines.
    1 while ($output_text =~ s/\n+\Z//s);  # Remove trailing newlines.
    1 while ($output_text =~ s/\A\r+//s);  # Remove starting newlines.
    1 while ($output_text =~ s/\r+\Z//s);  # Remove trailing newlines.

    output_start($user, $host);
    print("$output_text\n");
    output_ending();
}


sub read_request {
    my $retval = '';
    my $count = 0;
    my $s = undef;
    my $elapsed = undef;
    my $starttime = undef;

    if (defined $read_timeout) {
        $s = new IO::Select();
        $s->add(fileno(STDIN));
        $starttime = time();
        $elapsed = 0;
    }

    while (1) {
        if (defined $read_timeout) {
            my $ready = scalar($s->can_read($read_timeout - $elapsed));
            return undef if (not $ready);
            $elapsed = (time() - $starttime);
        }

        my $ch;
        my $rc = sysread(STDIN, $ch, 1);
        return undef if ($rc != 1);
        if ($ch ne "\015") {
            return($retval) if ($ch eq "\012");
            $retval .= $ch;
            $count++;
            return($retval) if ($count >= $max_request_size);
        }
    }

    return(undef);  # shouldn't ever hit this.
}


sub finger_mainline {
    my $query_string = read_request();

    my $syslog_text;
    if (not defined $query_string) {
        $syslog_text = "input timeout on finger request. Dropped client.\n";
        print($syslog_text);  # tell the client, if they care.
        syslog("info", $syslog_text) if ($use_syslog);
    } else {
        $syslog_text = "finger request: \"$query_string\"\n";
        $syslog_text =~ s/%/%%/g;
        if ($use_syslog) {
            syslog("info", $syslog_text) or
                 die("Couldn't write to syslog: $!\n");
        }

        my ($user, $args) = $query_string =~ /\A([^\?]*)(\?.*|\b)\Z/;
        # $user =~ tr/A-Z/a-z/ if defined $user;
        $args = parse_args($args);

        if (verify_and_load_request($args, $user)) {
            do_fingering($query_string, $user)
        }
    }

    return(0);
}


sub syslog_and_die {
    my $err = shift;
    $err .= "\n";
    $err =~ s/%/%%/g;
    syslog("info", $err) if ($use_syslog);
    die($err);
}


sub go_to_background {
    use POSIX 'setsid';
    chdir('/') or syslog_and_die("Can't chdir to '/': $!");
    open STDIN,'/dev/null' or syslog_and_die("Can't read '/dev/null': $!");
    open STDOUT,'>/dev/null' or syslog_and_die("Can't write '/dev/null': $!");
    defined(my $pid=fork) or syslog_and_die("Can't fork: $!");
    exit if $pid;
    setsid or syslog_and_die("Can't start new session: $!");
    open STDERR,'>&STDOUT' or syslog_and_die("Can't duplicate stdout: $!");
    syslog("info", "Daemon process is now detached") if ($use_syslog);
}


sub drop_privileges {
    delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};
    $ENV{'PATH'} = $safe_path;
    $) = $wanted_gid if (defined $wanted_gid);
    $> = $wanted_uid if (defined $wanted_uid);
}


sub signal_catcher {
    my $sig = shift;
    syslog("info", "Got signal $sig. Shutting down.") if ($use_syslog);
    exit 0;
}


my @kids;
use POSIX ":sys_wait_h";
sub reap_kids {
    my $i = 0;
    my $x = scalar(@kids);
    while ($i < scalar(@kids)) {
        my $rc = waitpid($kids[$i], &WNOHANG);
        if ($rc != 0) {  # reaped a zombie.
            splice(@kids, $i, 1); # take it out of the array.
        } else {  # still alive, try next one.
            $i++;
        }
    }

    $SIG{CHLD} = \&reap_kids;  # make sure this works on crappy SysV systems.
}


sub do_digests {
    do_digest();
    do_rss_digest();
}


sub daemon_upkeep {
    return if not defined $digest_frequency;

    my $curtime = time();
    if ($curtime >= $next_plan_digest) {
        do_digests();
        $next_plan_digest += ($digest_frequency * 60);
    }
}


# Mainline.

foreach (@ARGV) {
    $daemonize = 1, next if $_ eq '--daemonize';
    $daemonize = 1, next if $_ eq '-d';
    $daemonize = 0, next if $_ eq '--no-daemonize';
    $next_plan_digest = 1, next if $_ eq '--digest';
    die("Unknown command line \"$_\".\n");
}

if ($use_syslog) {
    use Sys::Syslog qw(:DEFAULT setlogsock);
    setlogsock("unix");
    openlog("fingerd", "user") or die("Couldn't open syslog: $!\n");
}


my $retval = 0;
if (not $daemonize) {
    drop_privileges();

    if ($next_plan_digest) {
        do_digests();
    } else {
        $retval = finger_mainline();
    }

    exit $retval;
}

# The daemon.

if ($use_syslog) {
    syslog("info", "IcculusFinger daemon $version starting up...");
}

go_to_background();

# reap zombies from client forks...
$SIG{CHLD} = \&reap_kids;
$SIG{TERM} = \&signal_catcher;
$SIG{INT} = \&signal_catcher;

use IO::Socket::INET;
my $listensock = IO::Socket::INET->new(LocalPort => $server_port,
                                       Type => SOCK_STREAM,
                                       ReuseAddr => 1,
                                       Listen => $max_connects);

syslog_and_die("couldn't create listen socket: $!") if (not $listensock);

my $selection = new IO::Select( $listensock );
drop_privileges();

if ($use_syslog) {
    syslog("info", "Now accepting connections (max $max_connects" .
                    " simultaneous on port $server_port).");
}

if (defined $digest_frequency) {
    $next_plan_digest = time() + ($digest_frequency * 60);
    do_digests(); # Dump a digest right at the start.
}

while (1)
{
    # prevent connection floods.
    daemon_upkeep(), sleep(1) while (scalar(@kids) >= $max_connects);

    # if timed out, do upkeep and try again.
    daemon_upkeep() while not $selection->can_read(10);

    # we've got a connection!
    my $client = $listensock->accept();
    if (not $client) {
        syslog("info", "accept() failed: $!") if ($use_syslog);
        next;
    }

    my $ip = $client->peerhost();
    syslog("info", "connection from $ip") if ($use_syslog);

    my $kidpid = fork();
    if (not defined $kidpid) {
        syslog("info", "fork() failed: $!") if ($use_syslog);
        close($client);
        next;
    }

    if ($kidpid) {  # this is the parent process.
        close($client);  # parent has no use for client socket.
        push @kids, $kidpid;
    } else {
        $ENV{'TCPREMOTEIP'} = $ip;
        close($listensock);   # child has no use for listen socket.
        local *FH = $client;
        open(STDIN, "<&FH") or syslog_and_die("no STDIN reassign: $!");
        open(STDERR, ">&FH") or syslog_and_die("no STDERR reassign: $!");
        open(STDOUT, ">&FH") or syslog_and_die("no STDOUT reassign: $!");
        my $retval = finger_mainline();
        close($client);
        exit $retval;  # kill child.
    }
}

close($listensock);  # shouldn't ever hit this.
exit $retval;

# end of finger.pl ...


