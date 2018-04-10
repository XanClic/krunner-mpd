Long description
================

First I was sad that KDE 5 ripped out a lot of the Amarok krunner integration.
Then I was sad that (under Arch Linux) everything that was left seemed to have
disappeared as well.

On my quest to find out how to restore it I noticed that apparently nobody cares
for Amarok anymore (;\_;7), so I looked for other music players that might be
well integrated into KDE again.  First I tried Babe, well, I didn’t like the
name and more importantly it crashed when it tried to load my library.  Maybe
the \u0000 in one of the file tags hat something to do with it...  Who cares.

So I went on, to Cantata with MPD.  That seemed to work, even though change
always bites you in the behind somehow (in this case among other things the
fact that it insists on splitting albums by artists, so I had to update quite a
lot of files with “Various” as their album artist), but, well.  Anyway, sadly I
had to see that this still wouldn’t give me nice krunner integration.

But I guessed that MPD would be designed in a way to allow me to easily
interface it and do whatever simple things I wanted to do.  Things like
`mpc insert "$(mpc search title 告白)"; mpc next` for instance.

And lo and behold, as of recently krunner can use dbus to load modules from
different processes!  So I won’t even have to curse at Qt all the time.


Short description
=================

Thus, I wrote this, a krunner module for controlling the default local MPD
instance.


Short feature list
==================

- Simple commands like `play`, `pause`, `previous`, `next`
- If you just enter something, it will look for hits in your music DB and then
  allows you to choose between the results – your choice will be inserted after
  the current track and played immediately
  - If there already is a matching track in your playlist, you can choose to
    instead jump there
- Prefixing search queries by `queue` allows you to add tracks at the end of the
  playlist without jumping there
  - `queue album` queues whole albums
- `anything by` gives you a random song by some artist, `anything on` gives you
  a random song from a random album

Oh, and by the way, even if you’re not on an English system, the commands are
still the same.  That’s because I personally always hate guessing whatever the
translator has come up with now (whereas the English terms are usually rather
consistent), and secondly because “queue X” in German would be “hänge X an” –
and I’d get crazy both as a developer and a user if I had to either use infix
notation or come up with a hack to get around it (like “Anhängen von X”).


Installation
============

The usual:

    $ mkdir build
    $ cd build
    $ ../configure --prefix=$PREFIX
    $ make
    $ sudo make install

This copies the plugin to `$PREFIX/bin`, the locale files to
`$PREFIX/share/krunner-mpd/locales`, a .desktop file for krunner to the
kservices directory, and a DBus .service file to `/usr/share/dbus-1/services`.
After that, restart krunner and everything should work (though maybe you need to
enable the plugin in the krunner settings).
