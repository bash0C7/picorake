module Picorake
  class FileTask < Task
    def self.scope_name(scope, task_name)
      task_name.to_s
    end

    def stamp(args = nil)
      nil
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
