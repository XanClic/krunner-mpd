#!/usr/bin/ruby

require 'dbus'
require 'i18n'
require 'locale'
require 'ruby-mpd'
require 'yaml'


# --------------------------------------------------------------------
# Global constants
# --------------------------------------------------------------------


# Replaced by make (using the replace-assets-path.rb script)
ASSETS_PATH = File.dirname(__FILE__)

CONFIG_FILE = ENV['HOME'] + '/.config/krunner-mpd/config.yaml'


PID_DIR = ENV['XDG_RUNTIME_DIR'] ? ENV['XDG_RUNTIME_DIR'] : "/var/run/user/#{Process::UID.eid}"
PID_FILE = "#{PID_DIR}/krunner-mpd.pid"


MATCH_NONE = 0
MATCH_COMPLETION = 10
MATCH_POSSIBLE = 30
MATCH_INFORMATIONAL = 50
MATCH_HELPER = 70
MATCH_COMPLETE = 100


# --------------------------------------------------------------------
# Important general functions
# --------------------------------------------------------------------


LOG_DEBUG       = 0
LOG_INFO        = 1
LOG_WARNING     = 2
LOG_ERROR       = 3
LOG_CRITICAL    = 4

LOG_LEVEL_STRING = {
    LOG_DEBUG       => 'Debug',
    LOG_INFO        => 'Info',
    LOG_WARNING     => 'Warning',
    LOG_ERROR       => 'Error',
    LOG_CRITICAL    => 'Critical',
}

def log(log_level, message)
    if log_level < $log_level
        return
    end

    time = Time.now.inspect
    lines = message.split($/).map { |line|
        "[#{time}] #{LOG_LEVEL_STRING[log_level]}: #{line}"
    }

    $log_file.puts(lines * $/)
    $log_file.flush
end

def die(message)
    $log_level = 0
    log(LOG_CRITICAL, message)
    exit 1
end


def format_host_port(host, port)
    if host.include?(':')
        "[#{host}]:#{port}"
    else
        "#{host}:#{port}"
    end
end


# --------------------------------------------------------------------
# Load i18n files
# --------------------------------------------------------------------


I18n.load_path << Dir[ASSETS_PATH + '/locales/*.yml']
candidates = Locale.candidates.map { |c| c.to_s } + ['en']
candidates.each do |c|
    begin
        I18n.locale = c
        break
    rescue
    end
end


# --------------------------------------------------------------------
# Fetch parameters from the config file and the command line
# --------------------------------------------------------------------


# Lowest proprity: Built-in defaults
host = 'localhost'
port = 6600

log_filename = nil
$log_file = $stderr
log_truncate = true
$log_level = LOG_WARNING


# Middle priority: Config file
begin
    config_file = File.open(CONFIG_FILE)
rescue Exception => e
    config = nil
else
    config = YAML.load(config_file)
end


if config
    if config['mpd']
        host = String(config['mpd']['host']) if config['mpd']['host'] != nil
        port = Integer(config['mpd']['port']) if config['mpd']['port'] != nil
    end

    if config['debug']
        log_filename = String(config['debug']['log_file']) if config['debug']['log_file'] != nil
        log_truncate = config['debug']['log_truncate'] if config['debug']['log_truncate'] != nil
        if ![true, false].include?(log_truncate)
            die('log_truncate must be true or false')
        end

        $log_level = nil
        log_level_string = String(config['debug']['log_level']) if config['debug']['log_level'] != nil
        LOG_LEVEL_STRING.each do |num, str|
            if str.casecmp(log_level_string) == 0
                $log_level = num
                break
            end
        end
        if !$log_level
            die("Invalid log level “#{log_level_string}”")
        end
    end
end


# Highest priority: Command-line arguments
args = ARGV.to_a

arg_host = args.shift
host = arg_host if arg_host

arg_port = args.shift
port = Integer(arg_port) if arg_port


# --------------------------------------------------------------------
# Initiate debugging
# --------------------------------------------------------------------


