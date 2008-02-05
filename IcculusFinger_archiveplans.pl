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

use strict;
use warnings;
use DBI;
use File::Basename;


#-----------------------------------------------------------------------------#
#             CONFIGURATION VARIABLES: Change to suit your needs...           #
#-----------------------------------------------------------------------------#

# The ever important debug-spew-enabler...
my $debug = 0;

# File must have not been touch within this many minutes to be archived.
#  This prevents archiving of a file that is in the middle of being edited.
my $update_delay = 60 * 24;  # 24 hours old.

my $use_homedir = 0;
my $fingerspace = '/fingerspace';

my $dbhost = 'localhost';
my $dbuser = 'fingermgr';

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
#  This value is specified in bytes. Data read from the database has no
#  limit, but theoretically, if it had to pass through this script to get into
#  the database, this is a practical limit for that, too.
my $max_plan_size = (100 * 1024);

# The password can be entered in three ways: Either hardcode it into $dbpass,
#  (which is a security risk, but is faster if you have a completely closed
#  system), or leave $dbpass set to undef, in which case this script will try
#  to read the password from the file specified in $dbpassfile (which means
#  that this script and the database can be touched by anyone with read access
#  to that file), or leave both undef to have DBI get the password from the
#  DBI_PASS environment variable, which is the most secure, but least
#  convenient.
my $dbpass = undef;
my $dbpassfile = '/etc/IcculusFinger_dbpass.txt';

my $dbname = 'IcculusFinger';
my $dbtable_archive = 'finger_archive';

my $post_to_icculusnews = 1;
my $newshost     = 'localhost';
my $newsauthor   = 'fingermaster';
my $newsposter   = '/usr/local/bin/IcculusNews_post.pl';
my $newspass     = undef;
my $newspassfile = '/etc/IcculusFinger_newspass.txt';

#-----------------------------------------------------------------------------#
#     The rest is probably okay without you laying yer dirty mits on it.      #
#-----------------------------------------------------------------------------#

my $force_archive = undef;
my $replace_archive = 0;

