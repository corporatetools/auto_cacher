# frozen_string_literal: true

require "active_record"
require "active_support"
require "hall_monitor"

require_relative "auto_cacher/version"
require_relative "auto_cacher/active_record_extensions"
require_relative "auto_cacher/cacher"

module AutoCacher
  class << self
    def register_all_cachers_from_loaded_object_memory
      @registered_cachers = []
      # Find all cacher classes defined in memory and register them
      ObjectSpace.each_object(Class).select { |klass| klass < AutoCacher::Cacher }.each do |auto_cacher_klass|
        register_cacher(auto_cacher_klass)
      end
    end

    def register_cacher(cacher)
      # check if class or instance
      cacher = cacher.new if cacher.is_a?(Class)
      registered_cachers << cacher
      registered_cachers.uniq!
      callbacks_for(:on_cacher_registry).each { |callback| callback.call(cacher) }
      registered_cachers
    end

    def registered_cachers
      @registered_cachers ||= []
    end

    # Callbacks
    [
      :on_cacher_registry, # called when a cacher is registered (after it's defined)
      :configure_dedicated_model, # called when a dedicated ActiveRecord model is registered (after it's defined)
      :after_every_recalculation, # called after every recalculation of a cacher managed field
      :after_dedicated_model_creation # called after a dedicated ActiveRecord model record is created
    ].each do |method|
      define_method(method) do |&block|
        unless instance_variable_get("@callbacks_for_#{method}")
          instance_variable_set("@callbacks_for_#{method}", [])
        end
        registry = instance_variable_get("@callbacks_for_#{method}")
        registry << block
        instance_variable_set("@callbacks_for_#{method}", registry)
        registry
      end

      define_method("callbacks_for_#{method}") do
        instance_variable_get("@callbacks_for_#{method}") || []
      end
    end

    # For accessing callback registries
    def callbacks_for(method)
      send("callbacks_for_#{method}")
    end

    def recalculate(relation, fields)
      return if fields.empty?

      changes_queue = build_changes_queue(relation, fields)
      return if changes_queue.empty?

      changes_queue.each do |change|
        record = change[:record]
        change[:changes].each do |field, details|
          record.send(:"#{field}=", details[:new_value])
        end
        record.save!

        change[:changes].each do |field, details|
          callbacks_for(:after_every_recalculation).each do |callback|
            callback.call({
              record:,
              field:,
              cacher: details[:cacher],
              old_value: details[:old_value],
              new_value: details[:new_value]
            })
          end
          details[:cacher].run_callback(record)
        end
      end
    end

    def cachers_for_table(table_name)
      registered_cachers.select { |cacher| cacher.table == table_name }
    end

    def find_cachers_for_table_and_field(table_name, field)
      cachers_for_table(table_name).select { |cacher| cacher.field.to_s == field.to_s }
    end

    def cachers_for(table_or_klass, field = nil)
      table_name = \
        if table_or_klass.is_a?(Class) && table_or_klass < ActiveRecord::Base
          table_or_klass.table_name
        elsif table_or_klass.is_a?(String) || table_or_klass.is_a?(Symbol)
          table_or_klass.to_s
        else
          raise ArgumentError, "Invalid table_or_klass: #{table_or_klass.inspect}"
        end
      return [] if table_name.nil?
      return cachers_for_table(table_name) if field.nil?
      find_cachers_for_table_and_field(table_name, field)
    end

    def model_klasses_with_auto_cacher_fields
      registered_cachers.map(&:klass).uniq
    end

    def dedicated_auto_cacher_models
      @dedicated_auto_cacher_models ||= []
    end

    def models_with_dedicated_auto_cachers
      dedicated_auto_cacher_models.map { |model|
        model.reflect_on_association(model.auto_cacher_dedicated_to_association).klass
      }.uniq
    end

    def register_dedicated_auto_cacher_model(dedicated_model_klass)
      unless dedicated_auto_cacher_models.include?(dedicated_model_klass)
        @dedicated_auto_cacher_models << dedicated_model_klass
        callbacks_for(:configure_dedicated_model).each do |callback|
          callback.call(dedicated_model_klass)
        end
      end
    end

    def dedicated_auto_cacher_klass_for(record_or_klass)
      klass = (record_or_klass < ActiveRecord::Base) ? record_or_klass : record_or_klass.class
      dedicated_auto_cacher_models.find { |model| model.auto_cacher_dedicated_to_klass == klass }
    end

    def build_changes_queue(relation, fields)
      relation.find_each.with_object([]) do |record, changes|
        field_changes = fields.each_with_object({}) do |field, hash|
          cacher = find_cachers_for_table_and_field(relation.table_name, field).first
          next unless cacher

          old_value = record.send(field)
          new_value = cacher.calculation.call(record, &cacher.method(:calculation))
          next if new_value == old_value

          hash[field] = {cacher: cacher, old_value: old_value, new_value: new_value}
        end

        changes << {record: record, changes: field_changes} unless field_changes.empty?
      end
    end

    def all_managed_cache_fields
      registered_cachers.each_with_object({}) do |cacher, hash|
        hash[cacher.table] ||= []
        hash[cacher.table] << cacher.field
      end
    end
  end
end
