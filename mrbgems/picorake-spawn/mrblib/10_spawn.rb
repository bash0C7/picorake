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

    def self._run_exec(argvs, stdin, stdin_from, mode, capture)
      return _exec(argvs, stdin, mode, capture) if stdin_from.nil?
      output, statuses, failure = _exec_feed(argvs, stdin_from, mode, capture)
      raise FeedError.new(failure[0], failure[2], failure[1]) if failure
      [output, statuses]
    end

    def self.run(argv, stdin: nil, stdin_from: nil, err: :merge, out: :capture)
      raise ArgumentError, "stdin and stdin_from are mutually exclusive" if !stdin.nil? && !stdin_from.nil?
      raise ArgumentError, "stdin_from must be an Array of pipelines" unless stdin_from.nil? || stdin_from.is_a?(Array)
      mode = _err_mode(err)
      case out
      when :capture
        output, statuses = _run_exec([argv], stdin, stdin_from, mode, 1)
        [output, statuses[0]]
      when :inherit
        _output, statuses = _run_exec([argv], stdin, stdin_from, mode, 0)
        statuses[0]
      else
        raise ArgumentError, "out must be :capture or :inherit"
      end
    end

    def self.pipeline(argvs, stdin: nil, err: :null)
      raise ArgumentError, "argvs must be a non-empty Array" unless argvs.is_a?(Array) && !argvs.empty?
      output, statuses = _exec(argvs, stdin, _err_mode(err), 1)
      [output, statuses]
    end
  end
end