sub run_external_updater {
    my $u = shift;
    my $d = shift;
    my $t = shift;

    if ($post_to_icculusnews) {
        print("   posting to IcculusNews's submission queue...\n") if $debug;
        1 while ($t =~ s/\&(?!amp)/&amp;/s);
        1 while ($t =~ s/</&lt;/s);
        1 while ($t =~ s/>/&gt;/s);
        1 while ($t =~ s/\[title\](.*?)\[\/title\](\n|\r\n|\b)//is);
        1 while ($t =~ s/\[wittyremark\](.*?)\[\/wittyremark\](\n|\r\n|\b)//is);
        1 while ($t =~ s/\[b\](.*?)\[\/b\]/<b>$1<\/b>/is);
        1 while ($t =~ s/\[u\](.*?)\[\/u\]/<u>$1<\/u>/is);
        1 while ($t =~ s/\[i\](.*?)\[\/i\]/<i>$1<\/i>/is);
        1 while ($t =~ s/\[center\](.*?)\[\/center\]/<center>$1<\/center>/is);
        1 while ($t =~ s/\[img=(".*?")\].*?\[\/img\]/<img src=$1>/is);
        1 while ($t =~ s/\[link=(".*?")\](.*?)\[\/link\]/<a href=$1>$2<\/a>/is);
        1 while ($t =~ s/\[defaultsection=".*?"\](\n|\r\n|\b)//is);
        1 while ($t =~ s/\[section=".*?"\](\n|\r\n|\b)(.*?)\[\/section\](\n|\r\n|\b)/$2/is);
        1 while ($t =~ s/\[font(.*?)\](.*?)\[\/font\]/<font $1>$2<\/font>/is);
        1 while ($t =~ s/\[noarchive\](.*?)\[\/noarchive\]/$1/is);

        print("   parsed markup tags...\n") if $debug;
        my $newssubj = "Notable .plan update from $u";
        $ENV{'ICCNEWS_POST_PASS'} = $newspass if defined $newspass;
        my $rc = open(PH, "|$newsposter '$newshost' '$newsauthor' '1' '$newssubj' -");
        if (not $rc) {
            print("   No pipe to IcculusNews: $!\n");
        } else {
            print PH "<i>$u updated his .plan file at $d" .
                     " with the following info:</i>\n<p>\n<pre>$t</pre>\n</p>\n";
            close(PH);
            print("   posted to submission queue.\n") if $debug;
        }
    }
}


sub enumerate_planfiles {
    my $dirname = (($use_homedir) ? '/home' : $fingerspace);
    opendir(DIRH, $dirname) or return(undef);
    my @dirents = sort readdir(DIRH);
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

    return('' .
           ($t[5]) . '-' . ($t[4]) . '-' . ($t[3]) . ' ' .
           ($t[2]) . ':' . ($t[1]) . ':' . ($t[0])
          );
}


sub read_plantext {
    my $link = shift;
    my $filename = shift;
    my $retval = '';

    open(PLAN_IN, '<', $filename) or die("Can't open $filename: $!\n");
    if (not defined read(PLAN_IN, $retval, $max_plan_size)) {
        die("Couldn't read planfile: $!");
    }
    close(PLAN_IN);

    return($retval);
}


sub update_planfile {
    my $link = shift;
    my $filename = shift;

    if (-d $filename) {
        return;
    }

    my $modtime = (stat($filename))[9];
    my $fdate = get_sqldate($modtime);
    my $sql = '';
    my $plantext = undef;

    my $user = $filename;
    if ($use_homedir) {
        $user =~ s#\A/home/(.*?)/\.plan\Z#$1#;
    } else {
        $user = basename($filename);
    }

    my $replace = 0;
    if ((defined $force_archive) and ($force_archive eq $user)) {
        print(" * Forcing archival of $user\'s .planfile...\n") if $debug;
        $user = $link->quote($user);
        $replace = $replace_archive;
    } else {
        print(" * Examining $user\'s .planfile (modtime $fdate)...\n") if $debug;

        $user = $link->quote($user);

        # ... get date of the latest archived .plan ...
        $sql = "select postdate, text from $dbtable_archive where username=$user" .
               " order by postdate desc limit 1";
        my $sth = $link->prepare($sql);
        $sth->execute() or die "can't execute the query: $sth->errstr";

        my @row = $sth->fetchrow_array();
        $sth->finish();
        if (not @row) {
            print("   Don't seem to have a previous entry ...\n") if $debug;
            if ( (stat($filename))[7] == 0 ) {
                print("    ...but the .plan is empty. Skipping.\n") if $debug;
                return;
            }
        } else {
            my $t = time();
            if ($t < $modtime) {
                print("   WARNING: file timestamp is in the future!\n") if $debug;
                `touch -c -m '$filename'`;  # force to now, retest next time for content change.
                return;
            } else {
                if ( ($t - $modtime) < ($update_delay * 60) ) {
                    if ($debug) {
                        my $oktime = int($update_delay - (($t - $modtime) / 60));
                        print("   File update is too new to archive.\n");
                        print("   (Try again in $oktime minutes.)\n");
                    }
                    return;
                }
            }

            if ($debug) {
                my $x = $row[0];
                print("   dates: [$x] [$fdate]\n");
            } 

            if ($row[0] eq $fdate) {
                print("   Matches archive timestamp. Skipping.\n") if $debug;
                return;
            } else {
                $plantext = read_plantext($link, $filename);
                my $plancpy = $plantext;
    	        # Ditch [noarchive][/noarchive] tag blocks and strcmp rest.
    	        1 while ($row[1] =~ s/\[noarchive\].*?\[\/noarchive\]//is);
    	        1 while ($plancpy =~ s/\[noarchive\].*?\[\/noarchive\]//is);
                if ($row[1] ne $plancpy) {
    	            print("   Newer revision needs archiving.\n") if $debug;
    	        } else {
    	            print("   Newer revision only changed [noarchive] section(s). Skipping.\n") if ($debug);
                    return;
    	        }
    	    }
        }
    }

    $plantext = read_plantext($link, $filename) if (not defined $plantext);
    my $ftext = $link->quote($plantext);

    my $lastpost = undef;
    if ($replace) {
        # ... get date of the latest archived .plan ...
        $sql = "select postdate from $dbtable_archive where username=$user" .
               " order by postdate desc limit 1";
        my $sth = $link->prepare($sql);
        $sth->execute() or die "can't execute the query: $sth->errstr";

        my @row = $sth->fetchrow_array();
        $sth->finish();
        if (not @row) {
            $replace = 0;  # no previous entry.
        } else {
            $lastpost = $row[0];
        }
    }

    if ($replace) {
        $sql = "update $dbtable_archive set text=$ftext" .
               " where $user=$user and postdate='$lastpost'";
        $lastpost =~ s/\d\d\d\d\-(\d\d)-(\d\d) (\d\d)\:(\d\d)\:(\d\d)/$1$2$3$4.$5/;
        `touch -c -m -t '$lastpost' '$filename'`;  # force file to this date.
    } else {
        $sql = "insert into $dbtable_archive (username, postdate, text)" .
               " values ($user, '$fdate', $ftext)";
    }

    $link->do($sql) or die "can't execute the query: $link->errstr";
    print("   Revision added to archives.\n") if $debug;

    run_external_updater(basename($filename), $fdate, $plantext);
}


# the mainline.

for (my $i = 0; $i < scalar(@ARGV); $i++) {
    my $arg = $ARGV[$i];
    $debug = 1, next if ($arg eq '--debug');
    $replace_archive = 1, next if ($arg eq '--replace');
    $force_archive = $ARGV[++$i], next if ($arg eq '--force');

    #$username = $arg, next if (not defined $username);
    #$subject = $arg, next if (not defined $subject);
    #$text = $arg, next if (not defined $text);
    #etc.

    print("Unknown argument \"$arg\".\n");
}

if (($replace_archive) and (not defined $force_archive)) {
    die("--replace without --force")
}

my @planfiles = enumerate_planfiles();
die("Failed to enumerate planfiles: $!\n") if not @planfiles;

if (not defined $dbpass) {
    if (defined $dbpassfile) {
        open(FH, $dbpassfile) or die("failed to open $dbpassfile: $!\n");
        $dbpass = <FH>;
        chomp($dbpass);
        $dbpass =~ s/\A\s*//;
        $dbpass =~ s/\s*\Z//;
        close(FH);
    }
}

if ((not defined $newspass) && (not defined $ENV{'ICCNEWS_POST_PASS'})) {
    if (defined $newspassfile) {
        open(FH, $newspassfile) or die("failed to open $newspassfile: $!\n");
        $newspass = <FH>;
        chomp($newspass);
        $newspass =~ s/\A\s*//;
        $newspass =~ s/\s*\Z//;
        close(FH);
    }
}

my $dsn = "DBI:mysql:database=$dbname;host=$dbhost";
print(" * Connecting to [$dsn] ...\n") if $debug;

my $link = DBI->connect($dsn, $dbuser, $dbpass, {'RaiseError' => 1});

foreach (@planfiles) {
    update_planfile($link, "$_");
}

$link->disconnect();
exit 0;

# end of IcculusFinger_archiveplans.pl ...