if log_filename
    $log_file = File.open(log_filename, log_truncate ? 'w' : 'a')
end

log(LOG_INFO, '--- Commencing log ---')


# --------------------------------------------------------------------
# Connect to MPD
# --------------------------------------------------------------------


$mpd = MPD.new(host, port)

retry_count = 0
while true
    begin
        $mpd.connect
    rescue Errno::ECONNREFUSED => e
        retry_count += 1
        raise if retry_count == 10

        sleep(1)
        retry
    else
        break
    end
end


log(LOG_INFO, "Connected to MPD on #{format_host_port(host, port)}")


# --------------------------------------------------------------------
# Fork off the main process and write a PID file
# --------------------------------------------------------------------


child_pid = fork
if child_pid
    begin
        File.write(PID_FILE, child_pid.to_s)
    rescue Exception => e
        log(LOG_WARNING, 'Failed to write PID file:')
        log(LOG_WARNING, e.message)
    end

    log(LOG_INFO, "Forked child (PID #{child_pid}), parent exiting")

    exit 0
end


# --------------------------------------------------------------------
# Ensure the PID file is cleaned up on exit
# --------------------------------------------------------------------


# Perform a normal exit when a termination signal is received...
['HUP', 'INT', 'TERM', 'USR1', 'USR2', 'ALRM', 'PIPE', 'POLL', 'PROF'].each do |signal|
    Signal.trap(signal) do
        log(LOG_INFO, "Received SIG#{signal}")
        exit 0
    end
end

# ...so that the PID file is cleaned up.  (Among other things.)
at_exit do
    begin
        File.delete(PID_FILE)

        log(LOG_INFO, 'Exiting')
        $log_file.close
    rescue Exception => e
    end
end


# --------------------------------------------------------------------
# This ends the main part of the initialization.  We still need to set
# up the DBus interface and enter the main loop, both of which is done
# at the bottom of this file.
# --------------------------------------------------------------------


# --------------------------------------------------------------------
# The actions that can be performed with this runner
# --------------------------------------------------------------------

# Structure of an action definition:
#   cmd:            Either a simple string that is the cmd the user
#                   can use through krunner to launch this action; or
#                   nil, in which case there must be a :match key.
#
#   action:         If :cmd is set, this specifies how the action
#                   should be identified to krunner.  (So this is just
#                   some ID string.)
#                   Without :cmd set, you probably want to use
#                   :action_prefix instead.
#
#   description:    The action description.  This is what the user
#                   sees in the krunner action list.  This is only
#                   necessary for actions with a :cmd key, though
#                   others may make internal use of it as well.  They
#                   will usually do some processing on it before
#                   the :match function returns the real description,
#                   though (like replace "\s" by a song name).
#
#   icon:           The icon to display in the action list.  Again,
#                   only strictly necessary for actions with :cmd set,
#                   but others may make internal ue of it.
#
#   execute:        Name of the function to execute once the action
#                   should be run.
#                   If :action is set, that function takes one
#                   argument, which is the krunner action ID.
#                   (krunner actions are different from these actions
#                    here.  A runner can implement multiple actions
#                    for a single match, and then the user will see
#                    little buttons next to the match and can thus
#                    choose between different actions.  This plugin
#                    does not make use of that yet.)
#                   If :action_prefix is set, that function takes two
#                   arguments.  The first one is the action ID without
#                   the prefix, the second one is the krunner aciton
#                   ID.
#
#   action_prefix:  If :action is not set, this specifies a common
#                   prefix that all action IDs returned by this
#                   action's :match function share.
#
#   match:          If :cmd is not set, this allows specifying a
#                   custom matching function.  That function receives
#                   the whole user input string and is supposed to
#                   return exactly the object that is returned to
#                   krunner via DBus.  This object is an array with
#                   the following entries:
#                   [0]: action ID (must be prefixed by
#                                   :action_prefix)
#                   [1]: description string
#                   [2]: icon name
#                   [3]: match type (MATCH_* constants)
#                   [4]: match relevance (in [0.0, 1.0])
#                   [5]: "properties" object (I don't know, something
#                        with keys "urls", "category", and "subtext")

