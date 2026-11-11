module Picorake
  class Application
    def initialize
      @tasks = {}
      @scope = []
      @last_description = nil
      @invoked = nil
    end

    def current_scope
      @scope
    end

    def desc(text)
      @last_description = text
    end

    def define_task(task_class, *args, &block)
      task_name, arg_names, deps = resolve_args(args)
      task = intern(task_class, task_class.scope_name(@scope, task_name))
      task.set_arg_names(arg_names) unless arg_names.empty?
      task.add_description(@last_description)
      @last_description = nil
      task.enhance(deps, &block)
      task
    end

    def intern(task_class, task_name)
      @tasks[task_name] ||= task_class.new(task_name, self)
    end

    def namespace(name)
      @scope = @scope + [name.to_s]
      yield
    ensure
      @scope = @scope[0..-2]
    end

    def lookup(task_name, initial_scope = nil)
      scope = initial_scope || @scope
      task_name = task_name.to_s
      if task_name.start_with?("rake:")
        scope = []
        task_name = task_name[5..-1]
      elsif task_name.start_with?("^")
        trim = 0
        trim += 1 while task_name[trim] == "^"
        scope = scope[0, [scope.size - trim, 0].max]
        task_name = task_name[trim..-1]
      end
      lookup_in_scope(task_name, scope)
    end

    def [](task_name, scopes = nil)
      lookup(task_name, scopes) or
        raise Error, "Don't know how to build task '#{task_name}'"
    end

    def tasks
      @tasks.values.sort { |a, b| a.name <=> b.name }
    end

    def invoke(task_name, args_hash = {})
      self[task_name].invoke(args_hash)
    end

    def plan(task_name, args_hash = {})
      task = self[task_name]
      result = []
      task.plan_with_chain(task.build_arguments([args_hash]), [], {}, result)
      result
    end

    def run
      return yield if @invoked
      @invoked = {}
      begin
        yield
      ensure
        @invoked = nil
      end
    end

    def invoked?(task)
      @invoked.key?(task.name)
    end

    def mark_invoked(task)
      @invoked[task.name] = true
    end

    def load(path)
      Object.include(Picorake::DSL) unless Object.include?(Picorake::DSL)
      super(path)
    end

    private

    def lookup_in_scope(name, scope)
      loop do
        task = @tasks[(scope + [name]).join(":")]
        return task if task
        break if scope.empty?
        scope = scope[0..-2]
      end
      nil
    end

    def resolve_args(args)
      args = args.dup
      if args.last.is_a?(Hash)
        resolve_args_with_dependencies(args, args.pop)
      else
        resolve_args_without_dependencies(args)
      end
    end

    def resolve_args_without_dependencies(args)
      task_name = args.shift
      arg_names = args.size == 1 && args[0].is_a?(Array) ? args[0] : args
      [task_name, arg_names, []]
    end

    def resolve_args_with_dependencies(args, hash)
      raise Error, "Task Argument Error" if hash.size != 1
      key = hash.keys[0]
      deps = hash.values[0] || []
      if args.empty?
        task_name = key
        arg_names = []
      else
        task_name = args.shift
        arg_names = key || args.shift || []
      end
      [task_name, arg_names, deps]
    end
  end
end
