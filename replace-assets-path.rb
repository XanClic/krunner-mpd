#!/usr/bin/ruby

args = ARGV.to_a

assets_path = args.shift
if !assets_path
    $stderr.puts('Assets path argument missing')
    exit 1
end

if !args.empty?
    $stderr.puts('Too many arguments')
    exit 1
end

while gets
    if $_ =~ /^\s*ASSETS_PATH\s*=/
        puts("ASSETS_PATH = #{assets_path.inspect}")
    else
        puts($_)
    end
end
