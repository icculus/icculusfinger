#!/usr/bin/perl -w

use strict;
use warnings;

#-----------------------------------------------------------------------------#
#             CONFIGURATION VARIABLES: Change to suit your needs...           #
#-----------------------------------------------------------------------------#

# Where the home dirs reside. $homebasedir/username/.plan is where we look...
# Note that THIS MUST NOT HAVE THE TRAILING DIR SEPARATOR!
my $homebasedir = '/home';

# This is the directory to move planfiles to. Note that THIS MUST NOT HAVE
#  THE TRAILING DIR SEPARATOR!
my $fingerspace = '/fingerspace';

#-----------------------------------------------------------------------------#
#     The rest is probably okay without you laying yer dirty mits on it.      #
#-----------------------------------------------------------------------------#



sub chown_by_name {
    my($user, $file) = @_;
    chown((getpwnam($user))[2], (getpwnam('root'))[3], $file) == 1 or
       die("chown on $file failed: $!\n");
}


sub check_dir {
    my $user = shift;
    my $nofingerpath = "$homebasedir/$user/.nofinger";
    my $homepath = "$homebasedir/$user/.plan";
    my $fingerpath = "$fingerspace/$user";

    if (($user eq '.') or ($user eq '..')) {
        return;
    }

    if (not -d "$homebasedir/$user") {
        print(" - $homebasedir/$user isn't a directory. Wierd.\n");
        return;
    }

    # ...since the user can WRITE to an existing file, but not create one
    #  in the fingerspace, we need to create it if it doesn't exist...
    if (not -e $fingerpath) {
        print(" + Creating $fingerpath ...\n");
        # God, I'm lazy. :)
        `touch $fingerpath`;
        if (not -e $fingerpath) {
            print("Failed to create.\n");
            return;
        }
    }

    # always fix permissions ...
    chmod(0644, $fingerpath) or die("Failed to chmod $fingerpath: $!\n");
    chown_by_name($user, $fingerpath);

    if (not -e $homepath) {
        print(" + symlinking missing file $homepath to $fingerpath ...\n");
        symlink($fingerpath, $homepath) or die("symlink failed:  $!\n");
        return;
    }

    # (For now, we'll assume that a symlink means we've moved it already.)
    if (-l $homepath) {
        if (readlink($homepath) ne $fingerpath) {
            print(" - There's an UNEXPECTED SYMLINK at $homepath ...\n");
        }
        return;
    }

    if (-d $homepath) {
        print(" - Uh...there's a DIRECTORY at $homepath ...\n");
        return;
    }

    if (-d $fingerpath) {
        print(" - Uh...there's a DIRECTORY at $fingerpath ...\n");
        return;
    }

    if (-e $nofingerpath) {
        print(" - $nofingerpath exists. Explicitly skipping ...\n");
        return;
    }

    print(" + Moving $homepath to $fingerpath ... \n");
    rename($homepath, $fingerpath) or die("rename failed:  $!\n");
    symlink($fingerpath, $homepath) or die("symlink failed:  $!\n");
}


# the mainline ...

opendir(DIRH, $homebasedir) or die("Can't open $homebasedir: $!\n");
my @homedirs = readdir(DIRH);
closedir(DIRH);

foreach (@homedirs) {
    check_dir($_);
}

# end of IcculusFinger_planmove.pl ...