PLAY = {
    cmd: 'play',
    action: 'play',
    description: I18n.t('play_desc'),
    icon: 'media-playback-start',
    execute: :do_play,
}

RESUME = {
    cmd: 'resume',
    action: 'resume',
    description: I18n.t('resume_desc'),
    icon: 'media-playback-start',
    execute: :do_resume,
}

PAUSE = {
    cmd: 'pause',
    action: 'pause',
    description: I18n.t('pause_desc'),
    icon: 'media-playback-pause',
    execute: :do_pause,
}

PREV = {
    cmd: 'prev',
    action: 'prev',
    description: I18n.t('prev_desc'),
    icon: 'media-skip-backward',
    execute: :do_prev,
}

PREVIOUS = {
    cmd: 'previous',
    action: 'previous',
    description: I18n.t('prev_desc'),
    icon: 'media-skip-backward',
    execute: :do_prev,
}

NEXT = {
    cmd: 'next',
    action: 'next',
    description: I18n.t('next_desc'),
    icon: 'media-skip-forward',
    execute: :do_next,
}

FIND_MEDIA = {
    cmd: nil,
    description: I18n.t('find_desc'),
    action_prefix: '!fm ',
    match: :find_media,
    execute: :found_media,
}

FIND_IN_PLAYLIST = {
    cmd: nil,
    description: I18n.t('jump_desc'),
    action_prefix: '!fpl ',
    match: :find_in_playlist,
    execute: :found_in_playlist,
}

QUEUE = {
    cmd: nil,
    description: I18n.t('queue_desc'),
    action_prefix: '!q ',
    match: :find_queue,
    execute: :do_queue,
}

QUEUE_ALBUM = {
    cmd: nil,
    description: I18n.t('queue_album_desc'),
    action_prefix: '!qal ',
    match: :find_queue_album,
    execute: :do_queue_album,
}

RANDOM_BY_ARTIST = {
    cmd: nil,
    description: I18n.t('random_by_artist_desc'),
    action_prefix: '!rar ',
    match: :lookup_artist_random_song,
    execute: :found_media,
}

RANDOM_BY_ALBUM = {
    cmd: nil,
    description: I18n.t('random_by_album_desc'),
    action_prefix: '!ral ',
    match: :lookup_album_random_song,
    execute: :found_media,
}


# --------------------------------------------------------------------
# Implementation of the above actions
# --------------------------------------------------------------------


def do_play(_)
    log(LOG_DEBUG, 'Function: do_play()')
    log(LOG_DEBUG, 'MPD request: play()')
    $mpd.play
end

def do_pause(_)
    log(LOG_DEBUG, 'Function: do_pause()')
    log(LOG_DEBUG, 'MPD request: pause = true')
    $mpd.pause = true
end

def do_resume(_)
    log(LOG_DEBUG, 'Function: do_resume()')
    log(LOG_DEBUG, 'MPD request: pause = false')
    $mpd.pause = false
end

def do_prev(_)
    log(LOG_DEBUG, 'Function: do_prev()')
    log(LOG_DEBUG, 'MPD request: previous()')
    $mpd.previous
end

def do_next(_)
    log(LOG_DEBUG, 'Function: do_next()')
    log(LOG_DEBUG, 'MPD request: next()')
    $mpd.next
end

class String
    def remove_spaced_prefix!(prefix)
        if self.start_with?(prefix + ' ')
            replace(self[prefix.length..-1].lstrip)
            return true
        else
            return false
        end
    end
end

