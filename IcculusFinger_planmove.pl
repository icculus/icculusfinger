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
use File::Copy;

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
        return if ($user eq '.keep');  # gentoo fix.
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
    move($homepath, $fingerpath) or die("move failed:  $!\n");
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
