Basic installation instructions:

Set up a new Unix user on the system, call him "finger". Make sure this user
IS NOT PERMITTED TO LOG IN (set his shell to /bin/false or something).

Edit IcculusFinger_daemon.pl. There are lots of variables that you can tweak
to match you're system and customize to your taste at the top. This is very
well documented, so have no fear.

Copy IcculusFinger_daemon.pl to /usr/local/bin/ ...

If you are planning on making everyone keep their planfiles in a unified
public directory (a "fingerspace"), then edit/copy IcculusFinger_planmove.pl
to /usr/local/bin, too. Run this program once now, and once every time you
add a new user to your system. It spits out a lot of text explaining exactly
what it's doing.

Make sure there's a line like this in /etc/services:
finger		79/tcp

If you want to manage IcculusFinger via inetd, then add this line to
 /etc/inetd.conf:
finger	stream	tcp	nowait	finger	/usr/sbin/tcpd /usr/local/bin/IcculusFinger_daemon.pl

If you like qmail's tcp-env better than tcpd (like I do), then use a line
 like this instead:
finger	stream	tcp	nowait	finger	/var/qmail/bin/tcp-env tcp-env -R /usr/local/bin/IcculusFinger_daemon.pl

The "ipaddr" fake user works with tcp-env, and not tcpd at this moment. Not a
 big deal or anything, but just FYI. "ipaddr" also works if you use the
 --daemonize flag instead of inetd, too.

Make sure no other lines in /etc/inetd.conf are handling finger requests.

Run "killall -HUP inetd". You should now be answering finger requests from the
outside world.

If you want to run IcculusFinger as a standalone daemon (instead of managing
it through inetd), put it in your startup scripts. This is different for every
system, but on my (Slackware) system, putting this in /etc/rc.d/rc.local works
well:

   echo "Starting IcculusFinger daemon..."
   /usr/local/bin/IcculusFinger_daemon.pl --daemonize

Next time you reboot, you should be answering finger requests by default. You
 can also run that command line without rebooting, and it should work, too.


If you want the web interface to finger accounts:

Edit IcculusFinger_webinterface.pl. There are some variables that you can
tweak to match you're system and customize to your taste at the top. This is
very well documented, so have no fear.

Copy IcculusFinger_webinterface.pl to somewhere your webserver can see it and
treat it as a cgi-bin program. You may want to symlink it or rename it to a
smaller filename (such as finger.pl).

Once your server is treating it as a cgi-bin program, run it as such (this is
 just an example, it'll be different depending on how you set things up):

  http://myserver.dom/cgi-bin/IcculusFinger_webinterface.pl?user=username



If using a MySQL database for planfile archiving:

Get MySQL installed on your system.

Edit IcculusFinger_archiveplans.pl. There are some variables that you can
tweak to match you're system and customize to your taste at the top. This is
very well documented, so have no fear.

Copy IcculusFinger_archiveplans.pl to /usr/local/bin/ ...


 (This part is cut-and-pasted-and-then-modified from Horde's install docs.
   http://www.horde.org/)

First of all, it is very important that you change the MySQL password for
the user 'root'. If you haven't done so already, type:

    mysqladmin [ -h <host> ] -u root -p password <new-password>

Login to MySQL by typing:

    mysql [ -h <host> ] -u root -p

Enter the password for root.

Now, create a database named "IcculusFinger" and switch to it:

    mysql> create database IcculusFinger;

    mysql> use IcculusFinger;

Then set up the table called "finger_archive". You can actually name it
anything you like as long as you use the same name when you alter the
IcculusFinger source files (maybe that goes without saying...but there's a
config variable at the top of a few of them that specifies this).

Type:

  mysql> create table finger_archive (
           id int not null auto_increment,
           username varchar(32) not null,
           postdate datetime not null,
           text mediumtext character set utf8 COLLATE utf8_general_ci not null,
           summary varchar(128) character set utf8 COLLATE utf8_general_ci not null default '',
           primary key (id)
         );

Next, create the MySQL user for the IcculusFinger database. You can call this
user any name and give this user any password you want, just make sure that
you use the same name and password when you alter the source files. For
this example, I will call the user "fingermgr" and make the password
"fingerpass". Type:

    mysql> use mysql;

    mysql> replace into user ( host, user, password )
        values ('localhost', 'fingermgr', password('fingerpass'));

    mysql> replace into db ( host, db, user, select_priv, insert_priv,
        update_priv, delete_priv, create_priv, drop_priv )
        values ('localhost', 'IcculusFinger', 'fingermgr', 'Y', 'Y',
        'Y', 'Y', 'Y', 'Y');

    mysql> flush privileges;

Exit MySQL by typing:

    mysql> quit

By default, the database password is read from /etc/IcculusFinger_dbpass.txt,
so you should:

    echo "fingerpass" > /etc/IcculusFinger_dbpass.txt

(obviously "fingerpass" should be the actual password.)

MAKE SURE that /etc/IcculusFinger_dbpass.txt is owned by unix user "finger"
and may only be read by him. THIS IS IMPORTANT.

   chown finger.root /etc/IcculusFinger_dbpass.txt
   chmod 0400 /etc/IcculusFinger_dbpass.txt


Set up a cronjob to archive the plans. Here's a crontab entry for most Unixes
that archives plans every half-hour:

# This makes sure the .planfile archive is up to date...
0,30 * * * * /usr/local/bin/IcculusFinger_archiveplans.pl


Planfiles are only archived if they have been updated since the last time they
were archived (so as not to fill the database), and a certain amount of time
has elasped since the update took place (so as not to archive plans in the
middle of being edited, and limit the archiving of chatty users that feel the
need to continually update their plans). There is also a metatag users can put
in their planfiles to prevent archiving if only certain sections are changed.
For example, I keep various info in my .plan that doesn't change often, and
is significant when it does, but there's also a continually updated TODO
section, which isn't important when it changes. the [noarchive] tag covers the
TODO, so archiving won't happen if the only changes are in that section.

Questions and comments to icculus@icculus.org. Good luck.

# end of INSTALL ...

