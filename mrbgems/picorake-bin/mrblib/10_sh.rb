module Picorake
  module DSL
    private

    def sh(*argv, chdir: nil, timeout_ms: nil)
      Picorake.sh(argv, chdir, timeout_ms)
    end
  end

  def self.sh(argv, chdir, timeout_ms)
    if argv.empty? || !argv.all? { |a| a.is_a?(String) }
      raise ArgumentError, "sh takes the command and each argument as separate Strings"
    end
    if argv.size == 1 && argv[0].bytes.any? { |b| b == 32 || b == 9 || b == 10 }
      raise ArgumentError, "sh does not run shell strings: pass the command and each argument separately"
    end
    $stdout.flush
    $stderr.puts argv.join(" ")
    status = Spawn.run(argv, out: :inherit, err: :inherit, chdir: chdir, timeout_ms: timeout_ms)
    raise Error, "Command failed with status (#{status}): #{argv.join(' ')}" unless status == 0
    true
  end
end
