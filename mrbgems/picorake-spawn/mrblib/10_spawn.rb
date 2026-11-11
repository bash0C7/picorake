module Picorake
  module Spawn
    ERR_MODES = { merge: 0, null: 1, inherit: 2 }

    def self._err_mode(err)
      mode = ERR_MODES[err]
      raise ArgumentError, "err must be :merge, :null or :inherit" unless mode
      mode
    end

    def self.run(argv, stdin: nil, err: :merge, out: :capture)
      mode = _err_mode(err)
      case out
      when :capture
        output, statuses = _exec([argv], stdin, mode, 1)
        [output, statuses[0]]
      when :inherit
        _output, statuses = _exec([argv], stdin, mode, 0)
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
