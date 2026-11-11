module Picorake
  class TaskArguments
    attr_reader :names

    def initialize(names, values, parent = nil)
      @names = names.map { |n| n.to_sym }
      @parent = parent
      @values = values
      @hash = {}
      @names.each_with_index do |name, i|
        value = values[i]
        next if value.nil? || value == ""
        @hash[name] = value
      end
    end

    def to_a
      @values.dup
    end

    def extras
      @values[@names.length..-1] || []
    end

    def new_scope(names)
      values = names.map { |n| self[n] }
      self.class.new(names, values + extras, self)
    end

    def [](name)
      lookup(name.to_sym)
    end

    def key?(name)
      @hash.key?(name.to_sym)
    end

    def to_h
      @hash.dup
    end

    def method_missing(sym, *args)
      lookup(sym.to_sym)
    end

    protected

    def lookup(name)
      if @hash.key?(name)
        @hash[name]
      elsif @parent
        @parent.lookup(name)
      end
    end
  end
end
