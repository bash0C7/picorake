module Picorake
  def self.file_stamper
    @file_stamper
  end

  def self.file_stamper=(callable)
    @file_stamper = callable
  end

  class FileTask < Task
    def self.scope_name(scope, task_name)
      task_name.to_s
    end

    def stamp(args = nil)
      source = Picorake.file_stamper
      source && source.call(name)
    end

    def timestamp(args = nil)
      stamp(args) || LATE
    end

    def needed?(args = nil)
      current = stamp(args)
      current.nil? || out_of_date?(current, args)
    end

    def out_of_date?(current, args = nil)
      all_prerequisite_tasks.any? { |pre| pre.timestamp(args ? args.new_scope(pre.arg_names) : nil) > current }
    end
  end
end
