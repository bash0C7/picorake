class ApplicationTest < Picotest::Test
  def setup
    @app = Picorake::Application.new
  end

  def define(*args, &block)
    @app.define_task(Picorake::Task, *args, &block)
  end

  def test_string_name
    task = define("a")
    assert_equal("a", task.name)
    assert_equal([], task.prerequisites)
    assert_equal([], task.arg_names)
  end

  def test_symbol_name
    assert_equal("a", define(:a).name)
  end

  def test_symbol_key_with_array_deps
    task = define(a: [:b, "c"])
    assert_equal("a", task.name)
    assert_equal(["b", "c"], task.prerequisites)
  end

  def test_string_key_with_single_dep
    task = define("a" => "b")
    assert_equal("a", task.name)
    assert_equal(["b"], task.prerequisites)
  end

  def test_symbol_key_with_single_symbol_dep
    assert_equal(["b"], define(a: :b).prerequisites)
  end

  def test_arg_names_as_array
    task = define(:a, [:x, :y])
    assert_equal([:x, :y], task.arg_names)
    assert_equal([], task.prerequisites)
  end

  def test_arg_names_as_list
    assert_equal([:x, :y], define(:a, :x, :y).arg_names)
  end

  def test_arg_names_with_deps
    task = define(:a, [:x] => [:b])
    assert_equal([:x], task.arg_names)
    assert_equal(["b"], task.prerequisites)
  end

  def test_arg_names_with_single_dep
    task = define(:a, [:x] => :b)
    assert_equal([:x], task.arg_names)
    assert_equal(["b"], task.prerequisites)
  end

  def test_block_becomes_action
    task = define(:a) { |t, args| t }
    assert_equal(1, task.actions.size)
  end

  def test_lookup_and_index
    task = define(:a)
    assert(@app.lookup("a").equal?(task))
    assert(@app.lookup(:a).equal?(task))
    assert(@app["a"].equal?(task))
    assert_nil(@app.lookup("zz"))
  end

  def test_unknown_task_raises
    assert_raise(Picorake::Error, "Don't know how to build task 'zz'") { @app["zz"] }
  end

  def test_tasks_sorted_by_name
    define(:c)
    define(:a)
    define(:b)
    assert_equal(["a", "b", "c"], @app.tasks.map { |t| t.name })
  end

  def test_redefinition_merges
    log = []
    first = define(:a => [:b]) { log << 1 }
    second = define(:a => [:c, :b]) { log << 2 }
    assert(first.equal?(second))
    assert_equal(["b", "c"], first.prerequisites)
    assert_equal(2, first.actions.size)
    first.execute
    assert_equal([1, 2], log)
  end

  def test_enhance
    log = []
    task = define(:a) { log << 1 }
    result = task.enhance([:b]) { log << 2 }
    assert(result.equal?(task))
    assert_equal(["b"], task.prerequisites)
    task.execute
    assert_equal([1, 2], log)
  end

  def test_enhance_deps_only
    task = define(:a)
    task.enhance(:b)
    task.enhance(["b", :c])
    assert_equal(["b", "c"], task.prerequisites)
  end

  def test_desc_attaches_to_next_task_only
    @app.desc("first one")
    a = define(:a)
    b = define(:b)
    assert_equal("first one", a.comment)
    assert_nil(b.comment)
  end

  def test_desc_on_redefinition_adds_comment
    @app.desc("one")
    define(:a)
    @app.desc("two")
    task = define(:a)
    assert_equal("one / two", task.comment)
  end

  def test_namespace_prefixes_names
    @app.namespace(:db) do
      define(:migrate)
      @app.namespace("deep") { define(:x) }
    end
    assert_equal(["db:deep:x", "db:migrate"], @app.tasks.map { |t| t.name })
  end

  def test_namespace_restores_scope
    @app.namespace(:db) { define(:a) }
    define(:b)
    assert_equal(["b", "db:a"], @app.tasks.map { |t| t.name })
  end

  def test_namespace_restores_scope_on_error
    assert_raise(RuntimeError) { @app.namespace(:db) { raise "boom" } }
    define(:b)
    assert_equal(["b"], @app.tasks.map { |t| t.name })
  end

  def test_qualified_name_inside_namespace
    @app.namespace(:db) { define("sub:x") }
    assert_equal("db:sub:x", @app.tasks[0].name)
  end

  def test_lookup_walks_outward
    outer = define(:build)
    inner = nil
    @app.namespace(:ns) { inner = define(:build) }
    assert(@app.lookup("build", ["ns"]).equal?(inner))
    assert(@app.lookup("build", ["ns", "deeper"]).equal?(inner))
    assert(@app.lookup("build", []).equal?(outer))
    assert(@app.lookup("ns:build").equal?(inner))
  end

  def test_lookup_outward_to_top_level
    top = define(:common)
    @app.namespace(:ns) { define(:x) }
    assert(@app.lookup("common", ["ns"]).equal?(top))
  end

  def test_caret_and_rake_prefix
    top = define(:build)
    @app.namespace(:ns) { define(:build) }
    assert(@app.lookup("^build", ["ns"]).equal?(top))
    assert(@app.lookup("rake:build", ["ns"]).equal?(top))
  end

  def test_prerequisite_resolved_in_task_scope_first
    log = []
    @app.namespace(:ns) do
      define(:build) { log << "ns:build" }
      define(:all => :build) { log << "ns:all" }
    end
    define(:build) { log << "build" }
    @app.invoke("ns:all")
    assert_equal(["ns:build", "ns:all"], log)
  end

  def test_prerequisite_falls_back_to_top_level
    log = []
    define(:common) { log << "common" }
    @app.namespace(:ns) { define(:all => :common) { log << "ns:all" } }
    @app.invoke("ns:all")
    assert_equal(["common", "ns:all"], log)
  end

  def test_prerequisite_with_same_name_as_self_resolves_to_outer
    log = []
    define(:build) { log << "top" }
    @app.namespace(:ns) { define(:build => :build) { log << "ns" } }
    @app.invoke("ns:build")
    assert_equal(["top", "ns"], log)
  end

  def test_prerequisite_tasks_unknown_raises
    task = define(:a => :missing)
    assert_raise(Picorake::Error, "Don't know how to build task 'missing'") { task.prerequisite_tasks }
  end

  def test_file_task_ignores_namespace
    @app.namespace(:ns) { @app.define_task(Picorake::FileTask, "out/a.txt") }
    assert_equal(["out/a.txt"], @app.tasks.map { |t| t.name })
  end

  def test_singleton_application
    original = Picorake.application
    Picorake.application = @app
    assert(Picorake.application.equal?(@app))
    task = Picorake.define_task(Picorake::Task, :viasingleton)
    assert(@app.lookup("viasingleton").equal?(task))
    Picorake.application = original
  end
end
