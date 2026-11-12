module Picorake
  module Spawn
    ERR_MODES = { merge: 0, null: 1, inherit: 2 }

    class FeedError < Error
      def initialize(index, stage, status)
        @index = index
        @stage = stage
        @status = status
        super("feeder #{index} stage #{stage} exited #{status}")
      end

      def index
        @index
      end

      def stage
        @stage
      end

      def status
        @status
      end
    end

    def self._err_mode(err)
      mode = ERR_MODES[err]
      raise ArgumentError, "err must be :merge, :null or :inherit" unless mode
      mode
    end

    def self._check_options(chdir, timeout_ms)
      unless chdir.nil?
        raise ArgumentError, "chdir must be a String" unless chdir.is_a?(String)
        raise ArgumentError, "chdir must not contain NUL" if chdir.include?("\0")
      end
      unless timeout_ms.nil?
        raise ArgumentError, "timeout_ms must be a positive Integer" unless timeout_ms.is_a?(Integer) && timeout_ms > 0
      end
    end

    def self._run_exec(argvs, stdin, stdin_from, mode, capture, chdir, timeout_ms)
      ms = timeout_ms || 0
      return _exec(argvs, stdin, mode, capture, chdir, ms) if stdin_from.nil?
      output, statuses, failure = _exec_feed(argvs, stdin_from, mode, capture, chdir, ms)
      raise FeedError.new(failure[0], failure[2], failure[1]) if failure
      [output, statuses]
    end

    def self.run(argv, stdin: nil, stdin_from: nil, err: :merge, out: :capture, chdir: nil, timeout_ms: nil)
      raise ArgumentError, "stdin and stdin_from are mutually exclusive" if !stdin.nil? && !stdin_from.nil?
      raise ArgumentError, "stdin_from must be an Array of pipelines" unless stdin_from.nil? || stdin_from.is_a?(Array)
      _check_options(chdir, timeout_ms)
      mode = _err_mode(err)
      case out
      when :capture
        output, statuses = _run_exec([argv], stdin, stdin_from, mode, 1, chdir, timeout_ms)
        [output, statuses[0]]
      when :inherit
        _output, statuses = _run_exec([argv], stdin, stdin_from, mode, 0, chdir, timeout_ms)
        statuses[0]
      else
        raise ArgumentError, "out must be :capture or :inherit"
      end
    end

    def self.pipeline(argvs, stdin: nil, err: :null, chdir: nil, timeout_ms: nil)
      raise ArgumentError, "argvs must be a non-empty Array" unless argvs.is_a?(Array) && !argvs.empty?
      _check_options(chdir, timeout_ms)
      output, statuses = _exec(argvs, stdin, _err_mode(err), 1, chdir, timeout_ms || 0)
      [output, statuses]
    end
  end
end
