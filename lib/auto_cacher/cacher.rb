# frozen_string_literal: true

module AutoCacher
  class Cacher
    CONFIG_OPTIONS = [
      # Inferred from class name
      :table, # Table name of cached field. Inferred from klass if not provided.
      :field, # Field name of cached field. Inferred from class name if not provided.
      :klass, # ActiveRecord class representing table on which cached field exists

      # Configuration
      :sync, # Whether to recalculate synchronously. Defaults to true.
      :watching, # FieldMap of tables and fields to watch
      :calculation, # Proc to calculate the cached field value
      :records_to_update, # Proc to find records to update when a change occurs, or symbol of method to call on klass
      :on_update, # Callback to run after updating that cache field on a record
      :operations, # Operations to watch for. Defaults to all.
      :context # Context to pass to calculation and records_to_update
    ].freeze

    class << self
      def inherited(subclass)
        subclass.extend(ClassMethods)
        subclass.cacher_config = subclass.interpret_configuration_options(subclass.cacher_config)
      end
    end

    module ClassMethods
      attr_writer :cacher_config

      def configuration(options = {})
        self.cacher_config = interpret_configuration_options(options)
      end

      def interpret_configuration_options(options = {})
        config = cacher_config.dup

        config[:table] = options[:table].to_s if options.key?(:table)
        config[:field] = options[:field]&.to_sym if options.key?(:field)
        config[:klass] = options[:klass] if options.key?(:klass)

        raise ArgumentError, "Must provide table if no klass" unless config[:table]

        config[:sync] = options[:sync] if options.key?(:sync)
        config[:watching] = ::HallMonitor::FieldMap.build(options[:watching]) if options.key?(:watching)
        config[:calculation] = options[:calculation]&.to_proc if options.key?(:calculation)
        config[:records_to_update] = options[:records_to_update]&.to_proc if options.key?(:records_to_update)
        config[:on_update] = options[:on_update]&.to_proc if options.key?(:on_update)
        config[:operations] = options[:operations] ? Array(options[:operations]).map(&:to_sym) : nil if options.key?(:operations)
        config[:context] = options[:context] if options.key?(:context)

        config
      end

      def cacher_config
        @cacher_config ||= default_cacher_config
      end

      def default_cacher_config
        config = superclass.cacher_config.dup if superclass.respond_to?(:cacher_config)
        config ||= CONFIG_OPTIONS.each_with_object({}) { |option, hash| hash[option] = nil }
        config.merge({
          field: inferred_field_name,
          table: inferred_table_name,
          klass: inferred_klass,
          sync: true
        })
      end

      def config(key, *args)
        if args.empty?
          cacher_config[key.to_sym]
        else
          configuration(key.to_sym => args.first)
        end
      end

      # class level configuration accessors
      CONFIG_OPTIONS.each do |option|
        define_method(option) do
          config(option)
        end

        define_method("#{option}=") do |value|
          config(option, value)
        end
      end

      def inferred_field_name
        name.split("::").last.sub(/Cacher$/, "").underscore.to_sym
      end

      def inferred_klass
        k = name.split("::")[0..-2].join("::")
        constant = k.constantize
        constant.is_a?(Class) ? constant : nil
      rescue NameError
        nil
      end

      def inferred_table_name
        inferred_klass&.respond_to?(:table_name) ? inferred_klass.table_name : name.split("::").first.underscore.pluralize
      end
    end

    extend ClassMethods

    # instance level configuration accessors
    CONFIG_OPTIONS.each do |option|
      define_method(option) do
        self.class.config(option)
      end
    end

    # Called by HallMonitor when changes occur.
    def call(data_change)
      return if records_to_update.nil?

      relation =
        if records_to_update.is_a?(Symbol)
          klass.send(records_to_update, data_change)
        elsif records_to_update.respond_to?(:call)
          records_to_update.call(data_change)
        else
          return
        end

      return if relation.nil? || relation.count.zero?

      recalculate_for(relation)
    end

    def run_callback(record)
      return unless on_update

      case on_update
      when Proc
        on_update.call(record)
      when Symbol, String
        if record.respond_to?(on_update)
          record.send(on_update, record)
        else
          raise ArgumentError, "Callback method '#{on_update}' not found on #{record.class}"
        end
      else
        raise ArgumentError, "Unsupported callback type: #{on_update.class}"
      end
    end

    def recalculate_for(relation)
      AutoCacher.recalculate(relation, [field])
    end
  end
end 