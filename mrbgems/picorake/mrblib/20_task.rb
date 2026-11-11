module Picorake
  class Task
    attr_reader :name, :prerequisites, :actions, :scope, :application

    def self.scope_name(scope, task_name)
      (scope + [task_name.to_s]).join(":")
    end

    def self.format_deps(deps)
      deps = [deps] unless deps.is_a?(Array)
      deps.map { |d| d.to_s }
    end

    def initialize(task_name, app)
      @name = task_name.to_s
      @application = app
      @scope = app.current_scope.dup
      @prerequisites = []
      @actions = []
      @comments = []
      @arg_names = nil
    end

    def to_s
      @name
    end

    def enhance(deps = nil, &block)
      @prerequisites |= self.class.format_deps(deps) if deps
      @actions << block if block
      self
    end

    def arg_names
      @arg_names || []
    end

    def set_arg_names(names)
      @arg_names = names.map { |n| n.to_sym }
    end

    def add_description(text)
      return if text.nil?
      comment = text.strip
      @comments << comment unless comment.empty? || @comments.include?(comment)
    end

    def comment
      @comments.empty? ? nil : @comments.join(" / ")
    end

    def prerequisite_tasks
      @prerequisites.map { |pre| lookup_prerequisite(pre) }
    end

    def all_prerequisite_tasks
      seen = {}
      collect_prerequisites(seen)
      seen.values
    end

    def collect_prerequisites(seen)
      prerequisite_tasks.each do |pre|
        next if seen[pre.name]
        seen[pre.name] = pre
        pre.collect_prerequisites(seen)
      end
    end

    def needed?(args = nil)
      true
    end

    def timestamp(args = nil)
      Time.now.to_i
    end

    def execute(args = nil)
      args ||= TaskArguments.new([], [])
      @actions.each { |action| action.call(self, args) }
    end

    def invoke(*values)
      task_args = build_arguments(values)
      application.run { invoke_with_chain(task_args, []) }
    end

    def build_arguments(values)
      if values.size == 1 && values[0].is_a?(Hash)
        hash = values[0]
        values = arg_names.map { |n| hash.key?(n) ? hash[n] : hash[n.to_s] }
      end
      TaskArguments.new(arg_names, values)
    end

    def invoke_with_chain(task_args, chain)
      new_chain = append_to_chain(chain)
      return if application.invoked?(self)
      application.mark_invoked(self)
      prerequisite_tasks.each do |pre|
        pre.invoke_with_chain(task_args.new_scope(pre.arg_names), new_chain)
      end
      execute(task_args) if needed?(task_args)
    end

    def plan_with_chain(task_args, chain, memo, result)
      new_chain = append_to_chain(chain)
      return memo[@name] if memo.key?(@name)
      memo[@name] = false
      included = false
      prerequisite_tasks.each do |pre|
        pre_included = pre.plan_with_chain(task_args.new_scope(pre.arg_names), new_chain, memo, result)
        included = true if pre_included
      end
      included = true if needed?(task_args)
      result << [self, task_args] if included
      memo[@name] = included
    end

    def append_to_chain(chain)
      if chain.include?(@name)
        raise Error, "Circular dependency detected: #{(chain + [@name]).join(' => ')}"
      end
      chain + [@name]
    end

    private

    def lookup_prerequisite(prerequisite_name)
      scoped = application[prerequisite_name, @scope]
      if scoped.equal?(self)
        unscoped = application[prerequisite_name]
      end
      unscoped || scoped
    end
  end
end
