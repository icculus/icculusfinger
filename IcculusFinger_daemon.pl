#!/usr/bin/perl -w
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
#-----------------------------------------------------------------------------

# !!! TODO: Let [img] tags nest inside [link] tags.
# !!! TODO: Make [center] tags attempt to format plain text.


use strict;    # don't touch this line, nootch.
use warnings;  # don't touch this line, either.
use DBI;       # or this. I guess. Maybe.

# Version of IcculusFinger. Change this if you are forking the code.
my $version = "v2.0.4";


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
my $max_request_size = 1024;

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


# These are special finger accounts; when a user queries for this fake
#  user, we hand back the string returned from the attached function as if
#  it was the contents of a planfile. Be careful with this, as it opens up
#  potential security holes.
# These subs do NOT have a maximum size limit imposed by the
#  $max_plan_size setting, above.
# This hash is checked before actual planfiles, so you can override an
#  existing user through this mechanism.
my %fakeusers;  # the hash has to exist; don't comment this line.

$fakeusers{'fortune'} = sub {
    return(`/usr/games/fortune`);
};

$fakeusers{'root'} = sub {
    return("ph34r me, for i am root. I'm l33t as kittens.");
};

$fakeusers{'time'} = sub {
    return("At the sound of the beep, it will be: " . scalar localtime() .
           "\012\012\012\012    ...[b][i][u]BEEP.[/u][/i][/b]");
};


# This works if run from qmail's tcp-env, and not tcpd.
#  also note that this is pretty useless for hits through the web
#  interface, since the webserver's IP will be reported, not the
#  browser's IP.
if (defined $ENV{'TCPREMOTEIP'}) {
    $fakeusers{'ipaddr'} = sub {
        return("Your IP address appears to be $ENV{'TCPREMOTEIP'}");
    };
}

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
  </head>

  <body>
   <center><h1>Finger info for $user\@$host...</h1></center>
   <hr>


__EOF__
    print "\n<pre>\n" if ($browser !~ /Lynx/);
}


sub output_ending {

    if (($is_web_interface) or ($do_html_formatting) and ($browser !~ /Lynx/)) {
        print("    </pre>\n");
    }

    return if $embed;

    my $revision = undef;
    if (($show_revision_date) and (defined $archive_date)) {
        $revision = "When this .plan was written: $archive_date";
    }

    if ($do_html_formatting) {
        $revision = ((defined $revision) ? "$revision<br>\n" : '');

        print <<__EOF__;

    <hr>
    <center>
      <font size="-3">
        $revision
        $html_credits<br>
        <i>$wittyremark</i>
      </font>
    </center>
__EOF__

    } else {
        # !!! FIXME : Make that ------ line fit the length of the strings.
        print "-------------------------------------------------------------------------\n";
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
    my $fname = ($use_homedir) ? "/home/$user/.plan" : "$fingerspace$user";
    my $errormsg = undef;

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
    } elsif (length($user) > 20) {
        # The 20 char limit is just for safety against potential buffer overflows
        #  in finger servers, but it's more or less arbitrary.
        # !!! TODO FIXME: Check for bogus characters in username/host.
        $errormsg = "Bogus user specified.";
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

        # !!! FIXME: Why isn't the substitution working? I need to assign $2 directly for some reason...
        if ($output_text =~ s/\[section=\"$wanted_section\"\](\r\n|\n|\b)(.*?)\[\/section\](\r\n|\n|\b)/$2/is) {
            $output_text = $2;
        } else {
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

    # Change [b][/b] tags.
    if ($do_html_formatting) {
        1 while ($output_text =~ s/\[b](.*?)\[\/b\]/<b>$1<\/b>/is);
    } else {
        1 while ($output_text =~ s/\[b](.*?)\[\/b\]/$1/is);
    }

    # Change [i][/i] tags.
    if ($do_html_formatting) {
        1 while ($output_text =~ s/\[i](.*?)\[\/i\]/<i>$1<\/i>/is);
    } else {
        1 while ($output_text =~ s/\[i](.*?)\[\/i\]/$1/is);
    }

    # Change [u][/u] tags.
    if ($do_html_formatting) {
        1 while ($output_text =~ s/\[u](.*?)\[\/u\]/<u>$1<\/u>/is);
    } else {
        1 while ($output_text =~ s/\[u](.*?)\[\/u\]/$1/is);
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
        1 while ($output_text =~ s/\[center](.*?)\[\/center\]/$1/is);
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
        1 while ($output_text =~ s/\[img=\"(.*?)\"\](.*?)\[\/img\]/<img src=\"$1\" alt=\"$2\">/is);
    } else {
        1 while ($output_text =~ s/\[img=\"(.*?)\"\](.*?)\[\/img\]/$2/is);
    }

    # Ditch [noarchive][/noarchive] tags ... those are metadata.
    1 while ($output_text =~ s/\[noarchive](.*?)\[\/noarchive\]/$1/is);

    if ($do_html_formatting) {
        # try to make URLs into hyperlinks in the HTML output.
        1 while ($output_text =~ s/(?<!href=")(?<!src=")(?<!">)\b([a-zA-Z]+?:\/\/[-~=\w&\.\/?]+)/<a href="$1">$1<\/a>/);

        # try to make email addresses into hyperlinks in the HTML output.
        1 while ($output_text =~ s/\b(?<!href="mailto:)(?<!">)\b([\w\.]+?\@[\w\.]+)(\b|\.)/<a href=\"mailto:$1\">$1<\/a>/);

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
        # !!! FIXME: executable regexps suck.
        # !!! FIXME: This doesn't work very well.
        1 while ($output_text =~ s/^( +)/"&nbsp;" x length($1)/mse);
        1 while ($output_text =~ s/\r//s);
        1 while ($output_text =~ s/\n/<br>/s);
    }

    if ($#title_array >= 0) {
        $title = $title_array[int(rand($#title_array + 1))];
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

    1 while ($output_text =~ s/\A\n//s);  # Remove starting newlines.
    1 while ($output_text =~ s/\n\Z//s);  # Remove trailing newlines.

    output_start($user, $host);
    print("$output_text\n");
    output_ending();
}


sub read_request {
    my $ch;
    my $count;
    my $retval = '';

    for ($count = 0; $count < $max_request_size; $count++) {
        # !!! FIXME: A timeout would be great, here.
        $ch = getc(STDIN);
        if ($ch ne "\015") {
            last if (($ch eq '') or ($ch eq "\012"));
            $retval .= $ch;
        }
    }

    return($retval);
}


# Mainline.

my $query_string = read_request();

if ($use_syslog) {
    use Sys::Syslog qw(:DEFAULT setlogsock);
    setlogsock("unix");
    openlog("fingerd", "user") or die("Couldn't open syslog: $!\n");
    syslog("info", "finger request: \"$query_string\"\n")
        or die("Couldn't write to syslog: $!\n");
}

my ($user, $args) = $query_string =~ /\A(.*?)(\?.*|\b)\Z/;
$user =~ tr/A-Z/a-z/ if defined $user;
$args = parse_args($args);

if (verify_and_load_request($args, $user)) {
    do_fingering($query_string, $user)
}

exit 0;

# end of finger.pl ...


