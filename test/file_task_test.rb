if defined?(Picorake::FileTask)
  class StampedFileTask < Picorake::FileTask
    def self.stamps
      @stamps ||= {}
    end

    def stamp(args = nil)
      key = args && args[:item_id] ? "#{name}@#{args[:item_id]}" : name
      self.class.stamps[key]
    end
  end
end

class FileTaskTest < Picotest::Test
  def setup
    @app = Picorake::Application.new
    @log = []
    StampedFileTask.stamps.clear
  end

  def file(*args, &block)
    @app.define_task(StampedFileTask, *args, &block)
  end

  def stamps
    StampedFileTask.stamps
  end

  def test_core_stamp_is_nil
    task = @app.define_task(Picorake::FileTask, "x")
    assert_nil(task.stamp)
    assert_equal(true, task.needed?)
    assert_equal(Picorake::LATE, task.timestamp)
  end

  def test_late_is_larger_than_any_epoch
    assert_equal(true, Picorake::LATE > 4_102_444_800_000)
  end

  def test_missing_is_needed
    task = file("out")
    assert_equal(true, task.needed?)
    assert_equal(Picorake::LATE, task.timestamp)
  end

  def test_existing_without_prerequisites_is_not_needed
    stamps["out"] = 100
    task = file("out")
    assert_equal(false, task.needed?)
    assert_equal(100, task.timestamp)
  end

  def test_older_prerequisite_is_not_needed
    stamps["out"] = 200
    stamps["src"] = 100
    file("src")
    task = file("out" => "src")
    assert_equal(false, task.needed?)
  end

  def test_newer_prerequisite_is_needed
    stamps["out"] = 100
    stamps["src"] = 200
    file("src")
    task = file("out" => "src")
    assert_equal(true, task.needed?)
  end

  def test_missing_prerequisite_is_needed
    stamps["out"] = 100
    file("src")
    task = file("out" => "src")
    assert_equal(true, task.needed?)
  end

  def test_plain_task_prerequisite_is_needed
    stamps["out"] = 100
    @app.define_task(Picorake::Task, "gen")
    task = file("out" => "gen")
    assert_equal(true, task.needed?)
  end

  def test_out_of_date_predicate
    stamps["src"] = 200
    file("src")
    task = file("out" => "src")
    assert_equal(true, task.out_of_date?(100))
    assert_equal(false, task.out_of_date?(200))
    assert_equal(false, task.out_of_date?(300))
  end

  def test_invoke_skips_up_to_date_file
    stamps["out"] = 200
    stamps["src"] = 100
    file("src") { @log << "src" }
    file("out" => "src") { @log << "out" }
    @app.invoke("out")
    assert_equal([], @log)
  end

  def test_invoke_builds_stale_file
    stamps["out"] = 100
    stamps["src"] = 200
    file("src") { @log << "src" }
    file("out" => "src") { @log << "out" }
    @app.invoke("out")
    assert_equal(["out"], @log)
  end

  def test_invoke_builds_missing_chain
    file("src") { @log << "src" }
    file("out" => "src") { @log << "out" }
    @app.invoke("out")
    assert_equal(["src", "out"], @log)
  end

  def test_stamps_follow_the_arguments
    stamps["src@a"] = 100
    stamps["out@a"] = 200
    stamps["src@b"] = 300
    stamps["out@b"] = 200
    file("src", [:item_id]) { |t, args| @log << "src #{args[:item_id]}" }
    file("out", [:item_id] => "src") { |t, args| @log << "out #{args[:item_id]}" }
    assert_equal(false, @app.lookup("out").needed?(Picorake::TaskArguments.new([:item_id], ["a"])))
    assert_equal(true, @app.lookup("out").needed?(Picorake::TaskArguments.new([:item_id], ["b"])))
    @app.invoke("out", item_id: "b")
    assert_equal(["out b"], @log)
  end

  def test_an_existing_file_without_a_task_becomes_a_file_task_like_rake
    Picorake.file_stamper = lambda { |name| name == "src.txt" ? 200 : nil }
    stamps["out"] = 100
    task = file("out" => "src.txt") { @log << "out" }
    assert_equal(true, task.needed?)
    @app.invoke("out")
    assert_equal(["out"], @log)
    assert_equal(true, @app.lookup("src.txt").is_a?(Picorake::FileTask))
    error = nil
    begin
      file("other" => "missing.txt")
      @app.invoke("other")
    rescue Picorake::Error => e
      error = e
    end
    assert_equal("Don't know how to build task 'missing.txt'", error.message)
  ensure
    Picorake.file_stamper = nil
  end

  def test_transitive_prerequisite_is_considered
    stamps["out"] = 100
    stamps["mid"] = 50
    stamps["src"] = 200
    file("src")
    file("mid" => "src")
    task = file("out" => "mid")
    assert_equal(true, task.needed?)
  end
end
