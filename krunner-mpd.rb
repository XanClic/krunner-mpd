#!/usr/bin/ruby

require 'dbus'
require 'i18n'
require 'locale'
require 'ruby-mpd'


MATCH_NONE = 0
MATCH_COMPLETION = 10
MATCH_POSSIBLE = 30
MATCH_INFORMATIONAL = 50
MATCH_HELPER = 70
MATCH_COMPLETE = 100


I18n.load_path << Dir[File.dirname(__FILE__) + '/locales/*.yml']
candidates = Locale.candidates.map { |c| c.to_s } + ['en']
candidates.each do |c|
    begin
        I18n.locale = c
        break
    rescue
    end
end


args = ARGV.to_a

host = args.shift
host = host ? host : 'localhost'

port = args.shift
port = port ? Integer(port) : 6600

$mpd = MPD.new(host, port)
$mpd.connect


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


def do_play(_)
    $mpd.play
end

def do_pause(_)
    $mpd.pause = true
end

def do_resume(_)
    $mpd.pause = false
end

def do_prev(_)
    $mpd.previous
end

def do_next(_)
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

    $mpd.where(title: title).sort { |x, y|
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
        [FIND_MEDIA[:action_prefix] + result.file, FIND_MEDIA[:description].sub('\s', "#{result.artist} (#{result.album}): #{result.title}"), 'media-playback-start', MATCH_POSSIBLE, prob, {}]
    }[0..9]
end

def found_media(file, _)
    id = $mpd.addid(file)
    $mpd.move({id: id}, -1) unless $mpd.stopped?
    $mpd.play({id: id})
end

def find_in_playlist(title)
    title.remove_spaced_prefix!('play')
    title.remove_spaced_prefix!('jump to')

    $mpd.queue_where(title: title).sort { |x, y|
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
        [FIND_IN_PLAYLIST[:action_prefix] + result.id.to_s, FIND_IN_PLAYLIST[:description].sub('\s', "#{result.artist} (#{result.album}): #{result.title}"), 'media-playback-start', MATCH_POSSIBLE, prob, {}]
    }[0..9]
end

def found_in_playlist(id, _)
    $mpd.play({id: id.to_i})
end

def find_queue(title)
    if !title.remove_spaced_prefix!('queue') && !title.remove_spaced_prefix!('enqueue')
        return []
    end

    $mpd.where(title: title).sort { |x, y|
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
        [QUEUE[:action_prefix] + result.file, QUEUE[:description].sub('\s', "#{result.artist} (#{result.album}): #{result.title}"), 'media-playback-start', MATCH_COMPLETION, prob, {}]
    }[0..9]
end

def do_queue(file, _)
    id = $mpd.addid(file)
    $mpd.play({id: id}) if $mpd.stopped?
end

def find_queue_album(album)
    if !album.remove_spaced_prefix!('queue') && !album.remove_spaced_prefix!('enqueue')
        return []
    end
    album.remove_spaced_prefix!('album')

    result_hash = {}
    $mpd.where(album: album).each { |result|
        artist = result.albumartist ? result.albumartist : result.artist
        result_hash[result.album] = artist
    }

    result_hash.keys.sort.map { |real_album|
        artist = result_hash[real_album]
        artist = I18n.t(:unknown_artist) unless artist
        prob = (real_album == album) ? 1.0 : 0.8
        [QUEUE_ALBUM[:action_prefix] + real_album, QUEUE_ALBUM[:description].sub('\al', real_album).sub('\ar', artist), 'folder', MATCH_COMPLETION, prob, {}]
    }[0..9]
end

def do_queue_album(album, _)
    ids = $mpd.where({album: album}, {strict: true}).sort { |x, y|
        x.track <=> y.track
    }.map { |song|
        $mpd.addid(song)
    }
    $mpd.play({id: ids[0]}) if $mpd.stopped? && ids[0]
end

def lookup_artist_random_song(artist)
    artist.remove_spaced_prefix!('play')
    if !artist.remove_spaced_prefix!('anything by') && !artist.remove_spaced_prefix!('anything from')
        return []
    end

    grouped = {}
    $mpd.where(artist: artist).each { |result|
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

    grouped = {}
    $mpd.where(album: album).each { |result|
        grouped[result.album] = [] unless grouped[result.album]
        grouped[result.album] << result
    }

    grouped.keys.sort.map { |key|
        sample = grouped[key].sample
        prob = (key == album) ? 1.0 : 0.9
        [RANDOM_BY_ALBUM[:action_prefix] + sample.file, RANDOM_BY_ALBUM[:description].sub('\s', key), 'media-playback-start', MATCH_COMPLETION, prob, {}]
    }[0..9]
end


ACTIONS = [PLAY, PAUSE, RESUME, PREV, PREVIOUS, NEXT,
           FIND_IN_PLAYLIST, FIND_MEDIA, QUEUE, QUEUE_ALBUM, RANDOM_BY_ARTIST, RANDOM_BY_ALBUM]


class DBusInterface < DBus::Object
    dbus_interface 'org.kde.krunner1' do
        dbus_method :Actions, 'in msg:v, out return:a(sss)' do |msg|
            p msg
            #return [ACTIONS.map { |action| [action[:action], action[:description], action[:icon]] }]
            return [[]]
        end

        dbus_method :Match, 'in query:s, out return:a(sssida{sv})' do |query|
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
                return [result]
            rescue Interrupt
                throw
            rescue Exception => e
                $stderr.puts e.inspect
                $stderr.puts e.backtrace
                $stderr.puts
                return [[]]
            end
        end

        dbus_method :Run, 'in match:s, in signature:s' do |match, signature|
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
        end
    end
end

dbus = DBus.session_bus
service = dbus.request_service('moe.xanclic.krunner-mpd')

obj = DBusInterface.new('/krunner')
service.export(obj)

dbus_loop = DBus::Main.new
dbus_loop << dbus
dbus_loop.run