def find_media(title)
    title.remove_spaced_prefix!('play')

    log(LOG_DEBUG, "Function: find_media(#{title.inspect})")

    log(LOG_DEBUG, "MPD request: where(title: #{title.inspect})")
    result = $mpd.where(title: title)
    log(LOG_DEBUG, " -> #{result.inspect}")

    result.sort { |x, y|
        xprio = (x.title == title)
        yprio = (y.title == title)
        if xprio == yprio
            x.title <=> y.title
        elsif xprio
            0
        else
            1
        end
    }.map { |result|
        prob = (result.title == title) ? 0.5 : 0.3

        if result.artist && result.album
            song = "#{result.artist} (#{result.album}): #{result.title}"
        elsif result.artist
            song = "#{result.artist}: #{result.title}"
        elsif result.album
            song = "#{result.album}: #{result.title}"
        else
            song = result.title
        end

        [FIND_MEDIA[:action_prefix] + result.file, FIND_MEDIA[:description].sub('\s', song), 'media-playback-start', MATCH_POSSIBLE, prob, {}]
    }[0..9]
end

def found_media(file, _)
    log(LOG_DEBUG, "Function: found_media(#{file.inspect})")

    log(LOG_DEBUG, "MPD request: addid(#{file.inspect}")
    id = $mpd.addid(file)
    log(LOG_DEBUG, " -> #{id.inspect}")
    unless $mpd.stopped?
        log(LOG_DEBUG, "MPD request: move({id: #{id}}, -1)")
        $mpd.move({id: id}, -1)
    end
    log(LOG_DEBUG, "MPD request: play({id: #{id}})")
    $mpd.play({id: id})
end

def find_in_playlist(title)
    title.remove_spaced_prefix!('play')
    title.remove_spaced_prefix!('jump to')

    log(LOG_DEBUG, "Function: find_in_playlist(#{title.inspect})")

    log(LOG_DEBUG, "MPD request: where_queue(title: #{title.inspect})")
    result = $mpd.queue_where(title: title)
    log(LOG_DEBUG, " -> #{result.inspect}")
    result.sort { |x, y|
        xprio = (x.title == title)
        yprio = (y.title == title)
        if xprio == yprio
            x.title <=> y.title
        elsif xprio
            0
        else
            1
        end
    }.map { |result|
        prob = (result.title == title) ? 0.9 : 0.7

        if result.artist && result.album
            song = "#{result.artist} (#{result.album}): #{result.title}"
        elsif result.artist
            song = "#{result.artist}: #{result.title}"
        elsif result.album
            song = "#{result.album}: #{result.title}"
        else
            song = result.title
        end

        [FIND_IN_PLAYLIST[:action_prefix] + result.id.to_s, FIND_IN_PLAYLIST[:description].sub('\s', song), 'media-playback-start', MATCH_POSSIBLE, prob, {}]
    }[0..9]
end

def found_in_playlist(id, _)
    log(LOG_DEBUG, "Function: found_in_playlist(#{id.inspect})")

    log(LOG_DEBUG, "MPD request: play({id: #{id}})")
    $mpd.play({id: id.to_i})
end

def find_queue(title)
    if !title.remove_spaced_prefix!('queue') && !title.remove_spaced_prefix!('enqueue')
        return []
    end

    log(LOG_DEBUG, "Function: find_queue(#{title.inspect})")

    log(LOG_DEBUG, "MPD request: where(title: #{title.inspect})")
    result = $mpd.where(title: title)
    log(LOG_DEBUG, " -> #{result.inspect}")
    result.sort { |x, y|
        xprio = (x.title == title)
        yprio = (y.title == title)
        if xprio == yprio
            x.title <=> y.title
        elsif xprio
            0
        else
            1
        end
    }.map { |result|
        prob = (result.title == title) ? 1.0 : 0.8

        if result.artist && result.album
            song = "#{result.artist} (#{result.album}): #{result.title}"
        elsif result.artist
            song = "#{result.artist}: #{result.title}"
        elsif result.album
            song = "#{result.album}: #{result.title}"
        else
            song = result.title
        end

        [QUEUE[:action_prefix] + result.file, QUEUE[:description].sub('\s', song), 'media-playback-start', MATCH_COMPLETION, prob, {}]
    }[0..9]
end

