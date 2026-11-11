module Picorake
  module DSL
    private

    def task(*args, &block)
      Picorake.define_task(Picorake::Task, *args, &block)
    end

    def file(*args, &block)
      Picorake.define_task(Picorake::FileTask, *args, &block)
    end

    def namespace(name, &block)
      Picorake.application.namespace(name, &block)
    end

    def desc(text)
      Picorake.application.desc(text)
    end
  end
end
