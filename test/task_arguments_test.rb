class TaskArgumentsTest < Picotest::Test
  def test_index_accepts_symbol_and_string
    args = Picorake::TaskArguments.new([:a, :b], [1, 2])
    assert_equal(1, args[:a])
    assert_equal(1, args["a"])
    assert_equal(2, args[:b])
    assert_nil(args[:c])
  end

  def test_names_may_be_strings
    args = Picorake::TaskArguments.new(["a"], [1])
    assert_equal(1, args[:a])
  end

  def test_nil_and_empty_values_are_absent
    args = Picorake::TaskArguments.new([:a, :b, :c], [nil, "", 3])
    assert_equal({ c: 3 }, args.to_h)
  end

  def test_to_h
    args = Picorake::TaskArguments.new([:a, :b], [1, 2])
    assert_equal({ a: 1, b: 2 }, args.to_h)
  end

  def test_new_scope_limits_to_names
    args = Picorake::TaskArguments.new([:a, :b], [1, 2])
    scoped = args.new_scope([:b])
    assert_equal({ b: 2 }, scoped.to_h)
    assert_equal(2, scoped[:b])
  end

  def test_new_scope_falls_back_to_parent
    args = Picorake::TaskArguments.new([:a], [1])
    scoped = args.new_scope([:a, :z])
    assert_equal(1, scoped[:a])
    assert_nil(scoped[:z])
    assert_equal({ a: 1 }, scoped.to_h)
  end

  def test_method_access
    args = Picorake::TaskArguments.new([:item_id], ["x1"])
    assert_equal("x1", args.item_id)
  end

  def test_extras
    args = Picorake::TaskArguments.new([:a], [1, 2, 3])
    assert_equal([2, 3], args.extras)
    assert_equal([1, 2, 3], args.to_a)
  end
end