def do_queue(file, _)
    log(LOG_DEBUG, "Function: do_queue(#{file.inspect})")

    log(LOG_DEBUG, "MPD request: addid(#{file.inspect}")
    id = $mpd.addid(file)
    log(LOG_DEBUG, " -> #{id.inspect}")

    if $mpd.stopped?
        log(LOG_DEBUG, "MPD request: play({id: #{id}})")
        $mpd.play({id: id})
    end
end

def find_queue_album(album)
    if !album.remove_spaced_prefix!('queue') && !album.remove_spaced_prefix!('enqueue')
        return []
    end
    album.remove_spaced_prefix!('album')

    log(LOG_DEBUG, "Function: find_queue_album(#{album.inspect})")

    result_hash = {}
    log(LOG_DEBUG, "MPD request: where(album: #{album.inspect})")
    result = $mpd.where(album: album)
    log(LOG_DEBUG, " -> #{result.inspect}")
    result.each { |result|
        artist = result.albumartist ? result.albumartist : result.artist
        result_hash[result.album] = artist
    }

    result_hash.keys.sort.map { |real_album|
        artist = result_hash[real_album]
        artist = I18n.t(:unknown_artist) unless artist
        prob = (real_album == album) ? 0.95 : 0.75
        [QUEUE_ALBUM[:action_prefix] + real_album, QUEUE_ALBUM[:description].sub('\al', real_album).sub('\ar', artist), 'folder', MATCH_COMPLETION, prob, {}]
    }[0..9]
end

def do_queue_album(album, _)
    log(LOG_DEBUG, "Function: do_queue_album(#{album.inspect})")

    log(LOG_DEBUG, "MPD request: where(album: #{album.inspect}, {strict: true})")
    result = $mpd.where({album: album}, {strict: true})
    log(LOG_DEBUG, " -> #{result.inspect}")
    ids = result.sort { |x, y|
        if x.track && y.track
            x.track <=> y.track
        elsif x.track
            -1
        elsif y.track
            1
        else
            0
        end
    }.map { |song|
        log(LOG_DEBUG, "MPD request: addid(#{song})")
        $mpd.addid(song)
    }

    if $mpd.stopped? && ids[0]
        log(LOG_DEBUG, "MPD request: play({id: #{ids[0]}})")
        $mpd.play({id: ids[0]})
    end
end

def lookup_artist_random_song(artist)
    artist.remove_spaced_prefix!('play')
    if !artist.remove_spaced_prefix!('anything by') && !artist.remove_spaced_prefix!('anything from')
        return []
    end

    log(LOG_DEBUG, "Function: lookup_artist_random_song(#{artist.inspect})")

    grouped = {}
    log(LOG_DEBUG, "MPD request: where(artist: #{artist.inspect})")
    result = $mpd.where(artist: artist)
    log(LOG_DEBUG, " -> #{result.inspect}")
    result.each { |result|
        grouped[result.artist] = [] unless grouped[result.artist]
        grouped[result.artist] << result
    }

    grouped.keys.sort.map { |key|
        sample = grouped[key].sample
        prob = (key == artist) ? 1.0 : 0.9
        [RANDOM_BY_ARTIST[:action_prefix] + sample.file, RANDOM_BY_ARTIST[:description].sub('\s', key), 'media-playback-start', MATCH_COMPLETION, prob, {}]
    }[0..9]
end

def lookup_album_random_song(album)
    album.remove_spaced_prefix!('play')
    if !album.remove_spaced_prefix!('anything on') && !album.remove_spaced_prefix!('anything from')
        return []
    end

    log(LOG_DEBUG, "Function: lookup_album_random_song(#{album.inspect})")

    grouped = {}
    log(LOG_DEBUG, "MPD request: where(album: #{album.inspect})")
    result = $mpd.where(album: album)
    log(LOG_DEBUG, " -> #{result.inspect}")
    result.each { |result|
        grouped[result.album] = [] unless grouped[result.album]
        grouped[result.album] << result
    }

    grouped.keys.sort.map { |key|
        sample = grouped[key].sample
        prob = (key == album) ? 1.0 : 0.9
        [RANDOM_BY_ALBUM[:action_prefix] + sample.file, RANDOM_BY_ALBUM[:description].sub('\s', key), 'media-playback-start', MATCH_COMPLETION, prob, {}]
    }[0..9]
