require "picotest"

class Integer
  def exitstatus
    self
  end
end

root = ARGV[0]
dir = ARGV[1]
unless root && dir
  $stderr.puts "usage: runner.rb <root> <dir> [load_file...]"
  exit 2
end

vm = ENV["PICORUBY"]
if vm.to_s.empty?
  $stderr.puts "PICORUBY is not set"
  exit 2
end

load_files = ARGV[2..-1].to_a.map { |file| File.join(root, file) }
ENV["RUBY"] = vm
filter = ENV["PICOTEST_FILTER"]
filter = nil if filter.to_s.empty?
tmpdir = IO.popen("mktemp -d", "r") { |io| io.read }.to_s.split("\n").first
status = Picotest::Runner.new(File.join(root, dir), filter: filter, load_files: load_files, tmpdir: tmpdir).run
IO.popen("rm -rf '#{tmpdir}'", "r") { |io| io.read }
exit status
