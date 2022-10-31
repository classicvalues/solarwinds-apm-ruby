# Copyright (c) 2016 SolarWinds, LLC.
# All rights reserved.

require 'minitest_helper'
require_relative '../jobs/delayed_job/remote_call_worker_job'
require_relative '../jobs/delayed_job/db_worker_job'
require_relative '../jobs/delayed_job/error_worker_job'
require_relative '../models/widget'

class DelayedJobWorkerTest < Minitest::Test
  def setup
    # Delete all pre-existing jobs before we start
    Delayed::Job.delete_all

    clear_all_traces
    @collect_backtraces = SolarWindsAPM::Config[:delayed_jobworker][:collect_backtraces]
    # @log_args = SolarWindsAPM::Config[:delayed_jobworker][:log_args] # there is no code using SolarWindsAPM::Config[:delayed_jobworker][:log_args]
  end

  def teardown
    SolarWindsAPM::Config[:delayed_jobworker][:collect_backtraces] = @collect_backtraces
    # SolarWindsAPM::Config[:delayed_jobworker][:log_args] = @log_args # there is no code using SolarWindsAPM::Config[:delayed_jobworker][:log_args]
  end

  def test_reports_version_init
    init_kvs = ::SolarWindsAPM::Util.build_init_report
    assert init_kvs.key?('Ruby.delayed_job.Version')
    assert_equal Gem.loaded_specs['delayed_job'].version.to_s, init_kvs['Ruby.delayed_job.Version']
  end

  def test_job_run
    w = Widget.new(:name => 'blah', :description => 'This is a wonderful wonderful widget.')
    w.save

    w.delay.do_work(1, 2, 3)

    sleep 60

    traces = get_all_traces
    assert_equal 2, traces.count, "Trace count"
    assert valid_edges?(traces), "Invalid edge in traces"

    assert_equal 'delayed_job-worker',    traces[0]['Layer']
    assert_equal 'entry',                 traces[0]['Label']
    assert_equal 'job',                   traces[0]['Spec']
    assert_equal 'DelayedJob',            traces[0]['Flavor']
    assert_equal 'Widget#do_work',        traces[0]['JobName']
    assert_equal 0,                       traces[0]['priority']
    assert_equal 0,                       traces[0]['attempts']
    assert       traces[0].key?('WorkerName'), "Worker Name"
    assert       traces[0].key?('SampleRate')
    assert       traces[0].key?('SampleSource')
    assert_equal false,                   traces[0].key?('Backtrace')

    assert_equal 'delayed_job-worker',    traces[1]['Layer']
    assert_equal 'exit',                  traces[1]['Label']
  end

  def test_jobs_with_errors
    w = Widget.new(:name => 'blah', :description => 'This is a wonderful wonderful widget.')
    w.save

    w.delay.do_error(1, 2, 3)

    sleep 60

    traces = get_all_traces
    assert_equal 3, traces.count, "Trace count"
    assert valid_edges?(traces), "Invalid edge in traces"

    assert_equal 'delayed_job-worker',          traces[0]['Layer']
    assert_equal 'entry',                       traces[0]['Label']

    assert_equal 'delayed_job-worker',          traces[1]['Layer']
    assert_equal 'error',                       traces[1]['Label']
    assert_equal 'error',                       traces[1]['Spec']
    assert_equal 'FakeTestError',               traces[1]['ErrorMsg']
    assert       traces[1].key?('Backtrace')
    assert       traces[1].key?('ErrorClass')
    assert_equal 1, traces.select { |trace| trace['Label'] == 'error' }.count

    assert_equal 'delayed_job-worker',          traces[2]['Layer']
    assert_equal 'exit',                        traces[2]['Label']

  end

  def test_collect_backtraces_default_value
    assert_equal false, SolarWindsAPM::Config[:delayed_jobworker][:collect_backtraces], "default backtrace collection"
  end

  def test_log_args_default_value
    skip # TODO: there is no code checking SolarWindsAPM::Config[:delayed_jobworker][:log_args]
    assert_equal true, SolarWindsAPM::Config[:delayed_jobworker][:log_args], "test log_args on by default "
  end
end
