class TaskTest < Picotest::Test
  def setup
    @app = Picorake::Application.new
    @log = []
  end

  def define(*args, &block)
    @app.define_task(Picorake::Task, *args, &block)
  end

  def test_needed_is_always_true
    assert_equal(true, define(:a).needed?)
  end

  def test_timestamp_is_integer_epoch_seconds
    stamp = define(:a).timestamp
    assert_equal(true, stamp.is_a?(Integer))
    assert_equal(true, stamp > 1_700_000_000)
    assert_equal(true, stamp < Picorake::LATE)
  end

  def test_execute_passes_task_and_args
    seen = nil
    task = define(:a, [:x]) { |t, args| seen = [t.name, args[:x]] }
    task.execute(Picorake::TaskArguments.new([:x], [7]))
    assert_equal(["a", 7], seen)
  end

  def test_execute_runs_every_action_in_order
    define(:a) { @log << 1 }
    define(:a) { @log << 2 }
    @app["a"].execute
    assert_equal([1, 2], @log)
  end

  def test_invoke_runs_prerequisites_depth_first_before_self
    define(:a => [:b, :c]) { @log << "a" }
    define(:b => :d) { @log << "b" }
    define(:c) { @log << "c" }
    define(:d) { @log << "d" }
    @app.invoke("a")
    assert_equal(["d", "b", "c", "a"], @log)
  end

  def test_each_task_runs_once_per_invoke
    define(:a => [:b, :c]) { @log << "a" }
    define(:b => :d) { @log << "b" }
    define(:c => :d) { @log << "c" }
    define(:d) { @log << "d" }
    @app.invoke("a")
    assert_equal(["d", "b", "c", "a"], @log)
  end

  def test_each_invoke_run_starts_fresh
    define(:a) { @log << "a" }
    @app.invoke("a")
    @app.invoke("a")
    assert_equal(["a", "a"], @log)
  end

  def test_invoke_on_task_runs_prerequisites
    task = define(:a => :b) { @log << "a" }
    define(:b) { @log << "b" }
    task.invoke
    assert_equal(["b", "a"], @log)
  end

  def test_invoke_again_after_failure_starts_fresh
    define(:a) { @log << "a"; raise "boom" }
    assert_raise(RuntimeError) { @app.invoke("a") }
    assert_raise(RuntimeError) { @app.invoke("a") }
    assert_equal(["a", "a"], @log)
  end

  def test_args_flow_by_matching_names_only
    seen = {}
    define(:top, [:item_id, :other] => [:mid]) { |t, args| seen["top"] = args.to_h }
    define(:mid, [:item_id] => [:leaf]) { |t, args| seen["mid"] = args.to_h }
    define(:leaf, [:unrelated]) { |t, args| seen["leaf"] = args.to_h }
    @app.invoke("top", item_id: "x1", other: "o", unrelated: "u")
    assert_equal({ item_id: "x1", other: "o" }, seen["top"])
    assert_equal({ item_id: "x1" }, seen["mid"])
    assert_equal({}, seen["leaf"])
  end

  def test_args_flow_through_intermediate_without_declaration
    seen = nil
    define(:top, [:item_id] => :mid)
    define(:mid => :leaf)
    define(:leaf, [:item_id]) { |t, args| seen = args[:item_id] }
    @app.invoke("top", item_id: "x1")
    assert_equal("x1", seen)
  end

  def test_invoke_positional_values
    seen = nil
    task = define(:a, [:x, :y]) { |t, args| seen = args.to_h }
    task.invoke(1, 2)
    assert_equal({ x: 1, y: 2 }, seen)
  end

  def test_invoke_hash_with_string_keys
    seen = nil
    define(:a, [:x]) { |t, args| seen = args[:x] }
    @app.invoke("a", "x" => 5)
    assert_equal(5, seen)
  end

  def test_circular_dependency
    define(:a => :b)
    define(:b => :a)
    assert_raise(Picorake::Error, "Circular dependency detected: a => b => a") { @app.invoke("a") }
  end

  def test_circular_dependency_longer_chain
    define(:a => :b)
    define(:b => :c)
    define(:c => :b)
    assert_raise(Picorake::Error, "Circular dependency detected: a => b => c => b") { @app.invoke("a") }
  end

  def test_self_dependency
    define(:a => :a)
    assert_raise(Picorake::Error, "Circular dependency detected: a => a") { @app.invoke("a") }
  end

  def test_unknown_goal
    assert_raise(Picorake::Error, "Don't know how to build task 'nope'") { @app.invoke("nope") }
  end

  def test_unknown_prerequisite
    define(:a => :nope)
    assert_raise(Picorake::Error, "Don't know how to build task 'nope'") { @app.invoke("a") }
  end

  def test_plain_task_runs_even_when_prerequisite_ran
    define(:a => :b) { @log << "a" }
    define(:b) { @log << "b" }
    @app.invoke("a")
    assert_equal(["b", "a"], @log)
  end
end
