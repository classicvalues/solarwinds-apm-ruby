# Copyright (c) 2016 SolarWinds, LLC.
# All rights reserved.

require 'minitest_helper'
require 'sidekiq'

Sidekiq.configure_server do |config|
  config.redis = { :password => ENV['REDIS_PASSWORD'] || 'secret_pass' }
  if ENV.key?('REDIS_HOST')
    config.redis << { :url => "redis://#{ENV['REDIS_HOST']}:6379" }
  end
end

require_relative "../jobs/sidekiq/remote_call_worker_job"
require_relative "../jobs/sidekiq/db_worker_job"
require_relative "../jobs/sidekiq/error_worker_job"

describe "SidekiqWorkerTest" do
  before do
    @collect_backtraces = SolarWindsAPM::Config[:sidekiqworker][:collect_backtraces]
    @log_args = SolarWindsAPM::Config[:sidekiqworker][:log_args]

    clear_all_traces
    # not a request entry point, context set up in test with start_trace
    SolarWindsAPM::Context.clear
  end

  after do
    SolarWindsAPM::Config[:sidekiqworker][:collect_backtraces] = @collect_backtraces
    SolarWindsAPM::Config[:sidekiqworker][:log_args] = @log_args
  end

  def test_reports_version_init
    init_kvs = SolarWindsAPM::Util.build_init_report
    assert init_kvs.key?('Ruby.sidekiq.Version')
    assert_equal ::Sidekiq::VERSION, init_kvs['Ruby.sidekiq.Version']
  end

  def test_job_run
    # Queue up a job to be run
    jid = Sidekiq::Client.push('queue' => 'critical', 'class' => RemoteCallWorkerJob, 'args' => [1, 2, 3], 'retry' => false)

    # Allow the job to be run
    sleep 3

    traces = get_all_traces
    assert_equal 12, traces.count, filter_traces(traces).pretty_inspect
    validate_outer_layers(traces, "sidekiq-worker")
    assert valid_edges?(traces), "Invalid edge in traces"

    # Validate entry layer KVs
    assert_equal true,             traces[0].key?('SampleRate'),   "has SampleRate KV"
    assert_equal true,             traces[0].key?('SampleSource'), "has SampleSource KV"

    # Validate Webserver Spec KVs
    assert_equal Socket.gethostname,    traces[0]['HTTP-Host']
    assert_equal "Sidekiq_critical",    traces[0]['Controller']
    assert_equal "RemoteCallWorkerJob", traces[0]['Action']
    assert_equal "/sidekiq/critical/RemoteCallWorkerJob", traces[0]['URL']

    # Validate Job Spec KVs
    assert_equal "job",                 traces[0]['Spec']
    assert_equal 'sidekiq',             traces[0]['Flavor']
    assert_equal "RemoteCallWorkerJob", traces[0]['JobName']
    assert_equal jid,                   traces[0]['MsgID']
    assert_equal "critical",            traces[0]['Queue']
    assert_equal "[1, 2, 3]",           traces[0]['Args']
    assert_equal "false",               traces[0]['Retry']
    assert_equal false,                 traces[0].key?('Backtrace')
    assert_equal "net-http",            traces[4]['Layer']
    assert_equal "exit",               traces[4]['Label']
    assert_equal "memcache",            traces[10]['Layer']
  end

  def test_jobs_with_errors
    # Queue up a job to be run
    jid = Sidekiq::Client.push('queue' => 'critical', 'class' => ErrorWorkerJob, 'args' => [1, 2, 3], 'retry' => false)

    # Allow the job to be run
    sleep 5

    traces = get_all_traces
    assert_equal 3, traces.count, filter_traces(traces).pretty_inspect
    validate_outer_layers(traces, "sidekiq-worker")
    assert valid_edges?(traces), "Invalid edge in traces"

    # Validate Webserver Spec KVs
    assert_equal Socket.gethostname,                  traces[0]['HTTP-Host']
    assert_equal "Sidekiq_critical",                  traces[0]['Controller']
    assert_equal "ErrorWorkerJob",                    traces[0]['Action']
    assert_equal "/sidekiq/critical/ErrorWorkerJob",  traces[0]['URL']

    # Validate Job Spec KVs
    assert_equal "job",             traces[0]['Spec']
    assert_equal 'sidekiq',         traces[0]['Flavor']
    assert_equal "ErrorWorkerJob",  traces[0]['JobName']
    assert_equal jid,               traces[0]['MsgID']
    assert_equal "critical",        traces[0]['Queue']
    assert_equal "[1, 2, 3]",       traces[0]['Args']
    assert_equal "false",           traces[0]['Retry']

    assert_equal traces[1]['Layer'], 'sidekiq-worker'
    assert_equal traces[1]['Label'], 'error'
    assert_equal traces[1]['Spec'], 'error'
    assert_equal traces[1]['ErrorClass'], "RuntimeError"
    assert_equal 1, traces.select { |trace| trace['Label'] == 'error' }.count

    assert traces[1].key?('ErrorMsg')
    assert traces[1].key?('Backtrace')
  end

  def test_collect_backtraces_default_value
    assert_equal SolarWindsAPM::Config[:sidekiqworker][:collect_backtraces], false, "default backtrace collection"
  end

  def test_log_args_default_value
    assert_equal SolarWindsAPM::Config[:sidekiqworker][:log_args], true, "log_args default "
  end

  def test_obey_collect_backtraces_when_false
    SolarWindsAPM::Config[:sidekiqworker][:collect_backtraces] = false

    # Queue up a job to be run
    Sidekiq::Client.push('queue' => 'critical', 'class' => ::RemoteCallWorkerJob, 'args' => [1, 2, 3], 'retry' => false)

    # Allow the job to be run
    sleep 5

    traces = get_all_traces
    assert_equal 12, traces.count, filter_traces(traces).pretty_inspect
    assert valid_edges?(traces), "Invalid edge in traces"
    assert_equal 'sidekiq-worker',   traces[0]['Layer']
    assert_equal false,              traces[0].key?('Backtrace')
  end

  def test_transaction_name
    SolarWindsAPM::Config[:sidekiqworker][:collect_backtraces] = false

    # Queue up a job to be run
    Sidekiq::Client.push('queue' => 'critical', 'class' => ::RemoteCallWorkerJob, 'args' => [1, 2, 3], 'retry' => false)

    # Allow the job to be run
    sleep 5

    traces = get_all_traces
    assert_equal 12, traces.count, filter_traces(traces).pretty_inspect
    assert valid_edges?(traces), "Invalid edge in traces"
    assert_equal 'sidekiq-worker',   traces[0]['Layer']
    assert_equal 'Sidekiq_critical.RemoteCallWorkerJob', traces.last['TransactionName']
  end

  def test_obey_collect_backtraces_when_true
    # FIXME: This can't be tested with the current Sidekiq minitest integration
    # ____   can't change the config of the already running sidekiq worker
    # ____   possible fix: run another sidekiq instance, but how do I configure them?
    # ____   or, is it possible to restart sidekiq?
    #
    # ____  new insight: it could be done through the args we are sending 05/20
    skip

    SolarWindsAPM::Config[:sidekiqworker][:collect_backtraces] = true

    # Queue up a job to be run
    Sidekiq::Client.push('queue' => 'critical', 'class' => ::RemoteCallWorkerJob, 'args' => [1, 2, 3], 'retry' => false)

    # Allow the job to be run
    sleep 5

    traces = get_all_traces
    assert_equal 17, traces.count, filter_traces(traces).pretty_inspect
    assert valid_edges?(traces), "Invalid edge in traces"
    assert_equal 'sidekiq-worker',   traces[0]['Layer']
    assert_equal true,               traces[0].key?('Backtrace')
  end

  def test_obey_log_args_when_false
    # FIXME: This can't be tested with the current Sidekiq minitest integration,
    # ____   can't change the config of the already running sidekiq worker
    skip

    SolarWindsAPM::Config[:sidekiqworker][:log_args] = false

    # Queue up a job to be run
    Sidekiq::Client.push('queue' => 'critical', 'class' => ::RemoteCallWorkerJob, 'args' => [1, 2, 3], 'retry' => false)

    # Allow the job to be run
    sleep 5

    traces = get_all_traces
    assert_equal 12, traces.count, filter_traces(traces).pretty_inspect
    assert valid_edges?(traces), "Invalid edge in traces"
    assert_equal false, traces[0].key?('Args')
  end

  def test_obey_log_args_when_true
    SolarWindsAPM::Config[:sidekiqworker][:log_args] = true

    # Queue up a job to be run
    Sidekiq::Client.push('queue' => 'critical', 'class' => ::RemoteCallWorkerJob, 'args' => [1, 2, 3], 'retry' => false)

    # Allow the job to be run
    sleep 5

    traces = get_all_traces
    assert_equal 12, traces.count, filter_traces(traces).pretty_inspect
    assert valid_edges?(traces), "Invalid edge in traces"
    assert_equal true,         traces[0].key?('Args')
    assert_equal '[1, 2, 3]',  traces[0]['Args']
  end
end
