#!/usr/bin/perl -w

use strict;
use warnings;
use DBI;
use File::Basename;

# The ever important debug-spew-enabler...
my $debug = 0;

# File must have not been touch within this many minutes to be archived.
#  This prevents archiving of a file that is in the middle of being edited.
my $update_delay = 30;

my $plandir = '/fingerspace';

my $dbhost = 'localhost';
my $dbuser = 'fingermgr';

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
my $newsauthor = 'fingermaster';
my $newsposter = '/usr/local/bin/IcculusNews_post.pl';


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
        1 while ($t =~ s/\[font(.*?)\](.*?)\[\/font\]/<font $1>$2<\/font>/is);

        print("   parsed markup tags...\n") if $debug;
        my $newssubj = "Notable .plan update from $u";
        my $rc = open(PH, "|$newsposter '$newsauthor' '$newssubj' -");
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


#----------------------------------------------------------------------------#
# End of setup vars. The rest is probably okay without you touching it.      #
#----------------------------------------------------------------------------#

sub get_planfiles {
    my $dirname = shift;
    opendir(DIRH, $dirname) or die ("Failed to enumerate planfiles: $!\n");
    my @retval = readdir(DIRH) or die ("Failed to enumerate planfiles: $!\n");
    closedir(DIRH);
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

    open(PLAN_IN, $filename) or die("Can't open $filename: $!\n");
    while (<PLAN_IN>) {
        $retval .= $_;
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

    my $user = basename($filename);
    my $modtime = (stat($filename))[9];
    my $fdate = get_sqldate($modtime);
    my $sql = '';

    print(" * Examining $user\'s .planfile (modtime $fdate)...\n") if $debug;

    $user = $link->quote($user);

    # ... get date of the latest archived .plan ...
    $sql = "select postdate from $dbtable_archive where username=$user" .
           " order by postdate desc limit 1";
    my $sth = $link->prepare($sql);
    $sth->execute() or die "can't execute the query: $sth->errstr";

    my @row = $sth->fetchrow_array();
    if (not @row) {
        print("   Don't seem to have a previous entry ...\n") if $debug;
    } else {
        my $t = time();
        if ($t < $modtime) {
            print("   WARNING: file timestamp is in the future!\n") if $debug;
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
            print("   Newer revision needs archiving.\n") if $debug;
        }
    }

    my $t = read_plantext($link, $filename);
    my $ftext = $link->quote($t);
    $sql = "insert into $dbtable_archive (username, postdate, text)" .
           " values ($user, '$fdate', $ftext)";

    $link->do($sql) or die "can't execute the query: $link->errstr";
    print("   Revision added to archives.\n") if $debug;

    run_external_updater(basename($filename), $fdate, $t);
}


# the mainline.

foreach (@ARGV) {
    $debug = 1, next if ($_ eq '--debug');
    #$username = $_, next if (not defined $username);
    #$subject = $_, next if (not defined $subject);
    #$text = $_, next if (not defined $text);
    #etc.
}

my @planfiles = get_planfiles($plandir);

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

my $dsn = "DBI:mysql:database=$dbname;host=$dbhost";
print(" * Connecting to [$dsn] ...\n") if $debug;

my $link = DBI->connect($dsn, $dbuser, $dbpass, {'RaiseError' => 1});

foreach (@planfiles) {
    update_planfile($link, "$plandir/$_");
}

$link->disconnect();
exit 0;

# end of IcculusFinger_archiveplans.pl ...

