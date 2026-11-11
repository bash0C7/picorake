class LoadTest < Picotest::Test
  def setup
    @original = Picorake.application
    Picorake.application = Picorake::Application.new
    @path = "/tmp/picorake_load_test_#{Time.now.to_i}.rb"
    $picorake_log = []
  end

  def teardown
    File.delete(@path) if File.exist?(@path)
    Picorake.application = @original
  end

  def write_rakefile(text)
    File.open(@path, "w") { |f| f.puts text }
  end

  def test_loads_rakefile_format
    write_rakefile(<<'RAKEFILE')
desc "Build everything"
task default: [:build]

desc "Compile"
task :build, [:item_id] => "prep:fetch" do |t, args|
  $picorake_log << "build #{args[:item_id]}"
end

namespace :prep do
  task :clean do
    $picorake_log << "prep:clean"
  end

  task fetch: :clean do
    $picorake_log << "prep:fetch"
  end
end

file "out/result.txt" => "build" do
  $picorake_log << "file"
end
RAKEFILE
    app = Picorake.application
    app.load(@path)
    assert_equal(["build", "default", "out/result.txt", "prep:clean", "prep:fetch"], app.tasks.map { |t| t.name })
    assert_equal("Build everything", app["default"].comment)
    assert_equal("Compile", app["build"].comment)
    assert_equal(true, app["out/result.txt"].is_a?(Picorake::FileTask))
    assert_equal(false, app["build"].is_a?(Picorake::FileTask))
    app.invoke("build", item_id: "x1")
    assert_equal(["prep:clean", "prep:fetch", "build x1"], $picorake_log)
  end

  def test_loaded_file_uses_picorake_application
    write_rakefile("task :solo do\n  $picorake_log << 'solo'\nend")
    Picorake.application.load(@path)
    assert_equal("solo", Picorake.application["solo"].name)
  end

  def test_dsl_is_private_on_object
    write_rakefile("task :x")
    Picorake.application.load(@path)
    assert_raise(NoMethodError) { Object.new.task(:y) }
  end

  def test_load_includes_dsl_once
    write_rakefile("task :x")
    Picorake.application.load(@path)
    Picorake.application.load(@path)
    assert_equal(true, Object.include?(Picorake::DSL))
    assert_equal(1, Picorake.application.tasks.size)
  end
end
