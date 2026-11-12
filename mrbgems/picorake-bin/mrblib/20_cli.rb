module Picorake
  class CLI
    def self.run(argv)
      new.run(argv)
    end

    def self.mtime(path)
      return nil unless File.exist?(path)
      File::Stat.new(path).mtime.to_i
    end

    def self.env_name?(name)
      return false if name.empty?
      name.bytes.all? { |b| b == 95 || (48 <= b && b <= 57) || (65 <= b && b <= 90) || (97 <= b && b <= 122) }
    end

    def self.parse_target(arg)
      open = arg.index("[")
      return [arg, []] unless open && arg.end_with?("]")
      [arg[0, open], arg[(open + 1)..-2].split(",")]
    end

    def run(argv)
      file = "Rakefile"
      list = false
      dry = false
      targets = []
      i = 0
      while i < argv.size
        arg = argv[i]
        if arg == "-f"
          i += 1
          return usage_error("-f needs a file") if argv[i].nil?
          file = argv[i]
        elsif arg == "-T"
          list = true
        elsif arg == "-n"
          dry = true
        elsif arg.start_with?("-")
          return usage_error("invalid option: #{arg}")
        elsif (eq = arg.index("=")) && CLI.env_name?(arg[0, eq])
          ENV[arg[0, eq]] = arg[(eq + 1)..-1]
        else
          targets << CLI.parse_target(arg)
        end
        i += 1
      end
      Picorake.file_stamper = CLI.method(:mtime)
      execute(file, list, dry, targets)
    end

    private

    def usage_error(message)
      $stderr.puts "picorake: #{message}"
      $stderr.puts "usage: picorake [-f FILE] [-T] [-n] [NAME=VALUE ...] [TASK[ARG,...] ...]"
      1
    end

    def execute(file, list, dry, targets)
      app = Picorake.application
      unless File.exist?(file)
        $stderr.puts "picorake aborted!"
        $stderr.puts "No Rakefile found: #{file}"
        return 1
      end
      app.load(file.start_with?("/") ? file : "#{Dir.pwd}/#{file}")
      return print_tasks(app) if list
      targets << ["default", []] if targets.empty?
      return print_plan(app, targets) if dry
      app.run do
        targets.each { |name, values| app[name].invoke(*values) }
      end
      0
    rescue StandardError, ScriptError => e
      $stdout.flush
      $stderr.puts "picorake aborted!"
      $stderr.puts e.message
      1
    end

    def print_tasks(app)
      rows = app.tasks.select { |t| t.comment }.map do |t|
        names = t.arg_names
        [names.empty? ? t.name : "#{t.name}[#{names.join(',')}]", t.comment]
      end
      width = rows.map { |r| r[0].size }.max || 0
      rows.each { |label, comment| puts "picorake #{label.ljust(width)}  # #{comment}" }
      0
    end

    def print_plan(app, targets)
      targets.each do |name, values|
        task = app[name]
        hash = {}
        task.arg_names.each_with_index { |n, idx| hash[n] = values[idx] }
        app.plan(name, hash).each { |t, _args| puts "** Execute (dry run) #{t.name}" }
      end
      0
    end
  end
end
