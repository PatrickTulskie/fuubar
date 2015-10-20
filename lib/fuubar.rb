# frozen_string_literal: true

require 'rspec/core'
require 'rspec/core/formatters/base_text_formatter'
require 'ruby-progressbar'
require 'fuubar/output'

RSpec.configuration.add_setting :fuubar_progress_bar_options, default: {}
RSpec.configuration.add_setting :fuubar_slow_threshold, default: 0.0

class Fuubar < RSpec::Core::Formatters::BaseTextFormatter

  # This avoids issues with reporting time caused by examples that
  # change the value/meaning of Time.now without properly restoring
  # it. Borrowed from rspec-core.
  class Time
    class << self
      define_method(:now, &::Time.method(:now))
    end
  end

  DEFAULT_PROGRESS_BAR_OPTIONS = { :format => ' %c/%C |%w>%i| %e ' }.freeze

  RSpec::Core::Formatters.register self,
                                   :close,
                                   :dump_failures,
                                   :example_started,
                                   :example_failed,
                                   :example_passed,
                                   :example_pending,
                                   :message,
                                   :start

  attr_accessor :example_tick_thread,
                :example_tick_lock,
                :progress,
                :passed_count,
                :pending_count,
                :failed_count,
                :start_time

  def initialize(*args)
    super
    self.start_time = Time.now
    self.example_tick_lock = Mutex.new
    self.progress = ProgressBar.create(
                      DEFAULT_PROGRESS_BAR_OPTIONS
                        .merge(:throttle_rate => continuous_integration? ? 1.0 : nil)
                        .merge(:total     => 0,
                               :output    => output,
                               :autostart => false)
    )
  end

  def start(notification)
    progress_bar_options = DEFAULT_PROGRESS_BAR_OPTIONS
                             .merge(:throttle_rate => continuous_integration? ? 1.0 : nil)
                             .merge(configuration.fuubar_progress_bar_options)
                             .merge(:total     => notification.count,
                                    :output    => output,
                                    :autostart => false)

    self.progress            = ProgressBar.create(progress_bar_options)
    self.passed_count        = 0
    self.pending_count       = 0
    self.failed_count        = 0
    self.example_tick_thread = start_tick_thread(notification)

    if Object.const_defined?('Pry')
      Pry
        .config
        .hooks
        .add_hook(:when_started, :fuubar_kill_refresh) do |_target, _opt, _|
          example_tick_thread.kill
        end
    end

    super

    with_current_color { progress.start }
  end

  def close(_notification)
    example_tick_thread.kill
  end

  def example_started(_notification)
    self.start_time = Time.now
  end

  def example_passed(notification)
    self.passed_count += 1

    slow_spec_warning(notification, Time.now - self.start_time)

    increment
  end

  def example_pending(_notification)
    self.pending_count += 1

    increment
  end

  def example_failed(notification)
    self.failed_count += 1

    progress.clear

    output.puts notification.fully_formatted(failed_count)
    output.puts

    increment
  end

  def example_tick(_notification)
    example_tick_lock.synchronize do
      refresh
    end
  end

  def message(notification)
    if progress.respond_to? :log
      progress.log(notification.message)
    else
      super
    end
  end

  def dump_failures(_notification)
    #
    # We output each failure as it happens so we don't need to output them en
    # masse at the end of the run.
    #
  end

  def output
    @fuubar_output ||= Fuubar::Output.new(super, configuration.tty?)
  end

  private

  def slow_spec_warning(notification, time_elapsed)
    if configuration.fuubar_slow_threshold > 0.0 && (time_elapsed > configuration.fuubar_slow_threshold)
      progress.clear

      yellow do
        output.print "SLOW SPEC: #{sprintf("%.4f", time_elapsed)} "
        output.puts notification.example.full_description
        output.puts "=> #{notification.example.location}"
        output.puts
      end
    end
  end

  def yellow
    output.print "\e[#{color_code_for(configuration.pending_color)}m" if color_enabled?
    yield
    output.print "\e[0m" if color_enabled?
  end

  def increment
    with_current_color { progress.increment }
  end

  def refresh
    with_current_color { progress.refresh }
  end

  def with_current_color
    output.print "\e[#{color_code_for(current_color)}m" if color_enabled?
    yield
    output.print "\e[0m"                                if color_enabled?
  end

  def color_enabled?
    configuration.color_enabled? && !continuous_integration?
  end

  def current_color
    if failed_count > 0
      configuration.failure_color
    elsif pending_count > 0
      configuration.pending_color
    else
      configuration.success_color
    end
  end

  def color_code_for(*args)
    RSpec::Core::Formatters::ConsoleCodes.console_code_for(*args)
  end

  def configuration
    RSpec.configuration
  end

  def continuous_integration?
    @continuous_integration ||= \
      ![nil, '', 'false'].include?(ENV['CONTINUOUS_INTEGRATION'])
  end

  def start_tick_thread(notification)
    Thread.new do
      loop do
        sleep(1)

        example_tick(notification)
      end
    end
  end
end
