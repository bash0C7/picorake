module Picorake
  class Error < StandardError; end

  LATE = 1_000_000_000_000_000

  def self.application
    @application ||= Application.new
  end

  def self.application=(app)
    @application = app
  end

  def self.define_task(klass, *args, &block)
    application.define_task(klass, *args, &block)
  end
end
