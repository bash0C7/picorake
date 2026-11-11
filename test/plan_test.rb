if defined?(Picorake::FileTask)
  class PlanStampedTask < Picorake::FileTask
    def self.stamps
      @stamps ||= {}
    end

    def stamp(args = nil)
      self.class.stamps[name]
    end
  end
end

class PlanTest < Picotest::Test
  def setup
    @app = Picorake::Application.new
    @log = []
    PlanStampedTask.stamps.clear
  end

  def task(*args, &block)
    @app.define_task(Picorake::Task, *args, &block)
  end

  def file(*args, &block)
    @app.define_task(PlanStampedTask, *args, &block)
  end

  def names(plan)
    plan.map { |entry| entry[0].name }
  end

  def test_plan_lists_in_invoke_order
    task(:a => [:b, :c])
    task(:b => :d)
    task(:c)
    task(:d)
    assert_equal(["d", "b", "c", "a"], names(@app.plan("a")))
  end

  def test_plan_lists_each_task_once
    task(:a => [:b, :c])
    task(:b => :d)
    task(:c => :d)
    task(:d)
    assert_equal(["d", "b", "c", "a"], names(@app.plan("a")))
  end

  def test_plan_executes_nothing
    task(:a => :b) { @log << "a" }
    task(:b) { @log << "b" }
    @app.plan("a")
    assert_equal([], @log)
  end

  def test_plan_first_is_what_invoke_runs_first
    task(:a => [:b, :c]) { @log << "a" }
    task(:b) { @log << "b" }
    task(:c) { @log << "c" }
    first = @app.plan("a")[0][0]
    @app.invoke("a")
    assert_equal(first.name, @log[0])
  end

  def test_plan_skips_up_to_date_file_tasks
    PlanStampedTask.stamps["out"] = 200
    PlanStampedTask.stamps["src"] = 100
    file("src")
    file("out" => "src")
    assert_equal([], @app.plan("out"))
  end

  def test_plan_first_is_the_missing_file
    PlanStampedTask.stamps["src"] = 100
    file("src")
    file("mid" => "src")
    file("out" => "mid")
    plan = @app.plan("out")
    assert_equal(["mid", "out"], names(plan))
  end

  def test_plan_propagates_to_dependents_of_needed_task
    PlanStampedTask.stamps["src"] = 100
    PlanStampedTask.stamps["mid"] = 200
    PlanStampedTask.stamps["out"] = 300
    file("src")
    file("mid" => "src")
    file("out" => "mid")
    assert_equal([], @app.plan("out"))
    PlanStampedTask.stamps.delete("mid")
    assert_equal(["mid", "out"], names(@app.plan("out")))
  end

  def test_plan_includes_dependents_of_a_missing_file
    PlanStampedTask.stamps["a"] = 10
    PlanStampedTask.stamps["top"] = 1_000_000
    file("a")
    file("top" => [:a])
    @app.define_task(Picorake::Task, "top2" => [:top])
    assert_equal(["top2"], names(@app.plan("top2")))
    PlanStampedTask.stamps.delete("a")
    assert_equal(["a", "top", "top2"], names(@app.plan("top2")))
  end

  def test_plan_plain_task_is_always_planned
    task(:a => :b)
    task(:b)
    assert_equal(["b", "a"], names(@app.plan("a")))
  end

  def test_plan_args_flow_by_name
    task(:top, [:item_id] => :leaf)
    task(:leaf, [:item_id])
    plan = @app.plan("top", item_id: "x1")
    assert_equal({ item_id: "x1" }, plan[0][1].to_h)
    assert_equal({ item_id: "x1" }, plan[1][1].to_h)
  end

  def test_plan_args_do_not_flow_without_matching_name
    task(:top, [:item_id] => :leaf)
    task(:leaf)
    plan = @app.plan("top", item_id: "x1")
    assert_equal({}, plan[0][1].to_h)
  end

  def test_plan_detects_cycle
    task(:a => :b)
    task(:b => :a)
    assert_raise(Picorake::Error, "Circular dependency detected: a => b => a") { @app.plan("a") }
  end

  def test_plan_unknown_goal
    assert_raise(Picorake::Error, "Don't know how to build task 'nope'") { @app.plan("nope") }
  end
end