end


# --------------------------------------------------------------------
# End of the action implementation: List of all actions
# --------------------------------------------------------------------


ACTIONS = [PLAY, PAUSE, RESUME, PREV, PREVIOUS, NEXT,
           FIND_IN_PLAYLIST, FIND_MEDIA, QUEUE, QUEUE_ALBUM, RANDOM_BY_ARTIST, RANDOM_BY_ALBUM]


# --------------------------------------------------------------------
# DBus interface to krunner
# --------------------------------------------------------------------


class DBusInterface < DBus::Object
    def initialize(path)
        @debug_id = 0
        super(path)
    end

    dbus_interface 'org.kde.krunner1' do
        dbus_method :Actions, 'in msg:v, out return:a(sss)' do |msg|
            debug_id = @debug_id
            @debug_id += 1

            log(LOG_DEBUG, "D-Bus :Actions[#{debug_id}](#{msg.inspect})")

            #return [ACTIONS.map { |action| [action[:action], action[:description], action[:icon]] }]
            log(LOG_DEBUG, "D-Bus :Actions[#{debug_id}] -> [[]]")
            return [[]]
        end

        dbus_method :Match, 'in query:s, out return:a(sssida{sv})' do |query|
            debug_id = @debug_id
            @debug_id += 1

            log(LOG_DEBUG, "D-Bus :Match[#{debug_id}](#{query.inspect})")

            begin
                result = []
                ACTIONS.each do |action|
                    if query == action[:cmd]
                        result << [action[:action], action[:description], action[:icon], MATCH_COMPLETE, 1.0, {}]
                    end
                end
                ACTIONS.each do |action|
                    if action[:match]
                        result += send(action[:match], query.dup)
                    end
                end

                log(LOG_DEBUG, "D-Bus :Match[#{debug_id}] -> [#{result.inspect}]")
                return [result]
            rescue Interrupt
                throw
            rescue Exception => e
                log(LOG_ERROR, 'Exception while matching: ' + e.inspect)
                log(LOG_ERROR, e.backtrace * $/)
                log(LOG_DEBUG, "D-Bus :Match[#{debug_id}] -> [[]]")
                return [[]]
            end
        end

        dbus_method :Run, 'in match:s, in signature:s' do |match, signature|
            debug_id = @debug_id
            @debug_id += 1

            log(LOG_DEBUG, "D-Bus :Run[#{debug_id}](#{match.inspect}, #{signature.inspect})")

            begin
                ACTIONS.each do |action|
                    if match == action[:action] && action[:execute]
                        send(action[:execute], signature.dup)
                        return
                    end
                    if action[:action_prefix] && match.start_with?(action[:action_prefix]) && action[:execute]
                        send(action[:execute], match[action[:action_prefix].length..-1], signature.dup)
                        return
                    end
                end
            rescue Interrupt
                throw
            rescue Exception => e
                log(LOG_ERROR, 'Exception while executing: ' + e.inspect)
                log(LOG_ERROR, e.backtrace * $/)
            end

            log(LOG_DEBUG, "D-Bus :Run[#{debug_id}] -> nil")
            return nil
        end
    end
end


# --------------------------------------------------------------------
# Continuation of top-level code: Create the DBus interface and enter
# the main loop
# --------------------------------------------------------------------


dbus = DBus.session_bus
service = dbus.request_service('moe.xanclic.krunner-mpd')

obj = DBusInterface.new('/krunner')
service.export(obj)

log(LOG_INFO, 'D-Bus service exported, entering main loop')

dbus_loop = DBus::Main.new
dbus_loop << dbus
dbus_loop.run
