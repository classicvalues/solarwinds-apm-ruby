# Copyright (c) 2016 SolarWinds, LLC.
# All rights reserved.

# We configure and launch Sidekiq in a background
# thread here.
#
require 'sidekiq/cli'

SolarWindsAPM.logger.info "[appoptics_apm/servers] Starting up background Sidekiq for ActiveJob."

options = []
arguments = ""
options << ["-r", Dir.pwd + "/test/servers/sidekiq_activejob_initializer.rb"]
options << ["-q", "default"]
options << ["-c", "1"]

options.flatten.each do |x|
  arguments += " #{x}"
end
gemfile = ENV['BUNDLE_GEMFILE']

SolarWindsAPM.logger.warn "[appoptics_apm/servers] sidekiq #{arguments}"
SolarWindsAPM.logger.level = Logger::FATAL

Thread.new do
  system("APPOPTICS_GEM_TEST=true BUNDLE_GEMFILE=#{gemfile} sidekiq #{arguments}")
end

# Allow Sidekiq to boot up
sleep 10
