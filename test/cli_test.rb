class CliTest < Picotest::Test
  def setup
    @picorake = ENV["PICORAKE"]
    @dir = "/tmp/picorake_cli_test_#{Time.now.to_i}_#{rand(1_000_000)}"
    Picorake::Spawn.run(["/bin/mkdir", "-p", @dir])
  end

  def teardown
    Picorake::Spawn.run(["/bin/rm", "-rf", @dir])
  end

  def write(name, text)
    File.open("#{@dir}/#{name}", "w") { |f| f.puts text }
  end

  def run_cli(*args)
    Picorake::Spawn.run([@picorake, *args], chdir: @dir)
  end

  def touch(name, stamp)
    Picorake::Spawn.run(["/usr/bin/touch", "-t", stamp, "#{@dir}/#{name}"])
  end

  def test_runs_default_task_from_rakefile_in_cwd
    write("Rakefile", <<'RAKEFILE')
task :default do
  puts "default ran"
end
RAKEFILE
    output, status = run_cli
    assert_equal(0, status)
    assert_equal("default ran\n", output)
  end

  def test_file_option_selects_the_rakefile
    write("Other.rb", <<'RAKEFILE')
task :hello do
  puts "from other"
end
RAKEFILE
    output, status = run_cli("-f", "Other.rb", "hello")
    assert_equal(0, status)
    assert_equal("from other\n", output)
  end

  def test_missing_rakefile_fails
    output, status = run_cli
    assert_equal(1, status)
    assert_true(output.include?("picorake aborted!"))
  end

  def test_task_arguments_are_mapped_in_order
    write("Rakefile", <<'RAKEFILE')
task :greet, [:first, :second] do |t, args|
  puts "#{args[:first]}-#{args[:second]}"
end
RAKEFILE
    output, status = run_cli("greet[a,b]")
    assert_equal(0, status)
    assert_equal("a-b\n", output)
  end

  def test_several_tasks_run_in_order_and_share_prerequisites
    write("Rakefile", <<'RAKEFILE')
task :base do
  puts "base"
end
task one: :base do
  puts "one"
end
task two: :base do
  puts "two"
end
RAKEFILE
    output, status = run_cli("one", "two")
    assert_equal(0, status)
    assert_equal("base\none\ntwo\n", output)
  end

  def test_list_prints_described_tasks_only
    write("Rakefile", <<'RAKEFILE')
desc "Build it"
task :build, [:item] do
end

desc "Run tests"
task :test do
end

task :hidden do
end
RAKEFILE
    output, status = run_cli("-T")
    assert_equal(0, status)
    assert_equal("picorake build[item]  # Build it\npicorake test         # Run tests\n", output)
  end

  def test_dry_run_prints_the_plan_without_running
    write("Rakefile", <<'RAKEFILE')
task :a do
  puts "ran a"
end
task b: :a do
  puts "ran b"
end
RAKEFILE
    output, status = run_cli("-n", "b")
    assert_equal(0, status)
    assert_equal("** Execute (dry run) a\n** Execute (dry run) b\n", output)
  end

  def test_name_value_sets_env
    write("Rakefile", <<'RAKEFILE')
task :show do
  puts "value=#{ENV['PICORAKE_CLI_TEST']}"
end
RAKEFILE
    output, status = run_cli("PICORAKE_CLI_TEST=x=y", "show")
    assert_equal(0, status)
    assert_equal("value=x=y\n", output)
  end

  def test_failing_task_aborts_with_status_1
    write("Rakefile", <<'RAKEFILE')
task :boom do
  raise "exploded"
end
RAKEFILE
    output, status = run_cli("boom")
    assert_equal(1, status)
    assert_equal("picorake aborted!\nexploded\n", output)
  end

  def test_unknown_task_fails
    write("Rakefile", "task :real do\nend")
    output, status = run_cli("nope")
    assert_equal(1, status)
    assert_true(output.include?("picorake aborted!"))
    assert_true(output.include?("nope"))
  end

  def test_sh_runs_argv_and_streams_output
    write("Rakefile", <<'RAKEFILE')
task :go do
  puts "before"
  sh "/bin/echo", "hello", "a b"
  puts "after"
end
RAKEFILE
    output, status = run_cli("go")
    assert_equal(0, status)
    assert_equal("before\n/bin/echo hello a b\nhello a b\nafter\n", output)
  end

  def test_sh_passes_special_characters_verbatim
    write("Rakefile", <<'RAKEFILE')
task :go do
  sh "/bin/echo", "$HOME", "a;b", "*"
end
RAKEFILE
    output, status = run_cli("go")
    assert_equal(0, status)
    assert_true(output.include?("\n$HOME a;b *\n"))
  end

  def test_sh_failure_raises_with_status
    write("Rakefile", <<'RAKEFILE')
task :go do
  sh "/bin/sh", "-c", "exit 3"
  puts "not reached"
end
RAKEFILE
    output, status = run_cli("go")
    assert_equal(1, status)
    assert_true(output.include?("Command failed with status (3): /bin/sh -c exit 3"))
    assert_false(output.include?("not reached"))
  end

  def test_sh_refuses_shell_strings
    write("Rakefile", <<'RAKEFILE')
task :go do
  sh "echo hi"
end
RAKEFILE
    output, status = run_cli("go")
    assert_equal(1, status)
    assert_true(output.include?("sh does not run shell strings"))
    assert_false(output.include?("hi\n"))
  end

  def test_sh_chdir
    write("Rakefile", <<'RAKEFILE')
task :go do
  sh "/bin/pwd", chdir: "/"
end
RAKEFILE
    output, status = run_cli("go")
    assert_equal(0, status)
    assert_true(output.end_with?("\n/\n"))
  end

  FILE_RAKEFILE = <<'RAKEFILE'
file "src.txt"

file "out.txt" => "src.txt" do |t|
  puts "building #{t.name}"
end
RAKEFILE

  def test_file_task_is_built_when_target_is_missing
    write("Rakefile", FILE_RAKEFILE)
    write("src.txt", "s")
    output, status = run_cli("out.txt")
    assert_equal(0, status)
    assert_equal("building out.txt\n", output)
  end

  def test_file_task_is_skipped_when_target_is_newer
    write("Rakefile", FILE_RAKEFILE)
    write("src.txt", "s")
    write("out.txt", "o")
    touch("src.txt", "202001010000")
    touch("out.txt", "202001020000")
    output, status = run_cli("out.txt")
    assert_equal(0, status)
    assert_equal("", output)
  end

  def test_file_task_is_rebuilt_when_source_is_newer
    write("Rakefile", FILE_RAKEFILE)
    write("src.txt", "s")
    write("out.txt", "o")
    touch("out.txt", "202001010000")
    touch("src.txt", "202001020000")
    output, status = run_cli("out.txt")
    assert_equal(0, status)
    assert_equal("building out.txt\n", output)
  end
end
