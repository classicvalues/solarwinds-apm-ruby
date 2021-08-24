# frozen_string_literal: true

# Copyright (c) 2016 SolarWinds, LLC.
# All rights reserved.

require 'mkmf'
require 'rbconfig'
require 'open-uri'
require 'no_proxy_fix'

CONFIG['warnflags'] = CONFIG['warnflags'].gsub(/-Wdeclaration-after-statement/, '')
                        .gsub(/-Wimplicit-function-declaration/, '')
                        .gsub(/-Wimplicit-int/, '')
                        .gsub(/-Wno-tautological-compare/, '')
                        .gsub(/-Wno-self-assign/, '')
                        .gsub(/-Wno-parentheses-equality/, '')
                        .gsub(/-Wno-constant-logical-operand/, '')
                        .gsub(/-Wno-cast-function-type/, '')
init_mkmf(CONFIG)

ext_dir = File.expand_path(File.dirname(__FILE__))

# Check if we're running in JRuby
jruby = defined?(JRUBY_VERSION) ? true : false
# Set the mkmf lib paths so we have no issues linking to
# the AppOpticsAPM libs.
ao_lib_dir = File.join(ext_dir, 'lib')
ao_include = File.join(ext_dir, 'src')

# Download the appropriate liboboe from S3(via rake for testing) or files.appoptics.com (production)
version = File.read(File.join(ao_include, 'VERSION')).strip
if ENV['APPOPTICS_FROM_S3'].to_s.downcase == 'true'
  ao_path = File.join('https://rc-files-t2.s3-us-west-2.amazonaws.com/c-lib/', version)
  puts 'Fetching c-lib from S3'
else
  ao_path = File.join('https://files.appoptics.com/c-lib', version)
end

ao_arch = 'x86_64'
if File.exist?('/etc/alpine-release')
  version = File.read('/etc/alpine-release').strip

  ao_arch =
    if Gem::Version.new(version) < Gem::Version.new('3.9')
      'alpine-libressl-x86_64'
    else # openssl
      'alpine-x86_64'
    end
end

ao_clib = "liboboe-1.0-#{ao_arch}.so.0.0.0"
ao_item = File.join(ao_path, ao_clib)
ao_checksum_file = File.join(ao_lib_dir, "#{ao_clib}.sha256")
clib = File.join(ao_lib_dir, ao_clib)

retries = 3
success = false
while retries > 0
  begin
    download = RUBY_VERSION < '2.5.0' ? open(ao_item, 'rb') : URI.open(ao_item, 'rb')
    IO.copy_stream(download, clib)

    clib_checksum = Digest::SHA256.file(clib).hexdigest
    download.close
    checksum =  File.read(ao_checksum_file).strip

    # unfortunately these messages only show if the install command is run
    # with the `--verbose` flag
    if clib_checksum != checksum
      $stderr.puts '== ERROR ================================================================='
      $stderr.puts 'Checksum Verification failed for the c-extension of the appoptics_apm gem'
      $stderr.puts 'Installation cannot continue'
      $stderr.puts "\nChecksum packaged with gem:   #{checksum}"
      $stderr.puts "Checksum calculated from lib: #{clib_checksum}"
      $stderr.puts 'Contact technicalsupport@solarwinds.com if the problem persists'
      $stderr.puts '=========================================================================='
      exit 1
    else
      success = true
      retries = 0
    end
  rescue => e
    File.write(clib, '')
    retries -= 1
    if retries == 0
      $stderr.puts '== ERROR =========================================================='
      $stderr.puts 'Download of the c-extension for the appoptics_apm gem failed.'
      $stderr.puts 'appoptics_apm will not instrument the code. No tracing will occur.'
      $stderr.puts 'Contact technicalsupport@solarwinds.com if the problem persists.'
      $stderr.puts "error: #{ao_item}\n#{e.message}"
      $stderr.puts '==================================================================='
      create_makefile('oboe_noop', 'noop')
    end
    sleep 0.5
  end
end

if success
  # Create relative symlinks for the AppOpticsAPM library
  Dir.chdir(ao_lib_dir) do
    File.symlink(ao_clib, 'liboboe.so')
    File.symlink(ao_clib, 'liboboe-1.0.so.0')
  end

  dir_config('oboe', 'src', 'lib')

  # create Makefile
  if jruby || ENV.key?('APPOPTICS_URL')
    # Build the noop extension under JRuby and Heroku.
    # The oboe-heroku gem builds it's own c extension which links to
    # libs specific to a Heroku dyno
    # FIXME: For JRuby we need to remove the c extension entirely
    create_makefile('oboe_noop', 'noop')

  elsif have_library('oboe', 'oboe_config_get_revision', 'oboe.h')
    $libs = append_library($libs, 'oboe')
    $libs = append_library($libs, 'stdc++')

    $CFLAGS << " #{ENV['CFLAGS']}"
    # $CPPFLAGS << " #{ENV['CPPFLAGS']} -std=c++11"
    # TODO for debugging: -pg -gdwarf-2, remove for production
    # -pg does not work on alpine https://www.openwall.com/lists/musl/2014/11/05/2
    $CPPFLAGS << " #{ENV['CPPFLAGS']} -std=c++11  -gdwarf-2 -I$$ORIGIN/../ext/oboe_metal/include -I$$ORIGIN/../ext/oboe_metal/src"
    # $CPPFLAGS << " #{ENV['CPPFLAGS']} -std=c++11 -I$$ORIGIN/../ext/oboe_metal/include"
    $LIBS << " #{ENV['LIBS']}"

    # use "z,defs" to see what happens during linking
    # $LDFLAGS << " #{ENV['LDFLAGS']} '-Wl,-rpath=$$ORIGIN/../ext/oboe_metal/lib,-z,defs'  -lrt"
    $LDFLAGS << " #{ENV['LDFLAGS']} '-Wl,-rpath=$$ORIGIN/../ext/oboe_metal/lib' -lrt"
    $CXXFLAGS += " -std=c++11 "

    # ____ include debug info, comment out when not debugging
    # ____ -pg -> profiling info for gprof
    CONFIG["debugflags"] = "-ggdb3 "
    CONFIG["optflags"] = "-O0"

    create_makefile('libappoptics_apm', 'src')

  else
    $stderr.puts   '== ERROR ========================================================='
    if have_library('oboe')
      $stderr.puts "The c-library either needs to be updated or doesn't match the OS."
      $stderr.puts 'No tracing will occur.'
    else
      $stderr.puts 'Could not find a matching c-library. No tracing will occur.'
    end
    $stderr.puts   'Contact technicalsupport@solarwinds.com if the problem persists.'
    $stderr.puts   '=================================================================='
    create_makefile('oboe_noop', 'noop')
  end
end
