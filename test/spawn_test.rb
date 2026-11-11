class SpawnTest < Picotest::Test
  PRINTF = "/usr/bin/printf"

  def echo_arg(arg)
    Picorake::Spawn.run([PRINTF, "%s\n", arg])
  end

  def test_special_characters_reach_the_child_verbatim
    args = [
      "it's",
      "say \"hi\"",
      "two  spaces and\ttab",
      "line1\nline2",
      "$HOME",
      "${HOME}",
      "$(echo expanded)",
      "`echo expanded`",
      "a;b",
      "a|b",
      "a&&b",
      "a||b",
      "*",
      "~",
      "a > b < c",
      "back\\slash",
      "'; rm -rf / #",
      ""
    ]
    args.each do |arg|
      output, status = echo_arg(arg)
      assert_equal(0, status)
      assert_equal(arg + "\n", output)
    end
  end

  def test_each_argv_element_stays_one_argument
    output, status = Picorake::Spawn.run([PRINTF, "[%s]", "a b", "c;d", "$HOME"])
    assert_equal(0, status)
    assert_equal("[a b][c;d][$HOME]", output)
  end

  def test_argv0_is_resolved_through_path
    output, status = Picorake::Spawn.run(["printf", "%s", "via path"])
    assert_equal(0, status)
    assert_equal("via path", output)
  end

  def test_stdin_round_trip_through_cat
    output, status = Picorake::Spawn.run(["/bin/cat"], stdin: "hello\nworld\n")
    assert_equal(0, status)
    assert_equal("hello\nworld\n", output)
  end

  def test_stdin_with_nul_bytes_round_trips
    data = "a\0b\0c"
    output, status = Picorake::Spawn.run(["/bin/cat"], stdin: data)
    assert_equal(0, status)
    assert_equal(5, output.bytesize)
    assert_equal(true, output == data)
  end

  def test_large_stdin_round_trips_without_deadlock
    data = "0123456789abcdef" * 80_000
    assert_equal(true, data.bytesize > 1_048_576)
    output, status = Picorake::Spawn.run(["/bin/cat"], stdin: data)
    assert_equal(0, status)
    assert_equal(data.bytesize, output.bytesize)
    assert_equal(true, output == data)
  end

  def test_empty_stdin_gives_eof
    output, status = Picorake::Spawn.run(["/bin/cat"], stdin: "")
    assert_equal(0, status)
    assert_equal("", output)
  end

  def test_nil_stdin_is_dev_null
    output, status = Picorake::Spawn.run(["/bin/cat"])
    assert_equal(0, status)
    assert_equal("", output)
  end

  def test_stdin_not_read_by_child_does_not_hang
    data = "x" * 2_000_000
    output, status = Picorake::Spawn.run(["/usr/bin/true"], stdin: data)
    assert_equal(0, status)
    assert_equal("", output)
  end

  def test_err_merge_captures_stderr
    output, status = Picorake::Spawn.run(["/bin/ls", "/picorake/no/such/path"], err: :merge)
    assert_equal(true, status != 0)
    assert_equal(true, output.include?("/picorake/no/such/path"))
    assert_equal(true, output.include?("No such file"))
  end

  def test_err_defaults_to_merge
    output, status = Picorake::Spawn.run(["/bin/ls", "/picorake/no/such/path"])
    assert_equal(true, status != 0)
    assert_equal(true, output.include?("No such file"))
  end

  def test_err_null_discards_stderr
    output, status = Picorake::Spawn.run(["/bin/ls", "/picorake/no/such/path"], err: :null)
    assert_equal(true, status != 0)
    assert_equal("", output)
  end

  def test_err_inherit_keeps_stderr_out_of_output
    output, status = Picorake::Spawn.run(["/bin/ls", "/picorake/no/such/path"], err: :inherit)
    assert_equal(true, status != 0)
    assert_equal("", output)
  end

  def test_exit_status
    _output, status = Picorake::Spawn.run(["/usr/bin/false"])
    assert_equal(1, status)
    _output, status = Picorake::Spawn.run(["/usr/bin/true"])
    assert_equal(0, status)
  end

  def test_signal_death_is_128_plus_signal
    _output, status = Picorake::Spawn.run(["/usr/bin/perl", "-e", "kill 9, $$"])
    assert_equal(137, status)
    _output, status = Picorake::Spawn.run(["/usr/bin/perl", "-e", "exit 3"])
    assert_equal(3, status)
  end

  def test_command_not_found_raises
    error = nil
    begin
      Picorake::Spawn.run(["/picorake/no/such/command"])
    rescue Picorake::Spawn::Error => e
      error = e
    end
    assert_equal(true, !error.nil?)
    assert_equal(true, error.message.include?("/picorake/no/such/command"))
    assert_equal(true, error.message.include?("No such file"))
  end

  def test_command_not_found_in_path_raises
    assert_raise(Picorake::Spawn::Error) { Picorake::Spawn.run(["picorake-no-such-command"]) }
  end

  def test_error_is_a_standard_error
    assert_equal(true, Picorake::Spawn::Error.ancestors.include?(StandardError))
  end

  def test_out_inherit_returns_only_the_status
    assert_equal(0, Picorake::Spawn.run(["/usr/bin/true"], out: :inherit))
    assert_equal(1, Picorake::Spawn.run(["/usr/bin/false"], out: :inherit))
  end

  def test_out_inherit_feeds_stdin
    assert_equal(0, Picorake::Spawn.run(["/bin/cat"], stdin: "", out: :inherit))
  end

  def test_pipeline_connects_stdout_to_stdin
    output, statuses = Picorake::Spawn.pipeline([[PRINTF, "%s", "secret"], ["/usr/bin/tr", "a-z", "A-Z"]])
    assert_equal("SECRET", output)
    assert_equal([0, 0], statuses)
  end

  def test_pipeline_feeds_stdin_to_the_first_command
    output, statuses = Picorake::Spawn.pipeline([["/bin/cat"], ["/usr/bin/tr", "a-z", "A-Z"], ["/bin/cat"]], stdin: "abc def\n")
    assert_equal("ABC DEF\n", output)
    assert_equal([0, 0, 0], statuses)
  end

  def test_pipeline_large_stdin
    data = "0123456789abcdef" * 80_000
    output, statuses = Picorake::Spawn.pipeline([["/bin/cat"], ["/bin/cat"]], stdin: data)
    assert_equal([0, 0], statuses)
    assert_equal(data.bytesize, output.bytesize)
    assert_equal(true, output == data)
  end

  def test_pipeline_reports_each_status
    output, statuses = Picorake::Spawn.pipeline([["/usr/bin/false"], ["/bin/cat"]])
    assert_equal("", output)
    assert_equal([1, 0], statuses)
  end

  def test_pipeline_single_command
    output, statuses = Picorake::Spawn.pipeline([[PRINTF, "%s", "solo"]])
    assert_equal("solo", output)
    assert_equal([0], statuses)
  end

  def test_pipeline_err_null_hides_stderr_of_every_command
    output, statuses = Picorake::Spawn.pipeline([["/bin/ls", "/picorake/no/such/path"], ["/bin/cat"]])
    assert_equal("", output)
    assert_equal(true, statuses[0] != 0)
  end

  def test_pipeline_err_merge_captures_stderr_of_every_command
    output, _statuses = Picorake::Spawn.pipeline([["/bin/ls", "/picorake/no/such/path"], ["/bin/cat"]], err: :merge)
    assert_equal(true, output.include?("No such file"))
  end

  def test_pipeline_failure_to_start_raises
    assert_raise(Picorake::Spawn::Error) do
      Picorake::Spawn.pipeline([["/bin/cat"], ["/picorake/no/such/command"]], stdin: "x")
    end
  end

  def test_pipeline_passes_special_characters_verbatim
    output, _statuses = Picorake::Spawn.pipeline([[PRINTF, "%s", "$(echo x); `y` 'z' *"], ["/bin/cat"]])
    assert_equal("$(echo x); `y` 'z' *", output)
  end

  def test_nul_in_argv_raises_argument_error
    assert_raise(ArgumentError) { Picorake::Spawn.run(["/bin/echo", "a\0b"]) }
    assert_raise(ArgumentError) { Picorake::Spawn.run(["/bin/ec\0ho"]) }
    assert_raise(ArgumentError) { Picorake::Spawn.pipeline([["/bin/cat"], ["/bin/echo", "a\0b"]]) }
  end

  def test_invalid_argv_raises_argument_error
    assert_raise(ArgumentError) { Picorake::Spawn.run([]) }
    assert_raise(ArgumentError) { Picorake::Spawn.run("/bin/echo hi") }
    assert_raise(ArgumentError) { Picorake::Spawn.run(["/bin/echo", 1]) }
    assert_raise(ArgumentError) { Picorake::Spawn.run(["/bin/echo", nil]) }
    assert_raise(ArgumentError) { Picorake::Spawn.run([["/bin/echo"]]) }
    assert_raise(ArgumentError) { Picorake::Spawn.pipeline([]) }
    assert_raise(ArgumentError) { Picorake::Spawn.pipeline(["/bin/cat"]) }
    assert_raise(ArgumentError) { Picorake::Spawn.pipeline([["/bin/cat"], []]) }
  end

  def test_invalid_options_raise_argument_error
    assert_raise(ArgumentError) { Picorake::Spawn.run(["/bin/cat"], stdin: 1) }
    assert_raise(ArgumentError) { Picorake::Spawn.run(["/bin/cat"], err: :bogus) }
    assert_raise(ArgumentError) { Picorake::Spawn.run(["/bin/cat"], out: :bogus) }
    assert_raise(ArgumentError) { Picorake::Spawn.pipeline([["/bin/cat"]], err: :bogus) }
  end

  def test_stdin_from_concatenates_feeder_outputs_in_order
    feeders = [[[PRINTF, "%s\n", "a"]], [[PRINTF, "%s", "b c"], ["/usr/bin/tr", "a-z", "A-Z"]]]
    output, status = Picorake::Spawn.run(["/bin/cat"], stdin_from: feeders)
    assert_equal(0, status)
    assert_equal("a\nB C", output)
  end

  def test_stdin_from_failing_feeder_raises_feed_error_and_skips_the_consumer
    dir, dir_status = Picorake::Spawn.run(["/usr/bin/mktemp", "-d"])
    assert_equal(0, dir_status)
    dir = dir.strip
    trace = dir + "/trace"
    error = nil
    begin
      Picorake::Spawn.run(["/usr/bin/touch", trace], stdin_from: [[[PRINTF, "%s", "x"]], [["/usr/bin/false"]]])
    rescue Picorake::Spawn::FeedError => e
      error = e
    end
    _out, exists = Picorake::Spawn.run(["/bin/test", "-e", trace])
    Picorake::Spawn.run(["/bin/rm", "-rf", dir])
    assert_equal(true, !error.nil?)
    assert_equal(1, error.index)
    assert_equal(0, error.stage)
    assert_equal(1, error.status)
    assert_equal("feeder 1 stage 0 exited 1", error.message)
    assert_equal(1, exists)
  end

  def test_feed_error_is_a_spawn_error
    assert_equal(true, Picorake::Spawn::FeedError.ancestors.include?(Picorake::Spawn::Error))
  end

  def test_stdin_from_and_stdin_are_mutually_exclusive
    assert_raise(ArgumentError) do
      Picorake::Spawn.run(["/bin/cat"], stdin: "x", stdin_from: [[[PRINTF, "%s", "y"]]])
    end
  end

  def test_stdin_from_invalid_values_raise_argument_error
    assert_raise(ArgumentError) { Picorake::Spawn.run(["/bin/cat"], stdin_from: "x") }
    assert_raise(ArgumentError) { Picorake::Spawn.run(["/bin/cat"], stdin_from: [[]]) }
    assert_raise(ArgumentError) { Picorake::Spawn.run(["/bin/cat"], stdin_from: [["/bin/cat"]]) }
    assert_raise(ArgumentError) { Picorake::Spawn.run(["/bin/cat"], stdin_from: [[["/bin/echo", 1]]]) }
  end

  def test_stdin_from_feeder_start_failure_raises_error
    assert_raise(Picorake::Spawn::Error) do
      Picorake::Spawn.run(["/bin/cat"], stdin_from: [[[PRINTF, "%s", "x"]], [["/picorake/no/such/command"]]])
    end
  end

  def test_stdin_from_large_feeder_output_round_trips_without_deadlock
    feeders = [[["/usr/bin/perl", "-e", 'print "0123456789abcdef" x 80000']]]
    output, status = Picorake::Spawn.run(["/bin/cat"], stdin_from: feeders)
    assert_equal(0, status)
    assert_equal(1_280_000, output.bytesize)
    assert_equal(true, output == "0123456789abcdef" * 80_000)
  end

  def test_stdin_from_empty_feeders_gives_eof
    output, status = Picorake::Spawn.run(["/bin/cat"], stdin_from: [])
    assert_equal(0, status)
    assert_equal("", output)
  end

  def test_stdin_from_honours_out_inherit
    status = Picorake::Spawn.run(["/bin/cat"], stdin_from: [[[PRINTF, "%s", ""]]], out: :inherit)
    assert_equal(0, status)
  end

  def awk_formatter(value)
    program = "{ if ($0 ~ /^[A-Za-z0-9._~+\\/=-]+$/) printf \"%s%s\\\"\\n\", prefix, $0; else exit 120 }"
    [[PRINTF, "%s", value], ["/usr/bin/awk", "-v", "prefix=header = \"Authorization: Bearer ", program]]
  end

  def test_stdin_from_awk_formats_a_safe_value
    output, status = Picorake::Spawn.run(["/bin/cat"], stdin_from: [awk_formatter("abc123")])
    assert_equal(0, status)
    assert_equal("header = \"Authorization: Bearer abc123\"\n", output)
  end

  def test_stdin_from_awk_rejects_an_unsafe_value
    error = nil
    begin
      Picorake::Spawn.run(["/bin/cat"], stdin_from: [awk_formatter("abc\"def")])
    rescue Picorake::Spawn::FeedError => e
      error = e
    end
    assert_equal(true, !error.nil?)
    assert_equal(0, error.index)
    assert_equal(1, error.stage)
    assert_equal(120, error.status)
    assert_equal(false, error.message.include?("abc"))
  end

  def feed_error_for(feeders)
    error = nil
    begin
      Picorake::Spawn.run(["/bin/cat"], stdin_from: feeders)
    rescue Picorake::Spawn::FeedError => e
      error = e
    end
    error
  end

  def test_feed_error_reports_the_second_command_when_it_is_the_first_to_fail
    error = feed_error_for([[[PRINTF, "%s", "x"], ["/bin/sh", "-c", "exit 44"]]])
    assert_equal(true, !error.nil?)
    assert_equal(0, error.index)
    assert_equal(1, error.stage)
    assert_equal(44, error.status)
    assert_equal("feeder 0 stage 1 exited 44", error.message)
  end

  def test_feed_error_reports_the_first_command_when_it_fails
    error = feed_error_for([[["/bin/sh", "-c", "exit 44"], ["/bin/cat"]]])
    assert_equal(true, !error.nil?)
    assert_equal(0, error.index)
    assert_equal(0, error.stage)
    assert_equal(44, error.status)
    assert_equal("feeder 0 stage 0 exited 44", error.message)
  end

  def test_status_is_reported_when_sigchld_is_ignored_in_the_vm
    code = 'p Picorake::Spawn.run(["/usr/bin/false"], out: :inherit)'
    output, status = Picorake::Spawn.run(["/usr/bin/perl", "-e", '$SIG{CHLD} = "IGNORE"; exec @ARGV', ENV["PICORUBY"], "-e", code])
    assert_equal(0, status)
    assert_equal("1\n", output)
  end

  def test_child_does_not_inherit_the_parents_other_fds
    script = 'print join(",", grep { -e "/dev/fd/$_" } 0..63)'
    output, status = Picorake::Spawn.run(["/usr/bin/perl", "-e", script], stdin: "x")
    assert_equal(0, status)
    assert_equal("0,1,2", output)
  end
end
